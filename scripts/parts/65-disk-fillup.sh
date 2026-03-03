#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/startup-parts.log) 2>&1

NAMESPACE="workshop"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

log() { echo "[disk-fillup] $*" | tee -a /var/log/startup-parts.log; }

log "Creating disk-fillup PVC and Deployment in namespace ${NAMESPACE}..."

# PVC: 1Gi volume that will be slowly filled
sudo k3s kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${NAMESPACE}" apply -f - <<'__DISK_FILLUP_PVC__'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: disk-fillup
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
__DISK_FILLUP_PVC__

# Deployment: busybox writing ~17KB/s to the PVC (fills 1Gi in ~1 hour)
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
                dd if=/dev/urandom bs=17000 count=1 >> /data/fill.bin 2>/dev/null
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

log "disk-fillup PVC and Deployment applied."
