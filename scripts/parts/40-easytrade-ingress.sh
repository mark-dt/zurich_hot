#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

# --- EasyTrade / Ingress settings ---
NAMESPACE="${EASYTRADE_NAMESPACE:-easytrade}"
# If not set, we will auto-detect a service named frontendreverseproxy*
SVC_NAME="${EASYTRADE_FRONTEND_SVC:-}"
SVC_PORT="${EASYTRADE_FRONTEND_PORT:-80}"
INGRESS_NAME="${EASYTRADE_INGRESS_NAME:-easytrade}"
INGRESS_CLASS="${EASYTRADE_INGRESS_CLASS:-traefik}"

# --- HTTPS settings ---
ENABLE_HTTPS="${EASYTRADE_ENABLE_HTTPS:-true}"                # true|false
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.4}"      # pin a known good version
CLUSTER_ISSUER="${EASYTRADE_CLUSTER_ISSUER:-letsencrypt-nipio}"
TLS_SECRET="${EASYTRADE_TLS_SECRET:-easytrade-tls}"

log() { echo "[easytrade-ingress] $*" | tee -a /var/log/startup-parts.log; }

# Determine external/public IP (GCP)
EXT_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' || true)"

if [[ -z "${EXT_IP}" ]]; then
  log "ERROR: Could not determine external IP from GCP metadata."
  exit 1
fi

# nip.io hostname: maps embedded IP to A record [5](https://dev.to/colom/easy-steps-to-install-k3s-with-ssl-certificate-by-traefik-cert-manager-and-lets-encrypt-20n0)
HOST="easytrade.${EXT_IP}.nip.io"
log "Using host: ${HOST}"

# Wait for k3s API
for i in {1..60}; do
  if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Ensure namespace exists
k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get ns "${NAMESPACE}" >/dev/null 2>&1 \
  || k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" create ns "${NAMESPACE}"

# --- Wait for services to appear and auto-detect reverse proxy service ---
log "Waiting for EasyTrade services to be present..."
for i in {1..60}; do
  if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get svc >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ -z "${SVC_NAME}" ]]; then
  # Find a service that starts with "frontendreverseproxy"
  SVC_NAME="$(k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get svc -o name \
    | sed 's#service/##' \
    | grep -E '^frontendreverseproxy' \
    | head -n 1 || true)"
fi

if [[ -z "${SVC_NAME}" ]]; then
  log "ERROR: Could not find a Service matching 'frontendreverseproxy*' in namespace ${NAMESPACE}."
  k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get svc || true
  exit 1
fi

log "Using service: ${NAMESPACE}/${SVC_NAME}:${SVC_PORT}"

# -------------------------
# Install cert-manager (for HTTPS)
# -------------------------
if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  log "HTTPS enabled: ensuring cert-manager is installed (version=${CERT_MANAGER_VERSION})"

  if ! k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get crd certificates.cert-manager.io >/dev/null 2>&1; then
    log "cert-manager CRDs not found, installing cert-manager..."
    k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f \
      "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    # Official installation manifest approach [2](https://github.com/Dynatrace/easytrade/blob/main/README.md)
  else
    log "cert-manager CRDs already present, skipping installation."
  fi

  for dep in cert-manager cert-manager-webhook cert-manager-cainjector; do
    log "Waiting for cert-manager deployment/${dep} to be ready..."
    k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n cert-manager rollout status "deploy/${dep}" --timeout=180s
  done

  # ClusterIssuer: Let’s Encrypt production + HTTP01 via Traefik
  # email intentionally omitted (empty string). Not recommended but possible. [3](https://deepwiki.com/exentriquesolutions/nip.io/3-configuration)[4](https://docs.cloud.google.com/kubernetes-engine/enterprise/knative-serving/docs/default-domain)
  log "Applying ClusterIssuer ${CLUSTER_ISSUER} (no email)"
  k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f - <<__CLUSTER_ISSUER__
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CLUSTER_ISSUER}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ""
    privateKeySecretRef:
      name: ${CLUSTER_ISSUER}-account-key
    solvers:
    - http01:
        ingress:
          ingressClassName: ${INGRESS_CLASS}
__CLUSTER_ISSUER__

  # HTTP->HTTPS redirect middleware
  k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<__REDIRECT_MW__
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
__REDIRECT_MW__
fi

# -------------------------
# Ingress (HTTP + HTTPS)
# -------------------------
if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  log "Applying Ingress with TLS + cert-manager (secret=${TLS_SECRET})"
  k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<__EASYTRADE_INGRESS_TLS__
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    traefik.ingress.kubernetes.io/router.middlewares: ${NAMESPACE}-redirect-https@kubernetescrd
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
            name: ${SVC_NAME}
            port:
              number: ${SVC_PORT}
  tls:
  - hosts:
    - ${HOST}
    secretName: ${TLS_SECRET}
__EASYTRADE_INGRESS_TLS__

  log "Waiting for TLS secret ${NAMESPACE}/${TLS_SECRET} (up to ~5 minutes)..."
  for i in {1..60}; do
    if k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get secret "${TLS_SECRET}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  log "✅ EasyTrade URLs:"
  log "   HTTP : http://${HOST}/"
  log "   HTTPS: https://${HOST}/"
else
  log "Applying Ingress (HTTP only)"
  k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<__EASYTRADE_INGRESS__
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
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
            name: ${SVC_NAME}
            port:
              number: ${SVC_PORT}
__EASYTRADE_INGRESS__
  log "✅ EasyTrade URL: http://${HOST}/"
fi

log "NOTE: HTTP-01 requires inbound port 80 reachable publicly. Traefik is bundled in k3s and uses 80/443 by default. [1](https://github.com/cert-manager/cert-manager/releases)"
