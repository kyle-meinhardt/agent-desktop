#!/bin/bash
set -euo pipefail

relay_dir="$(cd "$(dirname "$0")" && pwd)"
log_dir="$1/screen-sharing"
label=local.agent-desktop.screen-forward
endpoint=127.0.0.1:5903

relay_pid() {
  /bin/launchctl list | /usr/bin/awk -v label="$label" '$3 == label && $1 ~ /^[0-9]+$/ { print $1; exit }'
}

if ! /bin/launchctl list "$label" >/dev/null 2>&1; then
  python="$(command -v python3 || true)"
  if [[ -z "$python" ]] || ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
    echo 'Native Screen Sharing requires Python 3.11 or newer.' >&2
    exit 1
  fi
  (umask 077; mkdir -p "$log_dir")
  /bin/launchctl submit -l "$label" -o "$log_dir/session.log" -e "$log_dir/relay.log" -- \
    "$python" "$relay_dir/screen-sharing-relay.py" || /bin/launchctl list "$label" >/dev/null 2>&1
elif [[ -z "$(relay_pid)" ]]; then
  /bin/launchctl kickstart "gui/$UID/$label"
fi

for (( attempt=0; attempt<20; attempt++ )); do
  pid="$(relay_pid)"
  if [[ -n "$pid" ]] && /usr/sbin/lsof -nP -a -p "$pid" "-iTCP@$endpoint" -sTCP:LISTEN -t >/dev/null 2>&1; then
    printf 'vnc://agent@%s\n' "$endpoint"
    exit 0
  fi
  /bin/sleep 0.25
done

echo "Agent Desktop relay did not start on $endpoint. Check $log_dir/relay.log." >&2
exit 1
