#!/usr/bin/env bash
set -euo pipefail

# SLURM Docker launcher script
# Allocates SLURM resources and starts a Docker container

# Default configuration
DEFAULT_PARTITION="${SLURM_PARTITION:-cpu}"
DEFAULT_GPUS="${SLURM_GPUS:-0}"
DEFAULT_CPUS="${SLURM_CPUS:-8}"
DEFAULT_MEM="${SLURM_MEM:-32G}"
DEFAULT_TIME="${SLURM_TIME:-24:00:00}"
DEFAULT_JOB_NAME="${SLURM_JOB_NAME:-openclaw-docker}"
DEFAULT_IMAGE="${DOCKER_IMAGE:-openclaw-sandbox:bookworm-slim}"
DEFAULT_CONTAINER_NAME="${CONTAINER_NAME:-openclaw-sandbox}"

# Parse command line arguments
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -p, --partition PARTITION    SLURM partition (default: ${DEFAULT_PARTITION})
  -g, --gpus GPUS              Number of GPUs (default: ${DEFAULT_GPUS})
  -c, --cpus CPUS              Number of CPUs (default: ${DEFAULT_CPUS})
  -m, --mem MEMORY             Memory allocation (default: ${DEFAULT_MEM})
  -t, --time TIME              Time limit (default: ${DEFAULT_TIME})
  -n, --name NAME              Job name (default: ${DEFAULT_JOB_NAME})
  -i, --image IMAGE            Docker image (default: ${DEFAULT_IMAGE})
  -C, --container NAME         Container name (default: ${DEFAULT_CONTAINER_NAME})
  -v, --volume VOLUME          Docker volume mount (format: host:container[:ro])
  -e, --env ENV                Environment variable (format: KEY=VALUE)
  --interactive                Run in interactive mode (srun instead of sbatch)
  --workdir DIR                Working directory in container
  --cmd COMMAND                Command to run in container (default: /bin/bash)
  --sbatch-opts OPTS           Additional sbatch options
  --docker-opts OPTS           Additional docker run options
  -h, --help                   Show this help message

Examples:
  # Submit a batch job with default settings (CPU only, no GPU)
  $0

  # CPU-only job with custom command
  $0 --partition cpu --cmd "python preprocess.py"

  # Interactive session with 2 GPUs on GPU partition
  $0 --interactive --partition gpu --gpus 2

  # Custom image with volume mounts
  $0 -i my-image:latest -v /data:/data:ro -v /workspace:/workspace

  # Run training with GPUs
  $0 --partition gpu --gpus 4 --cmd "python train.py --epochs 100"

  # Pass additional SLURM and Docker options (note: remove --qos if not supported)
  $0 --sbatch-opts "--nodelist=node01" --docker-opts "--shm-size=16g"

Note:
  - If you get "Invalid qos specification" error, remove --qos from --sbatch-opts
  - Default is 0 GPUs on CPU partition; use --gpus N and --partition gpu for GPU jobs
  - GPU specification (--gres) is automatically omitted when --gpus is 0
EOF
  exit 0
}

# Initialize variables
PARTITION="${DEFAULT_PARTITION}"
GPUS="${DEFAULT_GPUS}"
CPUS="${DEFAULT_CPUS}"
MEM="${DEFAULT_MEM}"
TIME="${DEFAULT_TIME}"
JOB_NAME="${DEFAULT_JOB_NAME}"
IMAGE="${DEFAULT_IMAGE}"
CONTAINER_NAME="${DEFAULT_CONTAINER_NAME}"
VOLUMES=()
ENV_VARS=()
INTERACTIVE=0
WORKDIR=""
CMD="/bin/bash"
SBATCH_OPTS=""
DOCKER_OPTS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--partition)
      PARTITION="$2"
      shift 2
      ;;
    -g|--gpus)
      GPUS="$2"
      shift 2
      ;;
    -c|--cpus)
      CPUS="$2"
      shift 2
      ;;
    -m|--mem)
      MEM="$2"
      shift 2
      ;;
    -t|--time)
      TIME="$2"
      shift 2
      ;;
    -n|--name)
      JOB_NAME="$2"
      shift 2
      ;;
    -i|--image)
      IMAGE="$2"
      shift 2
      ;;
    -C|--container)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    -v|--volume)
      VOLUMES+=("$2")
      shift 2
      ;;
    -e|--env)
      ENV_VARS+=("$2")
      shift 2
      ;;
    --interactive)
      INTERACTIVE=1
      shift
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --cmd)
      CMD="$2"
      shift 2
      ;;
    --sbatch-opts)
      SBATCH_OPTS="$2"
      shift 2
      ;;
    --docker-opts)
      DOCKER_OPTS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Build Docker run command
build_docker_cmd() {
  local docker_cmd="docker run --rm"

  # Add container name
  docker_cmd+=" --name ${CONTAINER_NAME}"

  # Add GPU support if requested
  if [[ "${GPUS}" != "0" ]]; then
    docker_cmd+=" --gpus all"
  fi

  # Add volume mounts
  for vol in "${VOLUMES[@]}"; do
    docker_cmd+=" -v ${vol}"
  done

  # Add environment variables
  for env in "${ENV_VARS[@]}"; do
    docker_cmd+=" -e ${env}"
  done

  # Add working directory
  if [[ -n "${WORKDIR}" ]]; then
    docker_cmd+=" -w ${WORKDIR}"
  fi

  # Add additional Docker options
  if [[ -n "${DOCKER_OPTS}" ]]; then
    docker_cmd+=" ${DOCKER_OPTS}"
  fi

  # Add interactive flags if needed
  if [[ "${INTERACTIVE}" == "1" ]]; then
    docker_cmd+=" -it"
  fi

  # Add image and command
  docker_cmd+=" ${IMAGE} ${CMD}"

  echo "${docker_cmd}"
}

