#!/usr/bin/env bash
set -euo pipefail

# Deploy bad release or rollback across all workshop VMs
#
# Usage:
#   ./scripts/deploy-bad-release.sh                        # deploy bad release (default rate=0.7)
#   ./scripts/deploy-bad-release.sh deploy-bad-release 0.5 # deploy with custom failure rate
#   ./scripts/deploy-bad-release.sh rollback               # rollback (rate=0)

CSV_FILE="../${CSV_FILE:-ssh_credentials.csv}"
ACTION="${1:-deploy-bad-release}"
FAILURE_RATE="${2:-0.7}"

DT_ENV_URL="https://ggg43721.sprint.dynatracelabs.com"
DT_API_TOKEN="REDACTED_DT_API_TOKEN"

if [[ "$ACTION" == "rollback" ]]; then
  FAILURE_RATE="0"
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: $CSV_FILE" >&2
  exit 1
fi

# Read CSV (skip header)
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  LINES+=("$line")
done < <(tail -n +2 "$CSV_FILE" | sed 's/\r$//' | sed '/^[[:space:]]*$/d')

echo "Action: $ACTION | Failure rate: $FAILURE_RATE | VMs: ${#LINES[@]}"
echo ""

for line in "${LINES[@]}"; do
  IFS=',' read -r username password ip ssh_cmd <<< "$line"
  username="${username//\"/}"
  password="${password//\"/}"
  ip="${ip//\"/}"

  VM_HOST="${username}@${ip}"
  # Derive K8_CLUSTER from VM hostname pattern (simple-vm-N)
  VM_INDEX="${username#user}"
  K8_CLUSTER="dynakube-simple-vm-${VM_INDEX}"
  WORKSHOP_URL="https://workshop.${ip}.nip.io"

  echo "==> ${VM_HOST} (cluster: ${K8_CLUSTER})"

  # Set failure rate via workshop frontend
  echo "  Setting failure rate to ${FAILURE_RATE}..."
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"rate\":${FAILURE_RATE}}" \
    "${WORKSHOP_URL}/admin/failure-rate") || true
  echo "  Response: HTTP ${HTTP_CODE}"
  echo "${WORKSHOP_URL}"
  # Send Dynatrace deployment event
  echo "  Sending deployment event to Dynatrace..."
  curl -sk -o /dev/null -w "  DT event: HTTP %{http_code}\n" -X POST \
    -H "Authorization: Api-Token ${DT_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${DT_ENV_URL}/api/v2/events/ingest" \
    -d @- <<EOF || true
  {
    "eventType": "CUSTOM_DEPLOYMENT",
    "title": "Payment Service ${ACTION}",
    "description": "Action: ${ACTION}, Failure Rate: ${FAILURE_RATE}",
    "entitySelector": "type(\"SERVICE\"),entityName.startsWith(\"payment-service\"),tag(\"environment:${K8_CLUSTER}\")",
    "properties": {
      "git.repository": "mark-dt/zurich_hot",
      "environment": "${K8_CLUSTER}"
    }
  }
EOF

  echo ""
done

echo "Done. Action '${ACTION}' applied to ${#LINES[@]} VM(s)."
