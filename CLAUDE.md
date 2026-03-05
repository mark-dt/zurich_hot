# GCP K3s Workshop Environment

Terraform project that provisions GCP VMs with single-node k3s clusters for Dynatrace workshops. Each participant gets an isolated VM with pre-deployed demo apps and monitoring.

## Project Structure

```
main.tf / variables.tf / outputs.tf   # Terraform: GCP VMs, firewalls, credentials
scripts/
  bootstrap.sh.tpl                     # Orchestrator: assembles parts, runs them in order
  parts/                               # Modular startup scripts (numbered for execution order)
    10-base.sh.tpl                     # OS setup, SSH, k3s, Dynatrace Operator
    30-easytrade.sh                    # EasyTrade Helm deployment
    40-easytrade-ingress.sh            # TLS ingress via Traefik + cert-manager
    50-argocd.sh                       # ArgoCD installation
    55-edgeconnect.sh.tpl              # Dynatrace EdgeConnect with OAuth
    60-zurich-hot.sh                   # Workshop microservices (build + deploy)
    65-disk-fillup.sh                  # PVC disk fill demo (4Gi over ~10 hours)
    70-argocd-workshop-app.sh.tpl      # ArgoCD Application + DT notifications
  run_remote_commands.sh               # Sequential SSH execution across VMs
  deploy-bad-release.sh                # Set payment-service failure rate on all VMs
  get_vm_info.sh                       # Retrieve URLs & credentials from VMs
k8-samples/                            # Sample K8s manifests for demos
```

## Key Conventions

### Script Patterns
- All scripts use `set -euo pipefail` and log to `/var/log/startup-parts.log`
- Logging: `log() { echo "[module-name] $*"; }`
- Always use explicit kubeconfig: `k3s kubectl --kubeconfig "/etc/rancher/k3s/k3s.yaml"`
- Wait loops: `for i in {1..60}; do ... sleep N; done`
- Idempotent operations: check-then-create or `--dry-run=client -o yaml | kubectl apply -f -`

### Terraform Templates
- `.tpl` files are processed by `templatefile()` — use `$${VAR}` for shell vars (Terraform escaping)
- Plain `.sh` files are included via `file()` — use `${VAR}` for shell vars normally
- All secrets passed as Terraform variables (`sensitive = true`)
- Heredoc markers are unique per part: `__PART_NN_NAME__`

### Naming
- VM hostnames: `simple-vm-N`
- DynaKube names: `dynakube-simple-vm-N`
- Users: `userN` (password in ssh_credentials.csv)
- Terraform variables: `snake_case`

## Dynatrace Environment
- Tenant: `ggg43721.sprint.dynatracelabs.com`
- API URL: `https://ggg43721.sprint.dynatracelabs.com/api`
- EdgeConnect apiServer: `ggg43721.sprint.apps.dynatracelabs.com`
- Operator helm chart: `oci://docker.io/dynatrace/dynatrace-operator`

## Workshop Services (zurich_hot)
Source: `https://github.com/mark-dt/zurich_hot.git`

| Service | Port | Endpoint |
|---------|------|----------|
| frontend | 3000 | Ingress at `workshop.<IP>.nip.io` |
| order-service | 3001 | `GET /order` (auto-generates orderId) |
| payment-service | 3002 | `GET /pay?orderId=X&amount=Y` |
| inventory-service | 3003 | `GET /check?item=X&qty=N` |
| notification-service | 3004 | `GET /notify?orderId=X&event=Y` |

Admin endpoint: `POST /admin/failure-rate` with `{"rate": 0.0-1.0}`

## Common Operations

```bash
# Provision VMs
terraform apply

# SSH into a VM (credentials in ssh_credentials.csv)
ssh userN@<IP>

# Run commands on all VMs
./scripts/run_remote_commands.sh ssh_credentials.csv scripts/commands.sh

# Deploy bad release / rollback
./scripts/deploy-bad-release.sh deploy-bad-release 0.7
./scripts/deploy-bad-release.sh rollback

# Check service from inside VM
curl "http://$(kubectl -n workshop get svc payment-service -o jsonpath='{.spec.clusterIP}'):3002/pay?orderId=TEST&amount=99.99"
```

## Files Never Committed
`terraform.tfvars`, `ssh_credentials.csv`, `*.tfstate` — contain secrets/credentials.

## Change Log

### EdgeConnect Module (55-edgeconnect.sh.tpl)
- Created startup script to deploy Dynatrace EdgeConnect via CR
- Added 4 Terraform variables: `edgeconnect_oauth_client_id`, `edgeconnect_oauth_client_secret`, `edgeconnect_oauth_endpoint`, `edgeconnect_oauth_resource`
- Wired into `main.tf` templatefile block and `bootstrap.sh.tpl` heredoc
- Fixed apiServer: must use `.sprint.apps.dynatracelabs.com` format (not `.sprint.dynatracelabs.com`)
- Changed API version from `v1alpha2` to `v1alpha1` per Dynatrace docs
- Secret uses `stringData` YAML format (not `kubectl create secret --dry-run`)
- CR and secret names include hostname for uniqueness: `edgeconnect-${HOSTNAME}`, `edgeconnect-${HOSTNAME}-oauth`
- Added `replicas: 1` to CR spec
- OAuth resource must be `urn:dtenvironment:<tenantId>` (not `urn:dtaccount:...`)
- Known issue: OAuth client must be environment-scoped to work with `urn:dtenvironment:` resource

### Dynatrace Operator (10-base.sh.tpl)
- Switched helm chart source from `public.ecr.aws/dynatrace/dynatrace-operator` to `docker.io/dynatrace/dynatrace-operator`
- Added `--set "installCRD=true"` and `--set "csidriver.enabled=true"`

### Remote Commands (run_remote_commands.sh)
- Changed from parallel execution (`xargs -P`) to sequential (`for` loop) — processes one VM at a time
- SSH output now goes to both console and log files via `tee` (was log-only)
- Removed `PARALLEL` variable

### Bad Release Script (deploy-bad-release.sh)
- New script replicating GitHub Actions workflow `workshop-deploy-bad-release.yaml`
- Iterates all VMs from `ssh_credentials.csv`
- Sets payment-service failure rate via `workshop.<IP>.nip.io/admin/failure-rate`
- Sends `CUSTOM_DEPLOYMENT` event to Dynatrace with correct `K8_CLUSTER` tag per VM

### Disk Fillup (65-disk-fillup.sh)
- Updated comment to match actual fill rate (~119KB/s, 4Gi in ~10 hours)
