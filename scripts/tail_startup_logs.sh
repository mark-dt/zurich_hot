#!/usr/bin/env bash
set -euo pipefail

# Stream startup logs from VMs via SSH.
# Usage: ./scripts/tail_startup_logs.sh [csv_file] [log_file]
#
# Defaults:
#   csv_file  = ssh_credentials.csv
#   log_file  = /var/log/startup-parts.log

CSV_FILE="${1:-ssh_credentials.csv}"
LOG_FILE="${2:-/var/log/startup-parts.log}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
MAX_RETRIES="${MAX_RETRIES:-30}"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: $CSV_FILE" >&2
  exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is required but not installed." >&2
  echo "  macOS:          brew install esolitos/ipa/sshpass" >&2
  echo "  Debian/Ubuntu:  sudo apt-get install sshpass" >&2
  exit 2
fi

# Read CSV lines (skip header)
LINES=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ -z "$_line" ]] && continue
  LINES+=("$_line")
done < <(tail -n +2 "$CSV_FILE" | sed 's/\r$//' | sed '/^[[:space:]]*$/d')

if [[ ${#LINES[@]} -eq 0 ]]; then
  echo "ERROR: No hosts found in $CSV_FILE" >&2
  exit 1
fi

echo "Tailing ${LOG_FILE} on ${#LINES[@]} host(s)..."
echo "Press Ctrl-C to stop."
echo ""

# Launch a tail -f for each host in the background, prefixed with hostname
PIDS=()
for line in "${LINES[@]}"; do
  IFS=',' read -r username password ip _ssh_cmd <<< "$line"
  username="${username//\"/}"
  password="${password//\"/}"
  ip="${ip//\"/}"
  host="${username}@${ip}"

  (
    # Retry SSH until the VM is reachable (it may still be rebooting)
    for attempt in $(seq 1 "$MAX_RETRIES"); do
      sshpass -p "$password" \
        ssh -T \
          -o PubkeyAuthentication=no \
          -o PreferredAuthentications=password \
          -o ConnectTimeout="$SSH_TIMEOUT" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          "$host" "tail -n 50 -f ${LOG_FILE} 2>/dev/null || echo 'Waiting for log file...'" \
        2>/dev/null \
        | sed "s/^/[${username}] /" \
        && break
      sleep 5
    done
  ) &
  PIDS+=($!)
  echo "Started tailing ${host}..."
done

# Clean up all background processes on exit
cleanup() {
  echo ""
  echo "Stopping..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null
}
trap cleanup INT TERM EXIT

# Wait for all background tails
wait
