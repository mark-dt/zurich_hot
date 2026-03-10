#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/startup-parts.log) 2>&1

NAMESPACE="workshop"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
IMG_PATH="/opt/disk-fillup.img"
MNT_PATH="/mnt/disk-fillup"
IMG_SIZE_MB=4096  # 4Gi

log() { echo "[disk-fillup] $*" | tee -a /var/log/startup-parts.log; }

log "Setting up 1Gi loop-mounted volume for disk-fillup demo..."

# --- Create a 1Gi disk image, format it, and mount it ---
if [[ ! -f "${IMG_PATH}" ]]; then
  log "Creating ${IMG_SIZE_MB}MB disk image at ${IMG_PATH}..."
  dd if=/dev/zero of="${IMG_PATH}" bs=1M count="${IMG_SIZE_MB}" status=progress
  mkfs.ext4 -F "${IMG_PATH}"
fi

mkdir -p "${MNT_PATH}"
if ! mountpoint -q "${MNT_PATH}"; then
  log "Mounting loop device at ${MNT_PATH}..."
  mount -o loop "${IMG_PATH}" "${MNT_PATH}"
fi

# Ensure it stays mounted across reboots (idempotent)
if ! grep -q "${IMG_PATH}" /etc/fstab; then
  echo "${IMG_PATH} ${MNT_PATH} ext4 loop 0 0" >> /etc/fstab
fi

chmod 777 "${MNT_PATH}"

log "Loop volume mounted: $(df -h "${MNT_PATH}" | tail -1)"

# --- Clean up any stale PVC bound to the wrong volume (e.g. local-path from a previous run) ---
CURRENT_SC="$(sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" \
  get pvc disk-fillup -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
if [[ -n "${CURRENT_SC}" && "${CURRENT_SC}" != "disk-fillup" ]]; then
  log "Removing stale PVC (storageClass=${CURRENT_SC}), will recreate with disk-fillup class..."
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" delete deploy disk-fillup --ignore-not-found 2>/dev/null || true
  sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" delete pvc disk-fillup 2>/dev/null || true
  # Wait for PVC to be fully removed
  for i in {1..30}; do
    if ! sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" get pvc disk-fillup >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
fi

# --- Create a PV backed by the loop mount, PVC, and Deployment ---
sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f - <<__DISK_FILLUP_PV__
apiVersion: v1
kind: PersistentVolume
metadata:
  name: disk-fillup-pv
spec:
  capacity:
    storage: 4Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: disk-fillup
  local:
    path: ${MNT_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: Exists
__DISK_FILLUP_PV__

sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<'__DISK_FILLUP_PVC__'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: disk-fillup
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: disk-fillup
  resources:
    requests:
      storage: 4Gi
__DISK_FILLUP_PVC__

# Deployment: busybox writing ~119KB/s to the PVC (fills 4Gi in ~10 hours)
sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<'__DISK_FILLUP_DEPLOY__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: disk-fillup
  labels:
    app: disk-fillup
spec:
  replicas: 1
  selector:
    matchLabels:
      app: disk-fillup
  template:
    metadata:
      labels:
        app: disk-fillup
    spec:
      containers:
        - name: filler
          image: busybox:latest
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                dd if=/dev/urandom bs=119000 count=1 >> /data/fill.bin 2>/dev/null
                sleep 1
              done
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: disk-fillup
__DISK_FILLUP_DEPLOY__

log "disk-fillup PV, PVC, and Deployment applied."
