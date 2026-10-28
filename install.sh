#!/usr/bin/env bash
# Installs healthmon as a systemd timer on Ubuntu. Run: sudo ./install.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d /opt/healthmon /etc/healthmon /var/log/healthmon
install -m 755 "$DIR/healthmon.sh" /opt/healthmon/healthmon.sh
[[ -f /etc/healthmon/healthmon.conf ]] || install -m 644 "$DIR/healthmon.conf" /etc/healthmon/healthmon.conf
install -m 644 "$DIR/systemd/healthmon.service" /etc/systemd/system/
install -m 644 "$DIR/systemd/healthmon.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now healthmon.timer
echo "Installed. Check: systemctl list-timers healthmon.timer"
echo "Logs/report: /var/log/healthmon/"
