#!/bin/bash
# Deploy a "bad release" of payment-service that introduces a 70% failure rate.
# Usage: ./scripts/deploy-bad-release.sh [FAILURE_RATE]
#
# This simulates a faulty deployment that Dynatrace should detect.
# Changes the failure rate instantly via API — no pod restarts.

set -euo pipefail

FAILURE_RATE="${1:-0.7}"
NAMESPACE="workshop"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "=== Deploying bad release ==="
echo "  Failure rate:  ${FAILURE_RATE} (${FAILURE_RATE}00% of requests will fail)"
echo ""

PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=payment-service -o jsonpath='{.items[*].status.podIP}')

for IP in $PODS; do
  echo ">>> Setting failure rate on pod ${IP}..."
  wget -q -O- --post-data="{\"rate\":${FAILURE_RATE}}" --header='Content-Type: application/json' "http://${IP}:3002/admin/failure-rate"
  echo ""
done

echo ""
echo "=== Bad release deployed! ==="
echo "  payment-service is now failing ~${FAILURE_RATE}00% of requests"
echo "  Errors will cascade to order-service and frontend"
echo ""
echo "  To rollback: ./scripts/rollback.sh"
echo "  Check logs:  kubectl logs -n workshop -l app=payment-service --tail=20"
