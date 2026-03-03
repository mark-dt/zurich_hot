#!/usr/bin/env bash
set -euo pipefail

# Log everything from this part
exec > >(tee -a /var/log/startup-parts.log) 2>&1

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
NS="${ARGOCD_NAMESPACE:-argocd}"

# Install manifest (recommended: stable; pin to a version for production)
ARGOCD_MANIFEST_URL="${ARGOCD_MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

# Ingress/TLS options
ENABLE_INGRESS="${ARGOCD_ENABLE_INGRESS:-true}"                 # true|false
INGRESS_CLASS="${ARGOCD_INGRESS_CLASS:-traefik}"                # k3s default ingress controller is Traefik [4](https://github.com/cert-manager/cert-manager/releases)
CLUSTER_ISSUER="${ARGOCD_CLUSTER_ISSUER:-letsencrypt-nipio}"     # re-use your existing ClusterIssuer
TLS_SECRET="${ARGOCD_TLS_SECRET:-argocd-tls}"
INGRESS_NAME="${ARGOCD_INGRESS_NAME:-argocd}"

log() { echo "[argocd] $*"; }

log "Starting Argo CD install into namespace: ${NS}"

# Wait for k3s API
for i in {1..60}; do
  if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Ensure namespace exists (idempotent)
k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get ns "${NS}" >/dev/null 2>&1 \
  || k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" create ns "${NS}"

# Install Argo CD using server-side apply (recommended by official docs)
# This avoids kubectl client-side annotation size issues and handles upgrades better. [1](https://argo-cd.readthedocs.io/en/stable/getting_started/)
log "Applying Argo CD install manifest (server-side apply): ${ARGOCD_MANIFEST_URL}"
k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -n "${NS}" \
  --server-side --force-conflicts \
  -f "${ARGOCD_MANIFEST_URL}"

# Wait for core components (best-effort; some are Deployments, one is a StatefulSet)
log "Waiting for Argo CD deployments to become ready..."
for dep in argocd-server argocd-repo-server argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis; do
  # Not all installs have all components in every version/config, so ignore missing
  if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" get deploy "${dep}" >/dev/null 2>&1; then
    k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" rollout status "deploy/${dep}" --timeout=300s || \
      log "WARNING: deploy/${dep} did not become ready in time, continuing..."
  fi
done

if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" get statefulset argocd-application-controller >/dev/null 2>&1; then
  log "Waiting for Argo CD application controller StatefulSet to become ready..."
  k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" rollout status "statefulset/argocd-application-controller" --timeout=300s || \
    log "WARNING: argocd-application-controller did not become ready in time, continuing..."
fi

log "Argo CD installed. Pods summary:"
k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" get pods -o wide || true

# -------------------------
# Optional: expose UI via Ingress on nip.io with TLS from cert-manager
# -------------------------
if [[ "${ENABLE_INGRESS}" == "true" ]]; then
  EXT_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' || true)"

  if [[ -z "${EXT_IP}" ]]; then
    log "WARN: Could not determine external IP; skipping Ingress creation."
  else
    HOST="argocd.${EXT_IP}.nip.io"
    log "Configuring Ingress for Argo CD UI: https://${HOST}"

    # Argo CD API server serves HTTPS by default and uses a self-signed cert.
    # When using Ingress TLS termination, recommended approach is to run Argo CD server in insecure mode (HTTP behind ingress). [2](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
    # Set server.insecure=true via argocd-cmd-params-cm (idempotent).
    log "Setting Argo CD server to insecure mode behind Ingress (server.insecure=true)"
    k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" patch configmap argocd-cmd-params-cm \
      --type merge -p '{"data":{"server.insecure":"true"}}' >/dev/null 2>&1 || true

    # Restart argocd-server to pick up cmd params if needed
    if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" get deploy argocd-server >/dev/null 2>&1; then
      k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" rollout restart deploy/argocd-server || true
      k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" rollout status deploy/argocd-server --timeout=300s || true
    fi

    # Create a redirect middleware (http -> https) for Traefik
    k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" apply -f - <<__ARGO_REDIRECT__
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
__ARGO_REDIRECT__

    # Argo CD argocd-server service exposes 80 (HTTP redirect) and 443 (gRPC/HTTPS). [2](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
    # Since we terminate TLS at ingress and run server insecure, route to service port 80.
    k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" apply -f - <<__ARGO_INGRESS__
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    traefik.ingress.kubernetes.io/router.middlewares: ${NS}-redirect-https@kubernetescrd
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
  tls:
  - hosts:
    - ${HOST}
    secretName: ${TLS_SECRET}
__ARGO_INGRESS__

    log "Waiting for TLS secret ${NS}/${TLS_SECRET} (up to ~5 minutes)..."
    for i in {1..60}; do
      if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NS}" get secret "${TLS_SECRET}" >/dev/null 2>&1; then
        break
      fi
      sleep 5
    done

    log "Argo CD UI should be available at: https://${HOST}"
  fi
else
  log "Ingress disabled (ARGOCD_ENABLE_INGRESS=false). Use port-forward instead."
fi

# Admin password retrieval guidance (do not print password into logs)
# Officially, initial password lives in a Kubernetes Secret (argocd-initial-admin-secret). [2](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)[3](https://stackoverflow.com/questions/68297354/what-is-the-default-password-of-argocd)
log "To access Argo CD:"
log "  - Port-forward (local): kubectl -n ${NS} port-forward svc/argocd-server 8080:443"
log "  - Initial admin password:"
log "      kubectl -n ${NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
log "  - Username: admin"