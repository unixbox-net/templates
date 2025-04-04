#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/template-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

### Variables ###
SSH_REGEN_SERVICE="/etc/systemd/system/regenerate-ssh-hostkeys.service"
MACHINE_ID_RESET_SERVICE="/etc/systemd/system/regenerate-machine-id.service"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

trap 'error_exit "Script encountered an error."' ERR

log "Updating system..."
apt update && apt full-upgrade -y
apt autoremove -y && apt clean

log "Installing essentials..."
apt install -y vim sudo qemu-guest-agent cloud-init openssh-server

log "Configuring sudoers for 'debian' user..."
echo "debian ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debian
chmod 0440 /etc/sudoers.d/debian

log "Enabling QEMU Guest Agent..."
systemctl enable --now qemu-guest-agent

log "Configuring NTP..."
systemctl enable --now systemd-timesyncd
sed -i 's|^#NTP=.*|NTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org|' /etc/systemd/timesyncd.conf
systemctl restart systemd-timesyncd

log "Creating regenerate-machine-id.service..."
cat > "$MACHINE_ID_RESET_SERVICE" <<EOF
[Unit]
Description=Regenerate machine-id
Before=cloud-init.service
ConditionPathExists=!/etc/machine-id

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup && ln -sf /etc/machine-id /var/lib/dbus/machine-id'

[Install]
WantedBy=multi-user.target
EOF

log "Creating regenerate-ssh-hostkeys.service..."
cat > "$SSH_REGEN_SERVICE" <<EOF
[Unit]
Description=Regenerate SSH host keys
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rm -f /etc/ssh/ssh_host_* && ssh-keygen -A'

[Install]
WantedBy=multi-user.target
EOF

log "Enabling regeneration services..."
systemctl enable regenerate-machine-id.service
systemctl enable regenerate-ssh-hostkeys.service

log "Configuring cloud-init defaults..."
cat > /etc/cloud/cloud.cfg.d/99-custom.cfg <<EOF
preserve_hostname: false
ssh_deletekeys: true
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']
EOF

log "Setting cloud-init to use Proxmox clone name as hostname..."
cat > /etc/cloud/cloud.cfg.d/99-auto-hostname.cfg <<EOF
# Automatically generate FQDN from Proxmox clone name
preserve_hostname: false
fqdn: "{{ v1.vm_name }}.lan.xaeon.io"
EOF

log "Final cleanup before shutdown..."

# Clear host identity
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Clear shell history
history -c && history -w

log "Template setup complete. You can now shut down and convert this VM to a template."
