
#!/bin/bash
# Purpose: Generate an SSH key pair on the Semaphore UI server
# This script creates a secure RSA key pair without a passphrase
# and displays the public key for distribution to target hosts.
# bash -c "$(curl -fsSL # bash -c "$(curl -fsSL https://github.com/m3d1/linux-scripts/blob/main/Ansible/host%20preparation/prep-semaphore-host.sh)")"

set -euo pipefail

### ---------------------------
### Configuration
### ---------------------------
KEY_PATH="/home/semaphore/.ssh/id_rsa"
KEY_COMMENT="semaphore@server"

### ---------------------------
### 1) Prepare .ssh directory
### ---------------------------
mkdir -p /home/semaphore/.ssh
chmod 700 /home/semaphore/.ssh

### ---------------------------
### 2) Generate SSH key pair
### ---------------------------
ssh-keygen -t rsa -b 4096 -C "$KEY_COMMENT" -f "$KEY_PATH" -N ""

### ---------------------------
### 3) Display the public key
### ---------------------------
echo "✅ SSH key pair generated successfully."
echo "Public key (copy this to your target hosts):"
cat "${KEY_PATH}.pub"

### ---------------------------
### 4) Set correct permissions
### ---------------------------
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.chmod 644 "${KEY_PATH}.pub"

echo "✅ Private key stored at: $KEY_PATH"
