#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

USERNAME="${username}"
PASSWORD="${password}"

echo "BASE SCRIPT STARTED: USERNAME=$USERNAME" | tee -a /var/log/startup-parts.log

VM_NAME="$(hostname)"
DYNKUBE_NAME="dynakube-$${VM_NAME}"

# -----------------------------
# SSH: enforce password-only
# -----------------------------
apt-get update -y
apt-get install -y --no-install-recommends openssh-server ca-certificates curl wget unzip gnupg lsb-release

# Ensure OpenSSH allows password authentication
sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config || true
sed -i 's/^#\\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/g' /etc/ssh/sshd_config || true
sed -i 's/^#\\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/g' /etc/ssh/sshd_config || true
sed -i 's/^#\\?UsePAM .*/UsePAM yes/g' /etc/ssh/sshd_config || true
sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin no/g' /etc/ssh/sshd_config || true

# Drop-in to force password auth and disable pubkey auth
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-password.conf <<'EOF'
PasswordAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
PubkeyAuthentication no
PermitRootLogin no
EOF

# Create user if not exists
if ! id "$USERNAME" >/dev/null 2>&1; then
useradd -m -s /bin/bash "$USERNAME"
fi

# Set password
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME" || true
passwd -u "$USERNAME" || true

systemctl enable --now ssh || systemctl enable --now sshd || true
systemctl restart ssh || systemctl restart sshd || true

sudo apt-get -y install git-all

# -----------------------------
# K3s: install + kubeconfig
# -----------------------------

# Get external IP for TLS SAN + kubeconfig rewrite
EXT_IP="$(curl -s -H 'Metadata-Flavor: Google' \
http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)"

if [ -n "$EXT_IP" ]; then
INSTALL_ARGS="server --write-kubeconfig-mode=644 --tls-san $EXT_IP"
else
INSTALL_ARGS="server --write-kubeconfig-mode=644"
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$INSTALL_ARGS" sh -

# Wait until API responds
for i in {1..60}; do
if k3s kubectl get nodes >/dev/null 2>&1; then break; fi
sleep 2
done

# Wait for kubeconfig file to exist and be non-empty
K3S_CFG="/etc/rancher/k3s/k3s.yaml"
for i in {1..120}; do
if [ -s "$K3S_CFG" ]; then break; fi
sleep 1
done

if [ ! -s "$K3S_CFG" ]; then
echo "ERROR: kubeconfig not found: $K3S_CFG"
journalctl -u k3s --no-pager -n 200 || true
exit 1
fi

# Copy kubeconfig for workshop user
install -d -m 0700 "/home/$USERNAME/.kube"
cp -f "$K3S_CFG" "/home/$USERNAME/.kube/config"
cp -f "$K3S_CFG" "/home/$USERNAME/kubeconfig"

# Rewrite server address so kubeconfig works from a laptop (external IP)
if [ -n "$EXT_IP" ]; then
sed -i "s/127.0.0.1/$EXT_IP/g" "/home/$USERNAME/.kube/config" || true
sed -i "s/127.0.0.1/$EXT_IP/g" "/home/$USERNAME/kubeconfig" || true
fi

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.kube" "/home/$USERNAME/kubeconfig"
chmod 0600 "/home/$USERNAME/.kube/config" "/home/$USERNAME/kubeconfig"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# -----------------------------
# metrics-server: install + patch
# -----------------------------
k3s kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch metrics-server for common K3s kubelet cert/address behavior
k3s kubectl -n kube-system patch deploy metrics-server --type='json' -p='[
{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"}
]' || true

k3s kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s || true

# -----------------------------
# Helm + Dynatrace Operator
# -----------------------------
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

echo "Startup complete. User=$USERNAME"

#helm install dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator \
#--create-namespace \
#--namespace dynatrace \
#--atomic

helm --kubeconfig /etc/rancher/k3s/k3s.yaml -n dynatrace upgrade --install dynatrace-operator \
  oci://public.ecr.aws/dynatrace/dynatrace-operator \
  --create-namespace \
  --atomic

# Create/Update Dynatrace tokens secret (idempotent)
k3s kubectl -n dynatrace create secret generic "$DYNKUBE_NAME" \
--from-literal="apiToken=${dynatrace_operator_token}" \
--from-literal="dataIngestToken=${dynatrace_data_token}" \
--dry-run=client -o yaml | k3s kubectl apply -f -


echo "Waiting for Dynatrace CRDs..."
for i in {1..60}; do
if k3s kubectl get crd dynakubes.dynatrace.com >/dev/null 2>&1; then
    echo "Dynatrace CRDs are present"
    break
fi
sleep 5
done

echo "Applying DynaKube custom resource..."

k3s kubectl apply -f - <<EOF
apiVersion: dynatrace.com/v1beta5
kind: DynaKube
metadata:
  name: $DYNKUBE_NAME
  namespace: dynatrace
  annotations:
    feature.dynatrace.com/k8s-app-enabled: "true"
    feature.dynatrace.com/injection-readonly-volume: "true"
spec:
  apiUrl: https://ggg43721.sprint.dynatracelabs.com/api

  metadataEnrichment:
    enabled: true

  oneAgent:
    cloudNativeFullStack:
      tolerations:
        - effect: NoSchedule
          key: node-role.kubernetes.io/master
          operator: Exists
        - effect: NoSchedule
          key: node-role.kubernetes.io/control-plane
          operator: Exists

  activeGate:
    capabilities:
      - routing
      - kubernetes-monitoring
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1.5Gi
EOF
