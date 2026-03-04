#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-hosts.csv}"
COMMANDS_FILE="${2:-commands.sh}"

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

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is required but not installed." >&2
  echo "  Debian/Ubuntu: sudo apt-get install sshpass" >&2
  echo "  RHEL/CentOS:   sudo yum install sshpass" >&2
  echo "  macOS:          brew install esolitos/ipa/sshpass" >&2
  exit 2
fi

COMMANDS="$(cat "$COMMANDS_FILE")"

# Read CSV lines (skip header), strip CRLF and blank lines
# Use a while-read loop instead of mapfile for macOS Bash 3 compatibility
LINES=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ -z "$_line" ]] && continue
  LINES+=("$_line")
done < <(tail -n +2 "$CSV_FILE" | sed 's/\r$//' | sed '/^[[:space:]]*$/d')

if [[ ${#LINES[@]} -eq 0 ]]; then
  echo "ERROR: No hosts found in $CSV_FILE" >&2
  exit 1
fi

echo "Running commands on ${#LINES[@]} host(s) sequentially"

# Track results for summary
RESULT_DIR="$LOG_DIR/.results"
rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

export SSH_TIMEOUT CMD_TIMEOUT LOG_DIR COMMANDS RESULT_DIR

# Run in parallel using a temp script for portability
RUNNER="$(mktemp)"
trap 'rm -f "$RUNNER"' EXIT

cat > "$RUNNER" <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

# Portable timestamp (works on both macOS and GNU date)
timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

line="$1"
username="" password="" ip="" ssh_cmd=""

IFS=',' read -r username password ip ssh_cmd <<< "$line"

username="${username//\"/}"
password="${password//\"/}"
ip="${ip//\"/}"
ssh_cmd="${ssh_cmd//\"/}"

if [[ -z "$username" || -z "$password" || -z "$ip" ]]; then
  echo "SKIP: missing fields in line: $line" >&2
  exit 0
fi

host="${username}@${ip}"
label="$(echo "$host" | tr '@.' '__')"
out="$LOG_DIR/${label}.out.log"
err="$LOG_DIR/${label}.err.log"

# The ssh_cmd column is informational (e.g. "ssh user@host"), not a remote command to run.
# Always use COMMANDS from the commands file.
cmds="$COMMANDS"

echo "[$(timestamp)] START $host"

MAX_RETRIES=2
rc=0
for attempt in $(seq 1 "$MAX_RETRIES"); do
  rc=0
  sshpass -p "$password" \
      ssh -T \
          -o PubkeyAuthentication=no \
          -o PreferredAuthentications=password \
          -o ConnectTimeout="$SSH_TIMEOUT" \
          -o ServerAliveInterval=15 \
          -o ServerAliveCountMax=2 \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          "$host" "bash -c $(printf '%q' "$cmds")" \
      > >(tee -a "$out") 2> >(tee -a "$err" >&2) || rc=$?
  if [[ $rc -eq 0 ]]; then break; fi
  echo "  RETRY $host (attempt $attempt/$MAX_RETRIES, rc=$rc)"
  sleep 2
done

echo "[$(timestamp)] END $host rc=$rc" >> "$out"
echo "$rc" > "$RESULT_DIR/$label"

if [[ $rc -eq 0 ]]; then
  echo "  OK   $host"
else
  echo "  FAIL $host (rc=$rc, see $err)"
fi

exit 0
SCRIPT
chmod +x "$RUNNER"

for line in "${LINES[@]}"; do
  "$RUNNER" "$line"
done

# Summary
echo ""
echo "==== SUMMARY ===="
ok=0
fail=0
for f in "$RESULT_DIR"/*; do
  label="$(basename "$f")"
  rc="$(cat "$f")"
  if [[ "$rc" == "0" ]]; then
    echo "  OK   $label"
    ((ok++))
  else
    echo "  FAIL $label (rc=$rc)"
    ((fail++))
  fi
done
echo "---- $ok ok, $fail failed out of $((ok + fail)) hosts ----"
echo "Logs in: $LOG_DIR/"
