#!/usr/bin/env bash
# Uninstall everything install-matrix.sh created.
# Usage: sudo bash uninstall-matrix.sh
set -uo pipefail
systemctl disable --now matrix-synapse 2>/dev/null
rm -rf /opt/synapse /opt/synapse-admin
rm -f /etc/systemd/system/matrix-synapse.service
rm -f /etc/nginx/sites-enabled/matrix /etc/nginx/sites-available/matrix
rm -f /root/matrix-credentials.txt
rm -f /etc/ssl/certs/matrix.crt /etc/ssl/private/matrix.key
systemctl daemon-reload
if systemctl is-active --quiet postgresql; then
  sudo -u postgres psql -c 'DROP DATABASE IF EXISTS synapse' >/dev/null 2>&1
  sudo -u postgres psql -c 'DROP ROLE IF EXISTS synapse' >/dev/null 2>&1
fi
userdel synapse 2>/dev/null
groupdel synapse 2>/dev/null
systemctl reload nginx 2>/dev/null
echo "reset done"
