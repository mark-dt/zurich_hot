#!/bin/bash
# Rollback payment-service to healthy state (failure rate = 0).
# Usage: ./scripts/rollback.sh
#
# Resets failure rate instantly via API — no pod restarts.

set -euo pipefail

NAMESPACE="workshop"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "=== Rolling back payment-service ==="

PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=payment-service -o jsonpath='{.items[*].status.podIP}')

for IP in $PODS; do
  echo ">>> Resetting failure rate on pod ${IP}..."
  wget -q -O- --post-data='{"rate":0}' --header='Content-Type: application/json' "http://${IP}:3002/admin/failure-rate"
  echo ""
done

echo ""
echo "=== Rollback complete! ==="
echo "  payment-service is healthy again (failure rate = 0)"
echo "  Check logs:  kubectl logs -n workshop -l app=payment-service --tail=20"
