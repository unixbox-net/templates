#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/template-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

### Variables ###
MACHINE_ID_RESET_SERVICE="/etc/systemd/system/regenerate-machine-id.service"
CLOUD_INIT_SCRIPT_DIR="/var/lib/cloud/scripts/per-instance"
HOSTNAME_SCRIPT="$CLOUD_INIT_SCRIPT_DIR/99-force-hostname.sh"
CLOUD_CFG_FILE="/etc/cloud/cloud.cfg.d/90-xaeon-defaults.cfg"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "❌ ERROR: $1"
    exit 1
}

trap 'error_exit "Script encountered an error."' ERR

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

log "🧭 Setting Cloud-Init defaults..."
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

# Backup override in case default config conflicts
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

log "🌐 Installing strict FQDN enforcement..."
mkdir -p "$CLOUD_INIT_SCRIPT_DIR"

cat > "$HOSTNAME_SCRIPT" <<'EOF'
#!/bin/bash
LOG_FILE="/var/log/cloud-init.log"
DOMAIN="lan.xaeon.io"

NAME=$(grep -oP '"local-hostname":\s*"\K[^"]+' /var/lib/cloud/data/instance-data.json 2>/dev/null)

if [[ -z "$NAME" ]]; then
  echo "[hostname-init] ❌ No hostname found in metadata. Dumping metadata for debug:" | tee -a "$LOG_FILE"
  cat /var/lib/cloud/data/instance-data.json >> "$LOG_FILE"
  exit 1
fi

FQDN="${NAME}.${DOMAIN}"

echo "[hostname-init] ✅ Setting hostname to $FQDN" | tee -a "$LOG_FILE"
hostnamectl set-hostname "$FQDN"

sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 $FQDN $NAME" >> /etc/hosts

echo "[hostname-init] ✅ Hostname applied and /etc/hosts updated." | tee -a "$LOG_FILE"
EOF

chmod +x "$HOSTNAME_SCRIPT"

log "🧼 Resetting Cloud-Init for next boot..."
cloud-init clean --logs

log "🧹 Final cleanup before template shutdown..."
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Remove delete-key directive just in case
sed -i '/ssh_deletekeys:/d' "$CLOUD_CFG_FILE"

history -c && history -w

log "✅ Template prep complete. You may now shut this VM down and convert it to a template."
