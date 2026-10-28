#!/usr/bin/env bash
# healthmon.sh - Server Health Monitor for Ubuntu
# Checks CPU, memory, disk, load, services, network and failed SSH logins.
# Usage: healthmon.sh [--quiet] [--html] [--watch SECONDS] [--help]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HEALTHMON_CONF:-/etc/healthmon/healthmon.conf}"
[[ -f "$CONF" ]] || CONF="$SCRIPT_DIR/healthmon.conf"

# ---------- defaults (override in healthmon.conf) ----------
CPU_WARN=70;  CPU_CRIT=90
MEM_WARN=75;  MEM_CRIT=90
DISK_WARN=80; DISK_CRIT=90
LOAD_WARN=1.0; LOAD_CRIT=2.0          # load average per CPU core
SERVICES="ssh cron"                    # systemd services that must be active
PING_HOST="8.8.8.8"
FAILED_LOGIN_WARN=10                   # failed SSH logins in the last hour
ALERT_EMAIL=""                         # needs 'mailutils' + working MTA
WEBHOOK_URL=""                         # Slack/Discord-style webhook (optional)
if [[ $EUID -eq 0 ]]; then LOG_DIR="/var/log/healthmon"; else LOG_DIR="$HOME/healthmon-logs"; fi
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"

QUIET=0; HTML=0; WATCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --html)  HTML=1 ;;
    --watch) WATCH="${2:-5}"; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR" 2>/dev/null || { echo "Cannot create $LOG_DIR"; exit 1; }
CSV="$LOG_DIR/metrics.csv"; ALERT_LOG="$LOG_DIR/alerts.log"; STATE="$LOG_DIR/.last_state"

if [[ -t 1 ]]; then R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[1m'; N=$'\e[0m'; else R=""; Y=""; G=""; B=""; N=""; fi

# ---------- helpers ----------
level() { awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{ if (v>=c) print "CRIT"; else if (v>=w) print "WARN"; else print "OK" }'; }

cpu_usage() {
  local _ u1 n1 s1 i1 w1 q1 sq1 u2 n2 s2 i2 w2 q2 sq2
  read -r _ u1 n1 s1 i1 w1 q1 sq1 _ < /proc/stat; sleep 1
  read -r _ u2 n2 s2 i2 w2 q2 sq2 _ < /proc/stat
  local dt=$(( (u2+n2+s2+i2+w2+q2+sq2) - (u1+n1+s1+i1+w1+q1+sq1) ))
  local di=$(( (i2+w2) - (i1+w1) ))
  (( dt == 0 )) && echo 0 || echo $(( 100 * (dt - di) / dt ))
}
mem_usage() { awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo; }

colour() { case "$1" in OK) printf '%s' "$G";; WARN) printf '%s' "$Y";; CRIT) printf '%s' "$R";; esac; }

run_checks() {
  R_NAME=(); R_VAL=(); R_STATUS=(); ALERTS=(); OVERALL="OK"
  record() {
    R_NAME+=("$1"); R_VAL+=("$2"); R_STATUS+=("$3")
    case "$3" in
      CRIT) OVERALL="CRIT"; ALERTS+=("CRIT: $1 = $2") ;;
      WARN) [[ $OVERALL != CRIT ]] && OVERALL="WARN"; ALERTS+=("WARN: $1 = $2") ;;
    esac
  }

  CPU=$(cpu_usage);  record "CPU usage" "${CPU}%" "$(level "$CPU" "$CPU_WARN" "$CPU_CRIT")"
  MEM=$(mem_usage);  record "Memory usage" "${MEM}%" "$(level "$MEM" "$MEM_WARN" "$MEM_CRIT")"

  CORES=$(nproc); LOAD1=$(cut -d' ' -f1 /proc/loadavg)
  PERCORE=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%.2f", l/c}')
  record "Load (1m, per core)" "$PERCORE" "$(level "$PERCORE" "$LOAD_WARN" "$LOAD_CRIT")"

  DISK_ROOT=0
  while read -r pct mount; do
    pct=${pct%\%}; [[ "$mount" == "/" ]] && DISK_ROOT=$pct
    record "Disk $mount" "${pct}%" "$(level "$pct" "$DISK_WARN" "$DISK_CRIT")"
  done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1{print $5, $6}')

  for svc in $SERVICES; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then record "Service $svc" "active" "OK"
    else record "Service $svc" "DOWN" "CRIT"; fi
  done

  if ping -c1 -W2 "$PING_HOST" >/dev/null 2>&1; then record "Network ($PING_HOST)" "reachable" "OK"
  else record "Network ($PING_HOST)" "unreachable" "CRIT"; fi

  FAILS=$(journalctl -u ssh --since "1 hour ago" --no-pager 2>/dev/null | grep -c "Failed password" || true)
  FAILS=${FAILS:-0}
  record "Failed SSH logins (1h)" "$FAILS" "$(level "$FAILS" "$FAILED_LOGIN_WARN" 1000000)"
}

