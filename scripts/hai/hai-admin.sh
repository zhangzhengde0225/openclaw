#!/usr/bin/env bash
set -euo pipefail

# HPC Multi-user OpenClaw Admin Script
# Manages user registration, container lifecycle via SLURM, and status reporting.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
USERS_CSV="${SCRIPT_DIR}/users.csv"
TEMPLATE_JSON5="${SCRIPT_DIR}/openclaw-template.json5"

# Base home directory for all HPC users (shared filesystem)
HOME_BASE="${HAI_HOME_BASE:-/aifs/user/home}"

# SLURM defaults (override via environment)
SLURM_PARTITION="${HAI_PARTITION:-cpu}"
SLURM_QOS="${HAI_QOS:-cpudvp}"
SLURM_CPUS="${HAI_CPUS:-4}"
SLURM_MEM="${HAI_MEM:-8G}"
SLURM_TIME="${HAI_TIME:-7-00:00:00}"
SLURM_NODELIST="${HAI_NODELIST:-aicpu003}"
DOCKER_IMAGE="${HAI_DOCKER_IMAGE:-hai-openclaw:latest}"

# Port base offsets
SSH_PORT_BASE=22000
GW_PORT_BASE=18100

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_csv() {
  if [[ ! -f "$USERS_CSV" ]]; then
    echo "username,user_index,hepai_api_key,ssh_port,gateway_port,status,slurm_job_id" > "$USERS_CSV"
  fi
}

# Read a field from users.csv for a given username.
# Usage: csv_field <username> <field_number> (1-based)
csv_field() {
  local user="$1" field="$2"
  awk -F, -v u="$user" 'NR>1 && $1==u {print $'$field'}' "$USERS_CSV"
}

next_index() {
  local max
  max=$(awk -F, 'NR>1 && $2 ~ /^[0-9]+$/ {if($2>m) m=$2} END{print m+0}' "$USERS_CSV")
  echo $(( max + 1 ))
}

user_exists() {
  awk -F, -v u="$1" 'NR>1 && $1==u {found=1} END{exit !found}' "$USERS_CSV"
}

# Update a field in users.csv for a given user (in-place).
# Usage: csv_update <username> <field_number> <new_value>
csv_update() {
  local user="$1" field="$2" value="$3"
  awk -F, -v OFS=, -v u="$user" -v f="$field" -v v="$value" \
    'NR==1{print; next} $1==u{$f=v}{print}' "$USERS_CSV" > "${USERS_CSV}.tmp"
  mv "${USERS_CSV}.tmp" "$USERS_CSV"
}

user_dir() {
  echo "${HOME_BASE}/$1/.hai-openclaw"
}

# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #

cmd_build() {
  echo "=== Building base openclaw:local image ==="
  docker build -t openclaw:local -f "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}"

  echo ""
  echo "=== Building hai-openclaw:latest image ==="
  docker build -t hai-openclaw:latest -f "${SCRIPT_DIR}/Dockerfile.multiuser" "${REPO_ROOT}"

  echo ""
  echo "Build complete. Images:"
  docker images | grep -E 'hai-openclaw|openclaw.*local'
}

cmd_add_user() {
  local username="${1:-}"
  local api_key="${2:-}"
  [[ -z "$username" ]] && die "Usage: $0 add-user <username> <hepai_api_key>"
  [[ -z "$api_key" ]] && die "Usage: $0 add-user <username> <hepai_api_key>"

  ensure_csv
  if user_exists "$username"; then
    die "User '$username' already registered in users.csv"
  fi

  local idx ssh_port gw_port udir
  idx=$(next_index)
  ssh_port=$(( SSH_PORT_BASE + idx ))
  gw_port=$(( GW_PORT_BASE + idx ))
  udir=$(user_dir "$username")

  # Create persistent directories
  mkdir -p "${udir}/config" "${udir}/workspace"

  # Copy config template
  cp "$TEMPLATE_JSON5" "${udir}/openclaw-template.json5"

  # Generate random gateway token
  local gw_token
  gw_token=$(openssl rand -hex 32)
  echo "$gw_token" > "${udir}/.gateway-token"
  chmod 600 "${udir}/.gateway-token"

  # Append to users.csv
  echo "${username},${idx},${api_key},${ssh_port},${gw_port},stopped," >> "$USERS_CSV"

  echo ""
  echo "User '${username}' registered:"
  echo "  Index:        ${idx}"
  echo "  SSH port:     ${ssh_port}"
  echo "  Gateway port: ${gw_port}"
  echo "  Data dir:     ${udir}"
  echo ""
  echo "Next step: $0 start ${username}"
}

