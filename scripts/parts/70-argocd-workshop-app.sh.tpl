#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/startup-parts.log) 2>&1

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
ARGOCD_NS="argocd"
WORKSHOP_NS="workshop"
APP_NAME="workshop-app"
REPO_URL="https://github.com/mark-dt/zurich_hot.git"
REPO_PATH="k8s"
REPO_BRANCH="main"

DT_API_TOKEN="${dynatrace_api_token}"
DT_BASE_URL="https://ggg43721.sprint.dynatracelabs.com"

log() { echo "[argocd-workshop-app] $*"; }

log "Setting up ArgoCD Application for zurich-hot workshop"

# Wait for ArgoCD to be ready
for i in {1..60}; do
  if k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" get deploy argocd-server >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# Wait for workshop namespace (created by 60-zurich-hot.sh)
for i in {1..60}; do
  if k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" get ns "$${WORKSHOP_NS}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# Get external IP for ArgoCD URL
EXT_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' || true)"

ARGOCD_URL="https://argocd.$${EXT_IP}.nip.io"

# --- Patch argocd-notifications-secret with Dynatrace API token ---
log "Patching argocd-notifications-secret with Dynatrace API token..."

# Base64 encode the token and URL
DT_TOKEN_B64="$(echo -n "$${DT_API_TOKEN}" | base64 -w0)"
DT_URL_B64="$(echo -n "$${DT_BASE_URL}" | base64 -w0)"

k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" patch secret argocd-notifications-secret \
  --type merge -p "{\"data\":{\"dynatrace-api-token\":\"$${DT_TOKEN_B64}\",\"dynatrace-base-url\":\"$${DT_URL_B64}\"}}" \
  2>/dev/null || \
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" create secret generic argocd-notifications-secret \
  --from-literal="dynatrace-api-token=$${DT_API_TOKEN}" \
  --from-literal="dynatrace-base-url=$${DT_BASE_URL}"

# --- Patch argocd-notifications-cm with Dynatrace webhook service, template, and trigger ---
log "Patching argocd-notifications-cm with Dynatrace webhook configuration..."

k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" patch configmap argocd-notifications-cm \
  --type merge -p "$(cat <<'PATCH_EOF'
{
  "data": {
    "service.webhook.dynatrace-webhook": "url: $dynatrace-base-url/api/v2/events/ingest\nheaders:\n- name: Authorization\n  value: Api-Token $dynatrace-api-token\n- name: Content-Type\n  value: application/json\n",
    "template.dynatrace-deployment-event": "webhook:\n  dynatrace-webhook:\n    method: POST\n    body: |\n      {\n        \"eventType\": \"CUSTOM_DEPLOYMENT\",\n        \"title\": \"ArgoCD Deployment: {{.app.metadata.name}}\",\n        \"entitySelector\": \"type(CLOUD_APPLICATION_NAMESPACE),entityName.equals(workshop)\",\n        \"properties\": {\n          \"dt.event.deployment.name\": \"{{.app.metadata.name}}\",\n          \"dt.event.deployment.version\": \"{{.app.status.sync.revision}}\",\n          \"dt.event.deployment.ci_back_link\": \"ARGOCD_URL_PLACEHOLDER/applications/argocd/workshop-app\",\n          \"dt.event.deployment.remediation_action_link\": \"https://github.com/mark-dt/zurich_hot/blob/main/scripts/rollback.sh\",\n          \"source\": \"ArgoCD\",\n          \"syncStatus\": \"{{.app.status.sync.status}}\",\n          \"healthStatus\": \"{{.app.status.health.status}}\"\n        }\n      }\n",
    "trigger.on-deployed": "- when: app.status.operationState.phase in ['Succeeded', 'Failed']\n  send: [dynatrace-deployment-event]\n"
  }
}
PATCH_EOF
)"

# Now fix the ArgoCD URL placeholder (can't use shell vars inside single-quoted heredoc)
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" get configmap argocd-notifications-cm -o json \
  | sed "s|ARGOCD_URL_PLACEHOLDER|$${ARGOCD_URL}|g" \
  | k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" apply -f -

# Restart notifications controller to pick up changes
log "Restarting argocd-notifications-controller..."
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" rollout restart deploy/argocd-notifications-controller || true
k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" rollout status deploy/argocd-notifications-controller --timeout=120s || true

# --- Create ArgoCD Application CR ---
log "Creating ArgoCD Application: $${APP_NAME}"

k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" apply -f - <<ARGO_APP_EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $${APP_NAME}
  namespace: $${ARGOCD_NS}
  annotations:
    notifications.argoproj.io/subscribe.on-deployed.dynatrace-webhook: ""
spec:
  project: default
  source:
    repoURL: $${REPO_URL}
    targetRevision: $${REPO_BRANCH}
    path: $${REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: $${WORKSHOP_NS}
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
      - CreateNamespace=false
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/spec/containers/0/image
        - /spec/template/spec/containers/0/imagePullPolicy
ARGO_APP_EOF

# Wait for the app to appear and sync
log "Waiting for ArgoCD application to sync..."
for i in {1..60}; do
  SYNC_STATUS="$(k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${ARGOCD_NS}" \
    get app "$${APP_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  if [[ "$${SYNC_STATUS}" == "Synced" ]]; then
    log "Application $${APP_NAME} is Synced."
    break
  fi
  sleep 5
done

# Re-patch image tag and imagePullPolicy after ArgoCD sync (ArgoCD ignores the diff but the initial sync may reset it)
log "Re-patching workshop deployments to use local images with imagePullPolicy: Never..."
SERVICES="frontend order-service payment-service inventory-service notification-service"
for svc in $${SERVICES}; do
  k3s kubectl --kubeconfig "$${KUBECONFIG_PATH}" -n "$${WORKSHOP_NS}" patch deploy "$${svc}" \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"workshop/$${svc}:local\"},{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Never\"}]" 2>/dev/null || true
done

log "ArgoCD workshop app setup complete."
log "  App URL: $${ARGOCD_URL}/applications/argocd/$${APP_NAME}"