# Generate SLURM job script
generate_slurm_script() {
  local docker_cmd
  docker_cmd=$(build_docker_cmd)

  # Build GPU resource line if needed
  local gpu_line=""
  if [[ "${GPUS}" != "0" ]]; then
    gpu_line="#SBATCH --gres=gpu:${GPUS}"
  fi

  # Auto-select QoS based on partition if not explicitly set
  local qos_line=""
  if [[ ! "${SBATCH_OPTS}" =~ --qos ]]; then
    case "${PARTITION}" in
      cpu)
        qos_line="#SBATCH --qos=cpunormal"
        ;;
      gpu)
        qos_line="#SBATCH --qos=gpunormal"
        ;;
      dcu)
        qos_line="#SBATCH --qos=dcunormal"
        ;;
      *)
        # Try partition + "normal" as default pattern
        qos_line="#SBATCH --qos=${PARTITION}normal"
        ;;
    esac
  fi

  cat <<EOF
#!/usr/bin/env bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --partition=${PARTITION}
${qos_line}
${gpu_line}
#SBATCH --cpus-per-task=${CPUS}
#SBATCH --mem=${MEM}
#SBATCH --time=${TIME}
#SBATCH --output=${JOB_NAME}-%j.out
#SBATCH --error=${JOB_NAME}-%j.err
${SBATCH_OPTS}

# Print job info
echo "============================================"
echo "Job ID: \${SLURM_JOB_ID}"
echo "Job Name: \${SLURM_JOB_NAME}"
echo "Node: \${SLURM_NODELIST}"
echo "Partition: \${SLURM_JOB_PARTITION}"
echo "GPUs: ${GPUS}"
echo "CPUs: ${CPUS}"
echo "Memory: ${MEM}"
echo "============================================"
echo ""

# Load required modules (adjust based on your cluster setup)
# module load docker 2>/dev/null || true
# module load cuda 2>/dev/null || true

# Pull Docker image if not exists
echo "Checking Docker image: ${IMAGE}"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Pulling Docker image: ${IMAGE}"
  docker pull "${IMAGE}"
fi

# Run Docker container
echo "Starting Docker container..."
echo "Command: ${docker_cmd}"
echo ""

${docker_cmd}

echo ""
echo "Container exited with code: \$?"
EOF
}

# Main execution
main() {
  echo "SLURM Docker Launcher"
  echo "====================="
  echo "Partition: ${PARTITION}"
  echo "GPUs: ${GPUS}"
  echo "CPUs: ${CPUS}"
  echo "Memory: ${MEM}"
  echo "Time: ${TIME}"
  echo "Job Name: ${JOB_NAME}"
  echo "Docker Image: ${IMAGE}"
  echo "Container Name: ${CONTAINER_NAME}"
  echo "Mode: $([ ${INTERACTIVE} -eq 1 ] && echo 'Interactive (srun)' || echo 'Batch (sbatch)')"
  echo ""

  # Check if Docker is available
  if ! command -v docker &>/dev/null; then
    echo "Error: docker command not found"
    exit 1
  fi

  # Check if SLURM commands are available
  if [[ "${INTERACTIVE}" == "1" ]]; then
    if ! command -v srun &>/dev/null; then
      echo "Error: srun command not found"
      exit 1
    fi
  else
    if ! command -v sbatch &>/dev/null; then
      echo "Error: sbatch command not found"
      exit 1
    fi
  fi

  if [[ "${INTERACTIVE}" == "1" ]]; then
    # Interactive mode: use srun directly
    local docker_cmd
    docker_cmd=$(build_docker_cmd)

    # Build GPU option for srun if needed
    local gpu_opt=""
    if [[ "${GPUS}" != "0" ]]; then
      gpu_opt="--gres=gpu:${GPUS}"
    fi

    # Auto-select QoS based on partition if not explicitly set
    local qos_opt=""
    if [[ ! "${SBATCH_OPTS}" =~ --qos ]]; then
      case "${PARTITION}" in
        cpu)
          qos_opt="--qos=cpunormal"
          ;;
        gpu)
          qos_opt="--qos=gpunormal"
          ;;
        dcu)
          qos_opt="--qos=dcunormal"
          ;;
        *)
          qos_opt="--qos=${PARTITION}normal"
          ;;
      esac
    fi

    echo "Launching interactive session..."
    echo "Command: srun --partition=${PARTITION} ${qos_opt} ${gpu_opt} --cpus-per-task=${CPUS} --mem=${MEM} --time=${TIME} --pty ${docker_cmd}"
    echo ""

    # shellcheck disable=SC2086
    srun \
      --partition="${PARTITION}" \
      ${qos_opt} \
      ${gpu_opt} \
      --cpus-per-task="${CPUS}" \
      --mem="${MEM}" \
      --time="${TIME}" \
      --job-name="${JOB_NAME}" \
      ${SBATCH_OPTS} \
      --pty \
      bash -c "${docker_cmd}"
  else
    # Batch mode: generate and submit job script
    local job_script
    job_script=$(mktemp /tmp/slurm-job-XXXXXX.sh)

    echo "Generating job script: ${job_script}"
    generate_slurm_script > "${job_script}"
    chmod +x "${job_script}"

    echo ""
    echo "Job script content:"
    echo "-------------------"
    cat "${job_script}"
    echo "-------------------"
    echo ""

    echo "Submitting job to SLURM..."
    sbatch "${job_script}"

    echo ""
    echo "Job submitted successfully!"
    echo "Check status with: squeue -u \${USER}"
    echo "Check output with: tail -f ${JOB_NAME}-<job_id>.out"
    echo "Job script saved at: ${job_script}"
  fi
}

main "$@"