cmd_start() {
  local username="${1:-}"
  [[ -z "$username" ]] && die "Usage: $0 start <username>"

  ensure_csv
  user_exists "$username" || die "User '$username' not found in users.csv"

  local idx api_key ssh_port gw_port udir gw_token
  idx=$(csv_field "$username" 2)
  api_key=$(csv_field "$username" 3)
  ssh_port=$(csv_field "$username" 4)
  gw_port=$(csv_field "$username" 5)
  udir=$(user_dir "$username")
  gw_token=$(cat "${udir}/.gateway-token" 2>/dev/null || echo "changeme")

  # Check if already running
  local current_status
  current_status=$(csv_field "$username" 6)
  if [[ "$current_status" == "running" ]]; then
    local current_job
    current_job=$(csv_field "$username" 7)
    if [[ -n "$current_job" ]] && squeue -j "$current_job" &>/dev/null 2>&1; then
      echo "User '${username}' already has a running job (${current_job}). Stop it first."
      return 1
    fi
  fi

  # Generate SLURM batch script
  local slurm_script="${udir}/slurm-job.sh"
  cat > "$slurm_script" <<'SLURM_EOF'
#!/usr/bin/env bash
#SBATCH --job-name=openclaw-__USERNAME__
#SBATCH --partition=__PARTITION__
#SBATCH --qos=__QOS__
#SBATCH --nodelist=__NODELIST__
#SBATCH --cpus-per-task=__CPUS__
#SBATCH --mem=__MEM__
#SBATCH --time=__TIME__
#SBATCH --output=__UDIR__/slurm-%j.out
#SBATCH --error=__UDIR__/slurm-%j.err

echo "Job ${SLURM_JOB_ID} starting on ${SLURM_NODELIST}"
echo "User: __USERNAME__, SSH port: __SSH_PORT__, Gateway port: __GW_PORT__"

# Detect UID/GID from the user directory (for Lustre root_squash compatibility)
HOST_UID=$(stat -c '%u' "__UDIR__")
HOST_GID=$(stat -c '%g' "__UDIR__")
echo "Detected HOST_UID=${HOST_UID}, HOST_GID=${HOST_GID}"

# Cleanup function to stop container on exit
cleanup() {
  echo "Received termination signal, stopping container..."
  docker stop openclaw-__USERNAME__ 2>/dev/null || true
  exit 0
}

# Trap termination signals
trap cleanup SIGTERM SIGINT

# Start container in background
docker run --rm \
  --name openclaw-__USERNAME__ \
  --cpus=__CPUS__ \
  --memory=__MEM_LOWER__ \
  -p __SSH_PORT__:22 \
  -p __GW_PORT__:18789 \
  -e HEPAI_API_KEY="__API_KEY__" \
  -e OPENCLAW_GATEWAY_TOKEN="__GW_TOKEN__" \
  -e HOST_UID=${HOST_UID} \
  -e HOST_GID=${HOST_GID} \
  -v __UDIR__/config:/home/clawuser/.openclaw \
  -v __UDIR__/workspace:/home/clawuser/workspace \
  -v __UDIR__/openclaw-template.json5:/tmp/openclaw-template.json5:ro \
  __DOCKER_IMAGE__ &

# Wait for container to finish
DOCKER_PID=$!
wait $DOCKER_PID
EXIT_CODE=$?

echo "Container exited with code: $EXIT_CODE"
exit $EXIT_CODE
SLURM_EOF

  # Replace placeholders
  sed -i "s|__USERNAME__|${username}|g" "$slurm_script"
  sed -i "s|__PARTITION__|${SLURM_PARTITION}|g" "$slurm_script"
  sed -i "s|__QOS__|${SLURM_QOS}|g" "$slurm_script"
  sed -i "s|__NODELIST__|${SLURM_NODELIST}|g" "$slurm_script"
  sed -i "s|__CPUS__|${SLURM_CPUS}|g" "$slurm_script"
  sed -i "s|__MEM__|${SLURM_MEM}|g" "$slurm_script"
  sed -i "s|__MEM_LOWER__|${SLURM_MEM,,}|g" "$slurm_script"
  sed -i "s|__TIME__|${SLURM_TIME}|g" "$slurm_script"
  sed -i "s|__SSH_PORT__|${ssh_port}|g" "$slurm_script"
  sed -i "s|__GW_PORT__|${gw_port}|g" "$slurm_script"
  sed -i "s|__API_KEY__|${api_key}|g" "$slurm_script"
  sed -i "s|__GW_TOKEN__|${gw_token}|g" "$slurm_script"
  sed -i "s|__UDIR__|${udir}|g" "$slurm_script"
  sed -i "s|__DOCKER_IMAGE__|${DOCKER_IMAGE}|g" "$slurm_script"
  chmod +x "$slurm_script"

  # Submit to SLURM
  echo "Submitting SLURM job for '${username}'..."
  local sbatch_output
  sbatch_output=$(sbatch "$slurm_script" 2>&1)
  echo "$sbatch_output"

  local job_id
  job_id=$(echo "$sbatch_output" | grep -oP '\d+$' || true)
  if [[ -z "$job_id" ]]; then
    die "Failed to parse SLURM job ID from: ${sbatch_output}"
  fi

  # Update users.csv
  csv_update "$username" 6 "running"
  csv_update "$username" 7 "$job_id"

  echo "Job submitted: ${job_id}"

  # Wait for the job to start running and discover the compute node
  echo "Waiting for job to start..."
  local node_name="" attempts=0 max_attempts=60
  while [[ $attempts -lt $max_attempts ]]; do
    local job_state
    job_state=$(squeue -j "$job_id" -h -o "%T" 2>/dev/null || echo "UNKNOWN")
    if [[ "$job_state" == "RUNNING" ]]; then
      node_name=$(squeue -j "$job_id" -h -o "%N" 2>/dev/null || echo "")
      break
    elif [[ "$job_state" == "UNKNOWN" || "$job_state" == "FAILED" || "$job_state" == "CANCELLED" ]]; then
      echo "Job ${job_id} ended with state: ${job_state}"
      csv_update "$username" 6 "stopped"
      csv_update "$username" 7 ""
      return 1
    fi
    sleep 5
    attempts=$(( attempts + 1 ))
    echo "  Waiting... (${job_state}, ${attempts}/${max_attempts})"
  done

  if [[ -z "$node_name" ]]; then
    echo "WARNING: Job submitted but node not yet allocated after polling."
    echo "  Check with: squeue -j ${job_id}"
    echo "  Run '$0 info ${username}' once it starts."
    return 0
  fi

  # Write connection info file
  local info_file="${udir}/connection-info.txt"
  cat > "$info_file" <<INFO_EOF
========================================
 OpenClaw Connection Info (User: ${username})
========================================
SSH Access:     ssh -p ${ssh_port} -o UserKnownHostsFile=/dev/null clawuser@${node_name}
Default Password: openclaw123
IMPORTANT:      Change password after first login: passwd

Web UI:         http://${node_name}:${gw_port}
Gateway Token:  ${gw_token}
SLURM Job ID:   ${job_id}
Compute Node:   ${node_name}
========================================
Utility commands:
  show_limits                  # Display CPU/Memory limits

Available commands inside the container:
  openclaw onboard             # Configure OpenClaw
  openclaw models list         # List available models
  openclaw models set ...      # Switch model
  openclaw send "..."          # Send a message
  openclaw gateway run --bind lan --port 18789  # Start gateway
========================================
INFO_EOF

  echo ""
  echo "=== Container started ==="
  cat "$info_file"
}

