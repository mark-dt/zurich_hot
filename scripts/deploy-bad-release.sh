#!/bin/bash
# Deploy a "bad release" of payment-service that introduces a 70% failure rate.
# Usage: ./scripts/deploy-bad-release.sh [FAILURE_RATE]
#
# This simulates a faulty deployment that Dynatrace should detect.

set -euo pipefail

FAILURE_RATE="${1:-0.7}"
NAMESPACE="workshop"
DEPLOYMENT="payment-service"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "=== Deploying bad release ==="
echo "  Target:       ${DEPLOYMENT} in namespace ${NAMESPACE}"
echo "  Failure rate:  ${FAILURE_RATE} (${FAILURE_RATE}00% of requests will fail)"
echo ""

# Set the FAILURE_RATE env var on the deployment — triggers a rolling update
kubectl set env "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" "FAILURE_RATE=${FAILURE_RATE}"

# Wait for rollout
echo ">>> Waiting for rollout..."
kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== Bad release deployed! ==="
echo "  payment-service is now failing ~${FAILURE_RATE}00% of requests"
echo "  Errors will cascade to order-service and frontend"
echo ""
echo "  To rollback: ./scripts/rollback.sh"
echo "  Check logs:  kubectl logs -n workshop -l app=payment-service --tail=20"
