#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
systemctl disable --now healthmon.timer || true
rm -f /etc/systemd/system/healthmon.{service,timer}
rm -rf /opt/healthmon
systemctl daemon-reload
echo "Removed. Config (/etc/healthmon) and logs (/var/log/healthmon) kept."
