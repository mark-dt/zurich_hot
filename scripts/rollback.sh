#!/bin/bash
# Rollback payment-service to healthy state (FAILURE_RATE=0).
# Usage: ./scripts/rollback.sh

set -euo pipefail

NAMESPACE="workshop"
DEPLOYMENT="payment-service"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "=== Rolling back payment-service ==="

kubectl set env "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" "FAILURE_RATE=0"

echo ">>> Waiting for rollout..."
kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== Rollback complete! ==="
echo "  payment-service is healthy again (FAILURE_RATE=0)"
echo "  Check logs:  kubectl logs -n workshop -l app=payment-service --tail=20"