cmd_stop() {
  local username="${1:-}"
  [[ -z "$username" ]] && die "Usage: $0 stop <username>"

  ensure_csv
  user_exists "$username" || die "User '$username' not found in users.csv"

  local job_id
  job_id=$(csv_field "$username" 7)

  if [[ -n "$job_id" ]]; then
    echo "Cancelling SLURM job ${job_id} for '${username}'..."
    scancel "$job_id" 2>/dev/null || true
  else
    echo "No active job ID for '${username}'."
  fi

  csv_update "$username" 6 "stopped"
  csv_update "$username" 7 ""
  echo "User '${username}' stopped."
}

cmd_status() {
  ensure_csv

  # Collect running SLURM job states
  declare -A job_states job_nodes
  while IFS='|' read -r jid state nodelist; do
    job_states["$jid"]="$state"
    job_nodes["$jid"]="$nodelist"
  done < <(squeue -u "$(whoami)" -h -o "%i|%T|%N" 2>/dev/null || true)

  printf "%-15s %-6s %-10s %-10s %-10s %-15s %-10s\n" \
    "USERNAME" "INDEX" "SSH_PORT" "GW_PORT" "STATUS" "NODE" "JOB_ID"
  printf "%-15s %-6s %-10s %-10s %-10s %-15s %-10s\n" \
    "-------" "-----" "--------" "-------" "------" "----" "------"

  while IFS=, read -r uname idx api_key ssh_port gw_port status job_id; do
    [[ "$uname" == "username" ]] && continue  # skip header

    local actual_status="$status"
    local node="-"

    if [[ -n "$job_id" ]] && [[ -v "job_states[$job_id]" ]]; then
      actual_status="${job_states[$job_id],,}"  # lowercase
      node="${job_nodes[$job_id]:-"-"}"
      # Sync status back to csv if changed
      if [[ "$actual_status" != "$status" ]]; then
        csv_update "$uname" 6 "$actual_status"
      fi
    elif [[ -n "$job_id" ]] && [[ "$status" == "running" ]]; then
      # Job no longer in queue — mark stopped
      actual_status="stopped"
      csv_update "$uname" 6 "stopped"
      csv_update "$uname" 7 ""
      job_id="-"
    fi

    printf "%-15s %-6s %-10s %-10s %-10s %-15s %-10s\n" \
      "$uname" "$idx" "$ssh_port" "$gw_port" "$actual_status" "$node" "${job_id:-"-"}"
  done < "$USERS_CSV"
}

