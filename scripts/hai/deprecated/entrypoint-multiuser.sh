#!/usr/bin/env bash
set -euo pipefail

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
USERNAME="clawuser"

echo "[entrypoint] Creating user ${USERNAME} (UID=${HOST_UID}, GID=${HOST_GID})..."

# Create group (skip if GID already exists)
if ! getent group "${HOST_GID}" >/dev/null 2>&1; then
  groupadd -g "${HOST_GID}" clawgrp
fi
GROUP_NAME=$(getent group "${HOST_GID}" | cut -d: -f1)

# Create user with matching UID/GID
# Use -M (no home creation) because Docker already created /home/clawuser for bind mounts
useradd -M -d /home/${USERNAME} -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash "${USERNAME}"
# Ensure home dir exists and is owned correctly (container-local filesystem, not Lustre)
mkdir -p /home/${USERNAME}
chown ${HOST_UID}:${HOST_GID} /home/${USERNAME}
chmod 755 /home/${USERNAME}

# Set password
echo "${USERNAME}:openclaw123" | chpasswd

# Grant sudo without password
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}
chmod 440 /etc/sudoers.d/${USERNAME}

# Mounted dirs (.openclaw, workspace) are Lustre bind mounts — already owned by
# the correct UID/GID on the host. Do NOT chown them (root_squash blocks it).

# Initialize OpenClaw config from template if not exists
CONFIG_FILE="/home/${USERNAME}/.openclaw/openclaw.json"
TEMPLATE_FILE="/tmp/openclaw-template.json5"

if [[ -f "$TEMPLATE_FILE" ]] && [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[entrypoint] Initializing OpenClaw config from template..."
  # Process template with sed as root (in /tmp), then copy as clawuser
  TEMP_CONFIG="/tmp/openclaw-config-$$.json5"
  sed "s|\${HEPAI_API_KEY}|${HEPAI_API_KEY:-}|g" "$TEMPLATE_FILE" > "$TEMP_CONFIG"
  # Copy to .openclaw as clawuser (root can't write to Lustre mount due to root_squash)
  su - "${USERNAME}" -c "cp '$TEMP_CONFIG' '$CONFIG_FILE'"
  rm -f "$TEMP_CONFIG"
  echo "[entrypoint] Config initialized at $CONFIG_FILE"
fi

# Configure bashrc
cat >> /home/${USERNAME}/.bashrc <<'BASHRC_EOF'

# ==================================================
# OpenClaw Container Configuration
# ==================================================
export HEPAI_API_KEY="${HEPAI_API_KEY}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}"
export PATH="/app/node_modules/.bin:$PATH"

export PS1="\[\033[01;35m\][\[\033[00m\]\[\033[01;32m\]\u@\h\[\033[00m\] \[\033[01;34m\]\W\[\033[00m\]\[\033[01;35m\]]\[\033[00m\]\$ "

if command -v dircolors > /dev/null 2>&1; then
    eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
fi

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ocl='openclaw'
alias ocl-models='openclaw models list'
alias ocl-send='openclaw send'
alias ocl-gateway='openclaw gateway run --bind lan --port 18789'
alias ocl-pm2='pm2 start openclaw --name gateway -- gateway run --bind lan --port 18789'
# ==================================================
BASHRC_EOF

# Substitute actual env var values
sed -i "s|\${HEPAI_API_KEY}|${HEPAI_API_KEY:-}|g" /home/${USERNAME}/.bashrc
sed -i "s|\${OPENCLAW_GATEWAY_TOKEN}|${OPENCLAW_GATEWAY_TOKEN:-}|g" /home/${USERNAME}/.bashrc
chown ${HOST_UID}:${HOST_GID} /home/${USERNAME}/.bashrc

# Create .bash_profile to source .bashrc on SSH login
cat > /home/${USERNAME}/.bash_profile <<'BASH_PROFILE_EOF'
# Source .bashrc if it exists
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
BASH_PROFILE_EOF
chown ${HOST_UID}:${HOST_GID} /home/${USERNAME}/.bash_profile

echo "[entrypoint] User ${USERNAME} configured"

# Display info
echo ""
echo "=========================================="
echo " OpenClaw Container Ready"
echo "=========================================="
echo "Login user: ${USERNAME}"
echo "Default password: openclaw123"
echo "Please change password after first login: passwd"
echo ""
echo "After logging in:"
echo "  1. openclaw onboard"
echo "  2. openclaw gateway run --bind lan --port 18789"
echo ""
echo "Or use pm2 to run gateway in background:"
echo "  pm2 start openclaw --name gateway -- gateway run --bind lan --port 18789"
echo "  pm2 list    # View running processes"
echo "  pm2 logs    # View logs"
echo "=========================================="
echo ""

# Start sshd (as root, foreground)
echo "[entrypoint] Starting sshd..."
exec /usr/sbin/sshd -D
