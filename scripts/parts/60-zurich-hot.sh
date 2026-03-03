#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/startup-parts.log) 2>&1

# --- Config ---
NAMESPACE="workshop"
REPO_URL="${ZURICH_HOT_REPO:-https://github.com/mark-dt/zurich_hot.git}"
REPO_BRANCH="${ZURICH_HOT_BRANCH:-main}"
WORKDIR="/opt/zurich-hot"
SERVICES="frontend order-service payment-service inventory-service notification-service"

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

log() { echo "[zurich-hot] $*" | tee -a /var/log/startup-parts.log; }

log "Starting zurich-hot deployment (namespace=${NAMESPACE}, branch=${REPO_BRANCH})"

# Ensure k3s API is reachable
for i in {1..60}; do
  if sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# --- Install docker (needed to build images) ---
log "Installing docker..."
apt-get update -qq
apt-get install -y -qq docker.io
systemctl enable docker
systemctl start docker

# --- Clone repository ---
log "Cloning zurich-hot repository..."
rm -rf "${WORKDIR}"
git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${WORKDIR}"

# --- Build Docker images ---
log "Building Docker images..."
for svc in ${SERVICES}; do
  log "  Building workshop/${svc}:latest ..."
  docker build -t "workshop/${svc}:latest" "${WORKDIR}/services/${svc}/"
done

# --- Import images into k3s containerd ---
log "Importing images into k3s containerd..."
for svc in ${SERVICES}; do
  docker save "workshop/${svc}:latest" | sudo k3s ctr images import -
done

# --- Deploy to Kubernetes ---
log "Creating namespace ${NAMESPACE}..."
sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get ns "${NAMESPACE}" >/dev/null 2>&1 \
  || sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${WORKDIR}/k8s/namespace.yaml"

log "Applying Kubernetes manifests..."
for manifest in "${WORKDIR}"/k8s/*.yaml; do
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${manifest}"
done

# Images are built locally and imported into k3s containerd, not in a registry.
# Patch deployments to use imagePullPolicy: Never, which triggers a new rollout.
log "Patching deployments to use imagePullPolicy: Never..."
for svc in ${SERVICES}; do
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" patch deploy "${svc}" \
    --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' || true
done

# --- Wait for pods ---
log "Waiting for workshop pods to appear..."
for i in {1..60}; do
  POD_COUNT="$(sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  if [[ "${POD_COUNT}" != "" && "${POD_COUNT}" != "0" ]]; then
    break
  fi
  sleep 2
done

log "Waiting for workshop pods to become Ready (timeout: 5 minutes)..."
if ! sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" \
  wait --for=condition=Ready pod --all --timeout=300s; then

  log "WARNING: Timed out waiting for all pods to be Ready. Current status:"
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pods -o wide || true
  log "Continuing startup despite non-ready pods."
else
  log "All workshop pods are Ready."
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pods || true
fi

# --- Ingress with TLS via cert-manager ---
INGRESS_NAME="workshop"
INGRESS_CLASS="traefik"
CLUSTER_ISSUER="letsencrypt-nipio"
TLS_SECRET="workshop-tls"
SVC_NAME="frontend"
SVC_PORT="3000"

EXT_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' || true)"

if [[ -z "${EXT_IP}" ]]; then
  log "WARNING: Could not determine external IP. Skipping ingress setup."
else
  HOST="workshop.${EXT_IP}.nip.io"
  log "Setting up ingress at ${HOST}"

  # HTTP->HTTPS redirect middleware
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<__REDIRECT_MW__
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
__REDIRECT_MW__

  # Ingress with TLS
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<__WORKSHOP_INGRESS__
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
__WORKSHOP_INGRESS__

  log "Waiting for TLS secret ${NAMESPACE}/${TLS_SECRET} (up to ~5 minutes)..."
  for i in {1..60}; do
    if sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get secret "${TLS_SECRET}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  log "Workshop URLs:"
  log "  HTTP : http://${HOST}/"
  log "  HTTPS: https://${HOST}/"
fi

log "zurich-hot deployment script finished."