cmd_info() {
  local username="${1:-}"
  [[ -z "$username" ]] && die "Usage: $0 info <username>"

  ensure_csv
  user_exists "$username" || die "User '$username' not found in users.csv"

  local udir info_file
  udir=$(user_dir "$username")
  info_file="${udir}/connection-info.txt"

  if [[ -f "$info_file" ]]; then
    cat "$info_file"
  else
    echo "No connection info found for '${username}'."
    echo "The container may not have been started yet. Run: $0 start ${username}"

    # Show static info from csv
    local ssh_port gw_port
    ssh_port=$(csv_field "$username" 4)
    gw_port=$(csv_field "$username" 5)
    echo ""
    echo "Registered ports:"
    echo "  SSH port:     ${ssh_port}"
    echo "  Gateway port: ${gw_port}"
  fi
}

cmd_start_all() {
  ensure_csv
  local count=0
  while IFS=, read -r uname idx api_key ssh_port gw_port status job_id; do
    [[ "$uname" == "username" ]] && continue
    if [[ "$status" != "running" ]]; then
      echo "--- Starting ${uname} ---"
      cmd_start "$uname" || echo "WARNING: Failed to start ${uname}"
      echo ""
      count=$(( count + 1 ))
    else
      echo "Skipping ${uname} (already running, job ${job_id})"
    fi
  done < "$USERS_CSV"
  echo "Started ${count} user(s)."
}

cmd_stop_all() {
  ensure_csv
  local count=0
  while IFS=, read -r uname idx api_key ssh_port gw_port status job_id; do
    [[ "$uname" == "username" ]] && continue
    if [[ "$status" == "running" ]] && [[ -n "$job_id" ]]; then
      echo "Stopping ${uname} (job ${job_id})..."
      cmd_stop "$uname"
      count=$(( count + 1 ))
    fi
  done < "$USERS_CSV"
  echo "Stopped ${count} user(s)."
}

cmd_help() {
  cat <<'EOF'
HPC Multi-user OpenClaw Admin Tool

Usage: hai-admin.sh <command> [arguments]

Commands:
  build                        Build base + multiuser Docker images
  add-user <name> <api_key>    Register a new user with HepAI API key
  start <name>                 Start user's container via SLURM
  stop <name>                  Stop user's container (scancel)
  status                       Show all users' status table
  info <name>                  Print connection info for a user
  start-all                    Start all stopped users
  stop-all                     Stop all running users
  help                         Show this help message

Environment overrides:
  HAI_HOME_BASE     User home base dir      (default: /aifs/user/home)
  HAI_PARTITION     SLURM partition          (default: cpu)
  HAI_QOS           SLURM QoS               (default: cpudvp)
  HAI_NODELIST      SLURM node list          (default: aicpu003)
  HAI_CPUS          CPUs per container       (default: 4)
  HAI_MEM           Memory per container     (default: 8G)
  HAI_TIME          SLURM time limit         (default: 7-00:00:00)
  HAI_DOCKER_IMAGE  Docker image to use      (default: hai-openclaw:latest)

Port allocation:
  SSH port     = 22000 + user_index
  Gateway port = 18100 + user_index
EOF
}

# --------------------------------------------------------------------------- #
# Main dispatch
# --------------------------------------------------------------------------- #

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    build)       cmd_build "$@" ;;
    add-user)    cmd_add_user "$@" ;;
    start)       cmd_start "$@" ;;
    stop)        cmd_stop "$@" ;;
    status)      cmd_status "$@" ;;
    info)        cmd_info "$@" ;;
    start-all)   cmd_start_all "$@" ;;
    stop-all)    cmd_stop_all "$@" ;;
    help|--help|-h) cmd_help ;;
    *)           die "Unknown command: ${cmd}. Run '$0 help' for usage." ;;
  esac
}

main "$@"
