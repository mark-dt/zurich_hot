Fix CSI crashloop


mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown mark.bley:mark.bley ~/.kube/config


# Install latest metrics-server manifests
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# (Often needed on k3s) Add --kubelet-insecure-tls to cope with kubelet certs/addresses
kubectl -n kube-system patch deploy metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Wait and check APIService becomes Available=True
kubectl -n kube-system rollout status deploy/metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'; echo

kubectl -n kube-system patch deployment metrics-server \
  --type='json' \
  -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"}
  ]'

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

https://docs.dynatrace.com/docs/ingest-from/opentelemetry/collector/deployment#kubernetes--helm


kubectl create secret generic dynatrace-otelcol-dt-api-credentials --from-literal=DT_ENDPOINT=https://ggg43721.sprint.dynatracelabs.com/ --from-literal=DT_API_TOKEN=REDACTED_DT_OTEL_TOKEN


kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=REDACTED_DT_API_TOKEN" --from-literal="dataIngestToken=REDACTED_DT_INGEST_TOKEN"

# gcp ssh login
gcloud compute ssh simple-vm-1 --zone europe-west1-b

# get gcp metadata
sudo curl -fsS -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/startup-script" \
  | nl -ba | sed -n '40,60p'


# AG pvc not starting
kubectl describe pod gcp-k3-activegate-0 -n dynatrace 

kubectl delete pod -n kube-system -l app=local-path-provisioner

# gcp tf startup script
sudo systemctl status google-startup-scripts.service


gcloud compute instances describe simple-vm-1 \
  --zone europe-west1-b \
  --format="get(metadata.items)"


sudo journalctl -u google-startup-scripts.service -b --no-pager -n 300


# restart all of namespace
kubectl -n easytrade rollout restart deploy,sts,ds