print_report() {
  echo "${B}=== Server Health Report: $(hostname) | $(date '+%F %T') ===${N}"
  echo "Uptime : $(uptime -p)   |   Kernel: $(uname -r)   |   Cores: $CORES"
  echo "-----------------------------------------------------"
  for i in "${!R_NAME[@]}"; do
    printf "%-28s %-14s %s%s%s\n" "${R_NAME[$i]}" "${R_VAL[$i]}" "$(colour "${R_STATUS[$i]}")" "${R_STATUS[$i]}" "$N"
  done
  echo "-----------------------------------------------------"
  echo "Top 5 processes by CPU:"
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -6
  echo "-----------------------------------------------------"
  echo "Overall: $(colour "$OVERALL")${B}${OVERALL}${N}"
}

write_html() {
  local f="$LOG_DIR/report.html" rows="" i c
  for i in "${!R_NAME[@]}"; do
    case "${R_STATUS[$i]}" in OK) c="#d4edda";; WARN) c="#fff3cd";; *) c="#f8d7da";; esac
    rows+="<tr style=\"background:$c\"><td>${R_NAME[$i]}</td><td>${R_VAL[$i]}</td><td>${R_STATUS[$i]}</td></tr>"
  done
  cat > "$f" <<HTMLEOF
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="60">
<title>Health: $(hostname)</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem}
table{border-collapse:collapse;width:100%}td,th{padding:8px 12px;border:1px solid #ccc;text-align:left}</style></head>
<body><h1>Server Health: $(hostname)</h1>
<p>Updated $(date '+%F %T') &middot; $(uptime -p) &middot; Overall: <b>$OVERALL</b></p>
<table><tr><th>Check</th><th>Value</th><th>Status</th></tr>$rows</table></body></html>
HTMLEOF
}

send_alert() {
  local msg="[healthmon] $(hostname): $1"$'\n'"$(printf '%s\n' "${ALERTS[@]:-}")"
  echo "$(date '+%F %T') $msg" >> "$ALERT_LOG"
  if [[ -n "$ALERT_EMAIL" ]] && command -v mail >/dev/null; then
    echo "$msg" | mail -s "[healthmon] $(hostname) is $OVERALL" "$ALERT_EMAIL"
  fi
  if [[ -n "$WEBHOOK_URL" ]] && command -v curl >/dev/null; then
    curl -s -m 5 -X POST -H 'Content-Type: application/json' \
      -d "{\"text\": \"$(echo "$msg" | tr '\n' ' ' | sed 's/"/\\"/g')\"}" "$WEBHOOK_URL" >/dev/null || true
  fi
}

once() {
  run_checks
  [[ ! -f "$CSV" ]] && echo "timestamp,cpu_pct,mem_pct,load_per_core,disk_root_pct,overall" > "$CSV"
  echo "$(date '+%F %T'),$CPU,$MEM,$PERCORE,$DISK_ROOT,$OVERALL" >> "$CSV"
  [[ $QUIET -eq 0 ]] && print_report
  [[ $HTML -eq 1 ]] && write_html
  # alert only when overall status changes (avoids spam)
  local prev; prev=$(cat "$STATE" 2>/dev/null || echo OK)
  if [[ "$prev" != "$OVERALL" ]]; then
    if [[ "$OVERALL" == "OK" ]]; then send_alert "RECOVERED (was $prev)"; else send_alert "status is $OVERALL"; fi
  fi
  echo "$OVERALL" > "$STATE"
}

if (( WATCH > 0 )); then
  while true; do clear; once; sleep "$WATCH"; done
else
  once
fi
[[ "$OVERALL" == "OK" ]] && exit 0 || { [[ "$OVERALL" == "WARN" ]] && exit 1 || exit 2; }
