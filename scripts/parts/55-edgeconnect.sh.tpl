#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/startup-parts.log) 2>&1

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
NS="dynatrace"
EC_NAME="edgeconnect"
SECRET_NAME="edgeconnect-oauth"

OAUTH_CLIENT_ID="${edgeconnect_oauth_client_id}"
OAUTH_CLIENT_SECRET="${edgeconnect_oauth_client_secret}"
OAUTH_ENDPOINT="${edgeconnect_oauth_endpoint}"
OAUTH_RESOURCE="${edgeconnect_oauth_resource}"

log() { echo "[edgeconnect] $*"; }

log "Starting EdgeConnect setup in namespace: $${NS}"

# Wait for k3s API
for i in {1..60}; do
  if k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Wait for EdgeConnect CRD (installed by Dynatrace Operator)
log "Waiting for EdgeConnect CRD..."
for i in {1..60}; do
  if k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" get crd edgeconnects.dynatrace.com >/dev/null 2>&1; then
    log "EdgeConnect CRD is present"
    break
  fi
  sleep 5
done

# Create OAuth client secret (idempotent)
log "Creating OAuth secret: $${SECRET_NAME}"
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${NS}" create secret generic "$${SECRET_NAME}" \
  --from-literal="oauth-client-id=$${OAUTH_CLIENT_ID}" \
  --from-literal="oauth-client-secret=$${OAUTH_CLIENT_SECRET}" \
  --dry-run=client -o yaml | k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" apply -f -

# Create EdgeConnect CR
log "Creating EdgeConnect CR: $${EC_NAME}"
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" apply -f - <<EC_EOF
apiVersion: dynatrace.com/v1alpha2
kind: EdgeConnect
metadata:
  name: $${EC_NAME}
  namespace: $${NS}
spec:
  apiServer: ggg43721.sprint.dynatracelabs.com
  oauth:
    clientSecret: $${SECRET_NAME}
    endpoint: $${OAUTH_ENDPOINT}
    resource: $${OAUTH_RESOURCE}
EC_EOF

# Wait for EdgeConnect pod to appear
log "Waiting for EdgeConnect pod..."
for i in {1..60}; do
  if k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${NS}" get pods -l app.kubernetes.io/name=edgeconnect 2>/dev/null | grep -q Running; then
    log "EdgeConnect pod is running"
    break
  fi
  sleep 5
done

log "EdgeConnect setup complete."
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${NS}" get edgeconnect || true
