# QuickCart

## Project Overview
Workshop demo environment for Dynatrace HOT (Hands-On Training) sessions. Combines two apps:
- **Workshop app**: Custom Node.js microservices (frontend, order-service, payment-service, inventory-service, notification-service) running on k3s
- **EasyTrade**: Dynatrace demo trading app with feature flag-based problem patterns

## Architecture

### Workshop App (k8s/k3s)
- Services run in `workshop` namespace on k3s
- Frontend proxies `/admin/failure-rate` to all payment-service pods via headless service DNS (`payment-service-headless`)
- Payment-service has a runtime-mutable failure rate (`POST /admin/failure-rate` with `{"rate": 0.7}`)
- No pod restarts needed for failure rate changes — all replicas updated via API fan-out

### Dynatrace Version Detection
All service manifests include labels and env vars for Dynatrace release tracking:
- Pod labels: `app.kubernetes.io/version` → `DT_RELEASE_VERSION`, `app.kubernetes.io/part-of` → `DT_RELEASE_PRODUCT`
- Env vars: `DT_RELEASE_VERSION`, `DT_RELEASE_PRODUCT`, `DT_RELEASE_STAGE`
- Baseline version is `1.0.0`; the `workshop-release` workflow bumps payment-service to `bad-release-<N>` / `rollback-<N>`

### EasyTrade
- Feature flags toggled via `PUT {EASYTRADE_BASE_URL}/feature-flag-service/v1/flags/{FF_KEY}`
- Flags: `db_not_responding`, `factory_crisis`, `ergo_aggregator_slowdown`, `high_cpu_usage`

## Project Structure
```
services/                  # Node.js microservices (frontend, order, payment, inventory, notification)
k8s/                       # Kubernetes manifests for workshop namespace
.github/workflows/         # GitHub Actions (workshop-* and easytrade-* prefixed)
dynatrace-workflows/       # Exported Dynatrace workflow JSONs
scripts/                   # deploy-bad-release.sh, rollback.sh
```

## GitHub Workflows
All in `.github/workflows/`, prefixed by target app:
- `workshop-deploy-bad-release.yaml` — Set/rollback payment-service failure rate via HTTP API. Supports `workflow_dispatch` and `repository_dispatch` (event: `auto-remediate`)
- `workshop-release.yaml` — GitOps release: commits version label + failure rate changes to `k8s/payment-service.yaml` for ArgoCD sync. Supports `workflow_dispatch` and `repository_dispatch` (event: `auto-remediate-release`). Uses `yq` to update manifest.
- `workshop-build-and-push.yaml` — Build and push Docker images
- `easytrade-ff-*.yaml` — Toggle individual feature flags. Each supports `repository_dispatch` for auto-remediation
- `easytrade-auto-remediation.yaml` — Generic remediation via `repository_dispatch` with `ff_key` in payload
- `easytrade-simulate-release.yaml` — Generic feature flag + deployment event

### Workflow Patterns
- "Resolve action" step handles both `workflow_dispatch` and `repository_dispatch` triggers
- Dynatrace deployment events use `K8_CLUSTER` secret, `entitySelector` with `entityName.startsWith()` and environment tag
- Heredocs must be unquoted (`<<EOF` not `<<'EOF'`) so `${K8_CLUSTER}` shell variable expands

## Dynatrace Workflows
Exported workflow JSONs in `dynatrace-workflows/` folder:
- Sensitive fields (`id`, `actor`, `owner`, `ownerType`) removed before committing
- GitHub PAT referenced as `{{ env.GITHUB_PAT }}` — never hardcode tokens

## Secrets (GitHub Actions)
`DT_ENV_URL`, `DT_API_TOKEN`, `WORKSHOP_IP`, `K8_CLUSTER`, `EASYTRADE_BASE_URL`
