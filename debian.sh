#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/template-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

### Variables ###
MACHINE_ID_RESET_SERVICE="/etc/systemd/system/regenerate-machine-id.service"
CLOUD_CFG_FILE="/etc/cloud/cloud.cfg.d/90-xaeon-defaults.cfg"
FQDN_FIX_CFG="/etc/cloud/cloud.cfg.d/91-fqdn-fix.cfg"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "❌ ERROR: $1"
    exit 1
}

trap 'error_exit \"Script encountered an error.\"' ERR

log "🔄 Updating system..."
apt update && apt full-upgrade -y
apt autoremove -y && apt clean

log "📦 Installing essentials..."
apt install -y vim sudo qemu-guest-agent cloud-init openssh-server

log "🔐 Configuring sudoers for 'debian' user..."
echo "debian ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debian
chmod 0440 /etc/sudoers.d/debian

log "📡 Enabling QEMU Guest Agent..."
systemctl enable --now qemu-guest-agent

log "🧭 Setting Cloud-Init base config..."
cat > "$CLOUD_CFG_FILE" <<EOF
# Cloud-Init Global Defaults (Xaeon)
preserve_hostname: false
timezone: America/Toronto
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']
ntp:
  enabled: true
  servers:
    - 0.ca.pool.ntp.org
    - 1.ca.pool.ntp.org
EOF

# Override preserve_hostname if already set in base config
if grep -q '^preserve_hostname:' /etc/cloud/cloud.cfg; then
    sed -i 's/^preserve_hostname:.*/preserve_hostname: false/' /etc/cloud/cloud.cfg
else
    echo "preserve_hostname: false" >> /etc/cloud/cloud.cfg
fi

log "🆔 Creating regenerate-machine-id.service..."
cat > "$MACHINE_ID_RESET_SERVICE" <<EOF
[Unit]
Description=Regenerate machine-id
Before=cloud-init.service
ConditionPathExists=!/etc/machine-id

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
rm -f /etc/machine-id /var/lib/dbus/machine-id &&
systemd-machine-id-setup &&
ln -sf /etc/machine-id /var/lib/dbus/machine-id
'

[Install]
WantedBy=multi-user.target
EOF

systemctl enable regenerate-machine-id.service

log "🌐 Configuring FQDN enforcement via Cloud-Init..."
cat > "$FQDN_FIX_CFG" <<'EOF'
# Appends domain to Proxmox-injected hostname automatically
preserve_hostname: false

fqdn: !!python/unicode
  "%s.lan.xaeon.io" % (open("/etc/hostname").read().strip())

runcmd:
  - sed -i '/127.0.1.1/d' /etc/hosts
  - echo "127.0.1.1 $(cat /etc/hostname).lan.xaeon.io $(cat /etc/hostname)" >> /etc/hosts
EOF

log "🧼 Cleaning up Cloud-Init state for fresh boot..."
cloud-init clean --logs

log "🧹 Final cleanup before template shutdown..."
# Important: Do not remove host SSH keys if cloud-init won’t regen them
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Remove delete-key directive if present (precaution)
sed -i '/ssh_deletekeys:/d' "$CLOUD_CFG_FILE" || true

# Clear shell history
history -c && history -w

log "✅ Template prep complete. You may now shut this VM down and convert it to a template."
