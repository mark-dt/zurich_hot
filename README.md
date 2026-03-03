# GCP K3s Workshop Environment

Terraform project that provisions GCP Compute Engine VMs, each running a single-node [k3s](https://k3s.io/) Kubernetes cluster pre-loaded with demo workloads. Designed for Dynatrace workshops where every participant gets their own isolated environment.

## How It Works

`terraform apply` spins up one or more Debian VMs (`instance_count`). Each VM runs a bootstrap script that executes numbered shell modules in order, building up the full environment from base OS config to running applications.

## Project Structure

```
main.tf                 # VM instances, firewall rules, credentials output
variables.tf            # GCP project/zone, instance count, Dynatrace tokens
outputs.tf              # Public IPs, SSH commands, credentials CSV path
scripts/
  bootstrap.sh.tpl      # Assembles all part scripts and runs them in order
  run_remote_commands.sh # Helper to SSH into VMs in parallel
  parts/
    10-base.sh.tpl              # OS setup, SSH, Dynatrace OneAgent, k3s install
    30-easytrade.sh             # EasyTrade sample app (Helm)
    40-easytrade-ingress.sh     # Ingress + TLS for EasyTrade (cert-manager, Traefik)
    50-argocd.sh                # ArgoCD install + ingress
    60-zurich-hot.sh            # Zurich HOT microservices app (build & deploy)
    65-disk-fillup.sh           # PVC that fills up over ~1h (Dynatrace forecasting demo)
    70-argocd-workshop-app.sh.tpl  # ArgoCD Application for zurich-hot (GitOps)
```

Scripts are numbered to control execution order. `.tpl` files are processed by Terraform's `templatefile()` to inject secrets/variables; plain `.sh` files are included as-is via `file()`.

## Usage

```bash
# Set required variables (or use a .tfvars file)
export TF_VAR_gcp_project="my-project"
export TF_VAR_dynatrace_operator_token="dt0c01.xxx"
export TF_VAR_dynatrace_data_ingest_token="dt0c01.xxx"
export TF_VAR_dynatrace_api_token="dt0c01.xxx"

terraform init
terraform apply
```

After apply, `ssh_credentials.csv` is generated with usernames, passwords, and IPs for all VMs.

## Startup Modules

| # | Module | What it does |
|---|--------|-------------|
| 10 | Base | Configures SSH with password auth, installs Dynatrace OneAgent, deploys k3s |
| 30 | EasyTrade | Deploys the EasyTrade multi-tier sample app via Helm |
| 40 | EasyTrade Ingress | Sets up Traefik ingress with Let's Encrypt TLS for EasyTrade |
| 50 | ArgoCD | Installs ArgoCD with ingress and TLS |
| 60 | Zurich HOT | Builds and deploys the zurich-hot microservices workshop app |
| 65 | Disk Fill-Up | Creates a 1Gi PVC that slowly fills (~17KB/s) for disk forecasting demos |
| 70 | ArgoCD Workshop App | Creates an ArgoCD Application pointing to the zurich-hot repo |
