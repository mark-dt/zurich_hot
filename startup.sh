#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/workshop-startup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Workshop startup script began at $(date) ==="

REPO_URL="${REPO_URL:-https://github.com/OWNER/REPO.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WORKSHOP_DIR="/opt/workshop"

# ─── 1. Install dependencies ────────────────────────────────────────────────
echo ">>> Installing system packages..."
apt-get update -qq
apt-get install -y -qq curl git docker.io

systemctl enable docker
systemctl start docker


# ─── 3. Clone repository ────────────────────────────────────────────────────
echo ">>> Cloning repository..."
rm -rf "$WORKSHOP_DIR"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$WORKSHOP_DIR"

# ─── 4. Build Docker images ─────────────────────────────────────────────────
echo ">>> Building Docker images..."
SERVICES="frontend order-service payment-service inventory-service notification-service"

for svc in $SERVICES; do
  echo "  Building workshop/${svc}:latest ..."
  docker build -t "workshop/${svc}:latest" "${WORKSHOP_DIR}/services/${svc}/"
done

# Import images into k3s's containerd so pods can use them
echo ">>> Importing images into k3s containerd..."
for svc in $SERVICES; do
  docker save "workshop/${svc}:latest" | k3s ctr images import -
done

# ─── 5. Deploy to Kubernetes ────────────────────────────────────────────────
echo ">>> Applying Kubernetes manifests..."

# Resolve VM external IP and patch the ingress manifest
EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
echo ">>> VM external IP: ${EXTERNAL_IP}"
sed -i "s/PLACEHOLDER_IP/${EXTERNAL_IP}/g" "${WORKSHOP_DIR}/k8s/ingress.yaml"

kubectl apply -f "${WORKSHOP_DIR}/k8s/namespace.yaml"

for manifest in frontend order-service payment-service inventory-service notification-service load-generator ingress; do
  kubectl apply -f "${WORKSHOP_DIR}/k8s/${manifest}.yaml"
done

# ─── 6. Wait for pods ───────────────────────────────────────────────────────
echo ">>> Waiting for all pods to be ready (timeout 5m)..."
kubectl wait --for=condition=ready pod --all -n workshop --timeout=300s || true

echo ">>> Pod status:"
kubectl get pods -n workshop

echo "=== Workshop startup script completed at $(date) ==="
