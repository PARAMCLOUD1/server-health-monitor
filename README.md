# Server Health Monitor (Ubuntu)

A lightweight monitoring tool written in Bash. It checks the health of an Ubuntu server, logs metrics, raises alerts, and produces an auto-refreshing HTML dashboard. It runs automatically through a systemd timer.

## What it monitors
| Check | Source |
|---|---|
| CPU usage % | `/proc/stat` (two samples, 1s apart) |
| Memory usage % | `/proc/meminfo` (MemAvailable) |
| Load average per core | `/proc/loadavg`, `nproc` |
| Disk usage per mount | `df` |
| Critical services (ssh, cron, nginx...) | `systemctl is-active` |
| Network reachability | `ping` |
| Failed SSH logins (last hour) | `journalctl -u ssh` |
| Top 5 CPU processes | `ps` |

Each check is OK / WARN / CRIT based on thresholds in `healthmon.conf`.

## Features
- Colored terminal report, `--watch N` live mode
- CSV history (`metrics.csv`) for graphs, `alerts.log` for events
- Alerts by email (`mailutils`) or Slack/Discord webhook, sent only when status changes (and on recovery)
- HTML dashboard (`report.html`), auto-refresh every 60s
- Exit codes 0/1/2 (OK/WARN/CRIT) so it works inside other scripts and CI
- Installed as a systemd service + timer (every 5 minutes)

## Run it
```bash
chmod +x healthmon.sh
./healthmon.sh              # one-time report
./healthmon.sh --watch 5    # live, refresh every 5s
./healthmon.sh --html       # also write report.html
```

## Install as a service
```bash
sudo ./install.sh
systemctl list-timers healthmon.timer
sudo journalctl -u healthmon.service
sudo nano /etc/healthmon/healthmon.conf   # edit thresholds / services
```
Logs and report: `/var/log/healthmon/`

View the dashboard in a browser:
```bash
cd /var/log/healthmon && python3 -m http.server 8080
# open http://<server-ip>:8080/report.html
```

## Test the alerts (stress test)
```bash
sudo apt install stress-ng
stress-ng --cpu 4 --timeout 60s &
./healthmon.sh --watch 5            # CPU should go WARN/CRIT
sudo systemctl stop cron            # service check goes CRIT
fallocate -l 5G /tmp/bigfile        # disk usage rises
```

## Email alerts
```bash
sudo apt install mailutils
# set ALERT_EMAIL="you@example.com" in /etc/healthmon/healthmon.conf
```

## Project structure
```
server-health-monitor/
├── healthmon.sh        main script
├── healthmon.conf      thresholds and settings
├── install.sh          sets up /opt, /etc, systemd timer
├── uninstall.sh
├── systemd/
│   ├── healthmon.service
│   └── healthmon.timer
└── README.md
```

## Ideas to extend (for a higher grade)
1. Plot `metrics.csv` with Python (matplotlib) or Grafana
2. Auto-restart a failed service and log the action
3. Monitor Docker containers (`docker ps`)
4. Ansible playbook to deploy to many servers
5. Export metrics for Prometheus (node_exporter textfile)
