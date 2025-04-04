#!/bin/bash
DEFAULT_DOMAIN="lan.xaeon.io"

read -rp "Enter new hostname (short or FQDN): " USER_INPUT

# Check if user entered a short name or FQDN
if [[ "$USER_INPUT" == *.* ]]; then
    NEW_HOSTNAME="$USER_INPUT"
else
    NEW_HOSTNAME="${USER_INPUT}.${DEFAULT_DOMAIN}"
fi

# Extract short name (before first dot)
SHORT_HOSTNAME=$(echo "$NEW_HOSTNAME" | cut -d. -f1)

echo
echo "Setting new hostname to: $NEW_HOSTNAME"
sudo hostnamectl set-hostname "$NEW_HOSTNAME" --static

echo "Updating /etc/hosts..."

# Backup /etc/hosts
sudo cp /etc/hosts /etc/hosts.bak

# Replace or add 127.0.1.1 line
if grep -q "^127.0.1.1" /etc/hosts; then
    sudo sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME $SHORT_HOSTNAME/" /etc/hosts
else
    echo -e "127.0.1.1\t$NEW_HOSTNAME $SHORT_HOSTNAME" | sudo tee -a /etc/hosts
fi

echo "Hostname changed to: $NEW_HOSTNAME"
echo "You may need to restart your session or reboot for all changes to take effect."

read -rp "Reboot now? (y/N): " REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    sudo reboot
else
    echo "Done. Reboot when ready to apply hostname fully system-wide."
fi
