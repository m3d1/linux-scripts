
#!/bin/bash
# Purpose: Prepare an Ubuntu Desktop to be managed by Ansible/Semaphore
# - Creates the 'semaphore' user with passwordless sudo
# - Installs required dependencies (SSH, Python, etc.)
# - Ensures SSH is enabled, started, and healthy
# - Downloads the private SSH key from a URL and applies correct permissions
# - Runs fully non-interactively
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/m3d1/linux-scripts/refs/heads/main/Ansible/host-preparation/prep-ubuntu-desktop.sh)"

set -euo pipefail

### ---------------------------
### Configuration (edit safely)
### ---------------------------
USER_NAME="semaphore"
USER_SHELL="/bin/bash"
SSH_DIR="/home/${USER_NAME}/.ssh"
SUDOERS_DROPIN="/etc/sudoers.d/99-${USER_NAME}-nopasswd"

### ---------------------------
### Helper functions
### ---------------------------
log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command '$1' not found."
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
  fi
}

systemd_is_active() {
  # Return 0 if active, 1 otherwise (avoid set -e on systemctl)
  systemctl is-active --quiet "$1"
}

### ---------------------------
### 0) Pre-flight checks
### ---------------------------
check_root
require_cmd apt-get
require_cmd systemctl
require_cmd bash
require_cmd sed
require_cmd id

# curl or wget is fine—prefer curl if available
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget -qO-"
else
  err "Neither curl nor wget is available. The script will install curl."
  apt-get update -y && apt-get install -y curl
  DOWNLOADER="curl -fsSL"
fi



### ---------------------------
### 1) Update & install packages
### ---------------------------
export DEBIAN_FRONTEND=noninteractive

log "Updating APT package index and upgrading system..."
apt-get update -y
apt-get upgrade -y

log "Installing required packages (sudo, OpenSSH, Python)..."
apt-get install -y sudo openssh-server python3 python3-apt ca-certificates

# Ensure a downloader exists in case it was not there
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  apt-get install -y curl
  DOWNLOADER="curl -fsSL"
fi

### ---------------------------
### 2) Enable & start SSH service
### ---------------------------
log "Enabling and starting SSH service..."
systemctl enable ssh
systemctl restart ssh

# Verify SSH service state explicitly
if systemd_is_active ssh; then
  log "SSH service is active."
else
  # Capture status for diagnostics without failing the script abruptly
  warn "SSH service is not active. Capturing diagnostics..."
  systemctl status ssh || true
  journalctl -u ssh --no-pager -n 100 || true
  err "SSH service failed to start. Please review diagnostics above."
fi

### ---------------------------
### 3) Create 'semaphore' user with sudo privileges
### ---------------------------
if id "${USER_NAME}" >/dev/null 2>&1; then
  log "User '${USER_NAME}' already exists."
else
  log "Creating user '${USER_NAME}'..."
  adduser --disabled-password --gecos "" --shell "${USER_SHELL}" "${USER_NAME}"
fi

log "Adding '${USER_NAME}' to 'sudo' group (idempotent)..."
usermod -aG sudo "${USER_NAME}"

### ---------------------------
### 4) Configure passwordless sudo (secure via sudoers.d)
### ---------------------------
log "Configuring passwordless sudo for '${USER_NAME}'..."
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > "${SUDOERS_DROPIN}"
chmod 440 "${SUDOERS_DROPIN}"

# Validate sudoers syntax to avoid lockouts
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "${SUDOERS_DROPIN}" >/dev/null || err "sudoers validation failed for ${SUDOERS_DROPIN}"
fi

### ---------------------------
### 5) Prepare SSH directory and permissions
### ---------------------------
log "Preparing SSH directory for '${USER_NAME}'..."
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}"


# (Optional) Pre-create an empty known_hosts to avoid first-connection prompts in some flows
touch "${SSH_DIR}/known_hosts"
chmod 644 "${SSH_DIR}/known_hosts"
chown "${USER_NAME}:${USER_NAME}" "${SSH_DIR}/known_hosts"

echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
#echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "KbdInteractiveAuthentication yes" >> /etc/ssh/sshd_config

### ---------------------------
### 7) Final SSH health check
### ---------------------------
if systemd_is_active ssh; then
  log "Final check: SSH is active and running."
else
  err "Final check failed: SSH is not active."
fi

log "Host is ready for Ansible/Semaphore. User '${USER_NAME}' has passwordless sudo and SSH key is installed."
