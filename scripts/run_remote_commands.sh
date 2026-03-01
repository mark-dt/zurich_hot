#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-hosts.csv}"
COMMANDS_FILE="${2:-commands.sh}"

PARALLEL="${PARALLEL:-10}"         # max parallel connections
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"   # connect timeout seconds
CMD_TIMEOUT="${CMD_TIMEOUT:-120}"  # per-host command timeout seconds
LOG_DIR="${LOG_DIR:-./logs}"

mkdir -p "$LOG_DIR"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: $CSV_FILE" >&2
  exit 1
fi
if [[ ! -f "$COMMANDS_FILE" ]]; then
  echo "ERROR: Commands file not found: $COMMANDS_FILE" >&2
  exit 1
fi

# Ensure sshpass exists (since you're using passwords)
if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is required for password auth but is not installed." >&2
  echo "Install:" >&2
  echo "  Debian/Ubuntu: sudo apt-get install sshpass" >&2
  echo "  RHEL/CentOS:   sudo yum install sshpass" >&2
  exit 2
fi

# Read commands (preserve newlines)
COMMANDS="$(cat "$COMMANDS_FILE")"

# Read CSV lines (skip header), handle CRLF, drop empty lines
mapfile -t LINES < <(tail -n +2 "$CSV_FILE" | sed 's/\r$//' | sed '/^\s*$/d')

run_one() {
  local line="$1"
  local username password ip ssh_cmd
  local host label out err rc

  IFS=',' read -r username password ip ssh_cmd <<< "$line"

  # Remove surrounding quotes if present
  username="${username//\"/}"
  password="${password//\"/}"
  ip="${ip//\"/}"
  ssh_cmd="${ssh_cmd//\"/}"

  # Basic validation
  if [[ -z "$username" || -z "$password" || -z "$ip" ]]; then
    echo "ERROR: Missing username/password/ip in line: $line" >&2
    return 3
  fi

  host="${username}@${ip}"
  label="$(echo "$host" | tr '@' '_' | tr '.' '_' )"
  out="$LOG_DIR/${label}.out.log"
  err="$LOG_DIR/${label}.err.log"

  echo "[$(date -Is)] START $host" >>"$out"

  # Use sshpass; run commands via stdin
  # - StrictHostKeyChecking=accept-new keeps it non-interactive while still tracking known_hosts
  # - UserKnownHostsFile isolates known_hosts to your LOG_DIR
  if timeout "$CMD_TIMEOUT" \
      sshpass -p "$password" \
      ssh -o PubkeyAuthentication=no \
          -o PreferredAuthentications=password \
          -o ConnectTimeout="$SSH_TIMEOUT" \
          -o ServerAliveInterval=15 \
          -o ServerAliveCountMax=2 \
          -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$LOG_DIR/known_hosts" \
          "${username}@${ip}" "bash -s" \
      >"$out" 2>"$err" <<<"$COMMANDS"
  then
    rc=0
  else
    rc=$?
  fi

  echo "[$(date -Is)] END $host rc=$rc" >>"$out"
  return "$rc"
}

export -f run_one
export SSH_TIMEOUT CMD_TIMEOUT LOG_DIR COMMANDS

# Run in parallel. The "bash -c" wrapper ensures the function is available in each subshell.
printf "%s\n" "${LINES[@]}" | xargs -P "$PARALLEL" -n 1 -I {} bash -c 'run_one "$@"' _ "{}"

# Summary
echo "==== SUMMARY ===="
shopt -s nullglob
for f in "$LOG_DIR"/*.out.log; do
  if grep -q "rc=0" "$f"; then
    echo "OK   - $(basename "$f" .out.log)"
  else
    echo "FAIL - $(basename "$f" .out.log) (see corresponding .err.log)"
  fi
done
