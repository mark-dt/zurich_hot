#!/usr/bin/env bash
set -euo pipefail

# Prints nip.io URLs and ArgoCD passwords for each VM.
# Usage: ./scripts/get_vm_info.sh [csv_file]

CSV_FILE="${1:-ssh_credentials.csv}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
MAX_RETRIES="${MAX_RETRIES:-30}"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: $CSV_FILE" >&2
  exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is required but not installed." >&2
  exit 2
fi

LINES=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ -z "$_line" ]] && continue
  LINES+=("$_line")
done < <(tail -n +2 "$CSV_FILE" | sed 's/\r$//' | sed '/^[[:space:]]*$/d')

if [[ ${#LINES[@]} -eq 0 ]]; then
  echo "ERROR: No hosts found in $CSV_FILE" >&2
  exit 1
fi

for line in "${LINES[@]}"; do
  IFS=',' read -r username password ip _ssh_cmd <<< "$line"
  username="${username//\"/}"
  password="${password//\"/}"
  ip="${ip//\"/}"
  host="${username}@${ip}"

  echo "============================================"
  echo "  ${host}"
  echo "============================================"
  echo "  SSH password: ${password}"
  echo ""

  # Retry until VM is reachable
  result=""
  for attempt in $(seq 1 "$MAX_RETRIES"); do
    result="$(sshpass -p "$password" \
      ssh -T \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$host" "
          ARGOCD_PW=\$(k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo 'not available yet')
          INGRESSES=\$(k3s kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.rules[0].host}{\"\\n\"}{end}' 2>/dev/null || true)
          echo \"ARGOCD_PW:\${ARGOCD_PW}\"
          echo \"\${INGRESSES}\"
        " 2>/dev/null)" && break
    sleep 5
  done

  if [[ -z "$result" ]]; then
    echo "  (VM not reachable)"
    echo ""
    continue
  fi

  argocd_pw="$(echo "$result" | grep '^ARGOCD_PW:' | cut -d: -f2-)"
  echo "  ArgoCD:  admin / ${argocd_pw}"
  echo ""
  echo "  URLs:"

  echo "$result" | grep -v '^ARGOCD_PW:' | while IFS=' ' read -r ns_name host_url; do
    [[ -z "$host_url" ]] && continue
    echo "    https://${host_url}  (${ns_name})"
  done

  echo ""
done
