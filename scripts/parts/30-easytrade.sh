#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/startup-parts.log) 2>&1

# --- Config ---
NAMESPACE="${EASYTRADE_NAMESPACE:-easytrade}"
INSTALL_PROBLEM_PATTERNS="${EASYTRADE_PROBLEM_PATTERNS:-false}"   # true|false
EASYTRADE_REF="${EASYTRADE_REF:-main}"                            # branch/tag
WORKDIR="/opt/easytrade-src"
TARBALL="/tmp/easytrade-${EASYTRADE_REF}.tar.gz"

# K3s kubeconfig (explicit, so it works under sudo and in boot context)
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

log() { echo "[easytrade] $*" | tee -a /var/log/startup-parts.log; }

log "Starting EasyTrade deployment (namespace=${NAMESPACE}, ref=${EASYTRADE_REF})"

# Ensure k3s API is reachable
for i in {1..60}; do
  if sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Namespace (idempotent)
sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" get ns "${NAMESPACE}" >/dev/null 2>&1 \
  || sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" create ns "${NAMESPACE}"

# Fetch sources (no git required)
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

log "Downloading EasyTrade sources from GitHub tarball..."
curl -fsSL -o "${TARBALL}" "https://github.com/Dynatrace/easytrade/archive/refs/heads/${EASYTRADE_REF}.tar.gz"
tar -xzf "${TARBALL}" -C "${WORKDIR}" --strip-components=1

# Apply manifests per EasyTrade README:
# kubectl -n easytrade apply -f ./kubernetes-manifests/release
# and optionally ./kubernetes-manifests/problem-patterns [1](https://github.com/Dynatrace/easytrade/blob/main/README.md)
log "Applying EasyTrade Kubernetes manifests..."
sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f "${WORKDIR}/kubernetes-manifests/release"

if [[ "${INSTALL_PROBLEM_PATTERNS}" == "true" ]]; then
  log "Applying EasyTrade problem-patterns manifests (optional)..."
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f "${WORKDIR}/kubernetes-manifests/problem-patterns"
fi

# Make UI reachable in a single-node k3s-on-VM scenario:
# Patch frontendreverseproxy Service to NodePort if it's LoadBalancer with no external integration.
# Many demos expect an EXTERNAL-IP; on k3s this may not behave as on managed clouds. [1](https://github.com/Dynatrace/easytrade/blob/main/README.md)
#
# We attempt to find the service and patch it. If it doesn't exist or already is NodePort, that's fine.
FRONTEND_SVC="frontendreverseproxy"
NODEPORT="${EASYTRADE_NODEPORT:-30080}"

if sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get svc "${FRONTEND_SVC}" >/dev/null 2>&1; then
  log "Patching ${FRONTEND_SVC} Service to NodePort=${NODEPORT} (best-effort)..."
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" patch svc "${FRONTEND_SVC}" --type='merge' -p "{
    \"spec\": {
      \"type\": \"NodePort\",
      \"ports\": [
        {\"name\":\"http\",\"port\":80,\"targetPort\":80,\"nodePort\": ${NODEPORT}}
      ]
    }
  }" || true
else
  log "Service ${FRONTEND_SVC} not found (yet). Skipping Service patch."
fi


# Wait for pods to exist, then become Ready (robust + no parsing)
log "Waiting for EasyTrade pods to appear..."
for i in {1..60}; do
  POD_COUNT="$(sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
  if [[ "${POD_COUNT}" != "" && "${POD_COUNT}" != "0" ]]; then
    break
  fi
  sleep 2
done

log "Waiting for EasyTrade pods to become Ready (timeout: 10 minutes)..."
if ! sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" \
  wait --for=condition=Ready pod --all --timeout=10m; then

  log "WARNING: Timed out waiting for all pods to be Ready. Current status:"
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pods -o wide || true

  log "Describing non-ready pods (best-effort):"
  # List pods that are not Ready (READY column not equal like 1/1, 2/2, etc.)
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pods --no-headers 2>/dev/null \
    | awk '$2 !~ /^([0-9]+)\/\1$/ {print $1}' \
    | while read -r p; do
        log "---- describe pod/${p} ----"
        sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" describe pod "${p}" || true
      done

  # Don't hard-fail the whole startup; continue
  log "Continuing startup despite non-ready pods."
else
  log "All EasyTrade pods are Ready."
fi

# Print access hint
NODE_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)"

if [[ -n "${NODE_IP}" ]]; then
  log "EasyTrade UI (NodePort): http://${NODE_IP}:${NODEPORT}"
else
  log "EasyTrade deployed. Determine node IP and access via NodePort ${NODEPORT}."
fi

log "EasyTrade deployment script finished."