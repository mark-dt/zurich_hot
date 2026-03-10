# QuickCart

Microservices order processing demo for Dynatrace HOT (Hands-On Training) sessions — demonstrates service-to-service communication, failure injection, and automated problem detection/remediation with Dynatrace.

## Architecture

```
                    ┌──────────────┐
   load-generator──>│   frontend   │ :3000
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ order-service │ :3001
                    └──┬────────┬──┘
                       │        │
              ┌────────▼──┐  ┌──▼───────────┐
              │  payment   │  │  inventory   │
              │  :3002     │  │  :3003       │
              └────────┬───┘  └──────────────┘
                       │
              ┌────────▼──────────┐
              │  notification-svc  │ :3004
              └───────────────────┘
```

### Services

| Service | Port | Description |
|---|---|---|
| **frontend** | 3000 | API gateway — receives requests and forwards to order-service. Proxies `/admin/failure-rate` to all payment-service pods via headless service DNS |
| **order-service** | 3001 | Orchestrates orders — calls payment-service and inventory-service in parallel |
| **payment-service** | 3002 | Processes payments — calls notification-service on success. Has a runtime-mutable failure rate (`POST /admin/failure-rate` with `{"rate": 0.7}`) — no pod restart needed |
| **inventory-service** | 3003 | Checks stock availability (leaf service) |
| **notification-service** | 3004 | Sends order confirmations via email (leaf service) |
| **load-generator** | — | Continuously hits `frontend /order` every 2 seconds to generate traffic |

All services are minimal Node.js/Express apps with structured JSON logging and health endpoints (`GET /health`).

## EasyTrade Feature Flags

EasyTrade is a separate Dynatrace demo trading app with problem patterns controlled via feature flags:

| Flag | Affected Service | What It Simulates |
|---|---|---|
| `db_not_responding` | Login/Account/Trade services | Database unavailability — prevents new trades (~20 min to observe) |
| `factory_crisis` | Third-Party Service | Credit card manufacturing halt — blocks card processing |
| `ergo_aggregator_slowdown` | Offer/Aggregator Services | Aggregator degradation — slow responses, reduced traffic |
| `high_cpu_usage` | Broker Service | Artificial CPU load — increased latency and CPU throttling |

Flags are toggled via: `PUT /feature-flag-service/v1/flags/{flag_key}` with body `{"enabled": true/false}`

## GitHub Actions Workflows

All workflows are in `.github/workflows/`, prefixed by target app (`workshop-` or `easytrade-`).

### Workshop App Workflows

| Workflow | File | Trigger |
|---|---|---|
| Build and Push | `workshop-build-and-push.yaml` | Push to `main` (when `services/` changes) |
| Deploy Bad Release | `workshop-deploy-bad-release.yaml` | `workflow_dispatch`, `repository_dispatch` (`auto-remediate`) |
| GitOps Release | `workshop-release.yaml` | `workflow_dispatch`, `repository_dispatch` (`auto-remediate-release`) |

- **Build and Push** — Builds all 5 service Docker images and pushes them to GHCR.
- **Deploy Bad Release** — Sets or rolls back the payment-service failure rate via HTTP API. Supports both manual dispatch and automated remediation.
- **GitOps Release** — Commits version label and failure rate changes to `k8s/payment-service.yaml` for ArgoCD sync. Uses `yq` to update the manifest. Bumps version to `bad-release-<N>` or `rollback-<N>`.

### EasyTrade Workflows

| Workflow | File | Trigger |
|---|---|---|
| Feature Flag: DB Not Responding | `easytrade-ff-db-not-responding.yaml` | `workflow_dispatch` |
| Feature Flag: Factory Crisis | `easytrade-ff-factory-crisis.yaml` | `workflow_dispatch` |
| Feature Flag: Aggregator Slowdown | `easytrade-ff-ergo-aggregator-slowdown.yaml` | `workflow_dispatch` |
| Feature Flag: High CPU Usage | `easytrade-ff-high-cpu-usage.yaml` | `workflow_dispatch` |
| Auto-Remediation | `easytrade-auto-remediation.yaml` | `repository_dispatch` (`remediation`) |
| Simulate Release | `easytrade-simulate-release.yaml` | `workflow_dispatch` |

Feature flag workflows toggle a flag on EasyTrade and send a `CUSTOM_DEPLOYMENT` event to Dynatrace. The auto-remediation workflow is triggered by Dynatrace via `repository_dispatch` with `{ "ff_key": "<flag>" }` in the payload.

### Workflow Patterns

- "Resolve action" step handles both `workflow_dispatch` and `repository_dispatch` triggers
- Dynatrace deployment events use `K8_CLUSTER` secret with `entitySelector` using `entityName.startsWith()` and environment tag
- Heredocs must be unquoted (`<<EOF` not `<<'EOF'`) so shell variables expand

## Dynatrace Workflows

Exported workflow JSONs in `dynatrace-workflows/`:

| File | Purpose |
|---|---|
| `workshop-auto-remediation-payment-service-failure-rate-rollback.workflow.json` | Auto-remediates payment-service failure rate issues |
| `workshop-notify-payment-service-issue-detection.workflow.json` | Notifies on payment-service problem detection |
| `workshop-predictive-pvc-usage.workflow.json` | Predictive PVC usage monitoring |

Import into Dynatrace via **Automations > Workflows**. Sensitive fields (`id`, `actor`, `owner`, `ownerType`) are removed before committing. GitHub PAT is referenced as `{{ env.GITHUB_PAT }}` — never hardcode tokens.

### Remediation Loop

```
1. Trigger bad release / feature flag ──> Service starts failing
2. Dynatrace detects failure rate increase ──> Davis opens a problem
3. Dynatrace workflow fires ──> calls GitHub API via repository_dispatch
4. Remediation workflow runs ──> fixes the issue ──> sends event to Dynatrace
5. Service recovers ──> problem closes
```

## Scripts

| Script | Description |
|---|---|
| `scripts/deploy-bad-release.sh [RATE]` | Sets failure rate on payment-service (default: 0.7 = 70% failures) |
| `scripts/rollback.sh` | Resets failure rate to 0 |

## K8s Manifests

All manifests are in `k8s/` and deploy to the `workshop` namespace:

- `namespace.yaml` — creates the `workshop` namespace
- `frontend.yaml` — Deployment (2 replicas) + ClusterIP Service
- `order-service.yaml` — Deployment (2 replicas) + ClusterIP Service
- `payment-service.yaml` — Deployment (2 replicas) + ClusterIP + headless Service (`payment-service-headless`)
- `inventory-service.yaml` — Deployment (2 replicas) + ClusterIP Service
- `notification-service.yaml` — Deployment (1 replica) + ClusterIP Service
- `load-generator.yaml` — Deployment running a curl loop for continuous traffic

All service pods include Dynatrace release tracking labels (`app.kubernetes.io/version`, `app.kubernetes.io/part-of`) and env vars (`DT_RELEASE_VERSION`, `DT_RELEASE_PRODUCT`, `DT_RELEASE_STAGE`). Baseline version is `1.0.0`.

## Required Secrets

### GitHub Repository Secrets

| Secret | Description |
|---|---|
| `DT_ENV_URL` | Dynatrace environment URL, e.g. `https://abc12345.live.dynatrace.com` |
| `DT_API_TOKEN` | Dynatrace API token with `events.ingest` scope |
| `EASYTRADE_BASE_URL` | EasyTrade base URL |
| `WORKSHOP_IP` | Workshop IP address |
| `K8_CLUSTER` | Dynatrace cluster identifier for entity selectors |

### Dynatrace

| Setting | Description |
|---|---|
| `GITHUB_PAT` environment variable | GitHub Personal Access Token with `repo` scope (for `repository_dispatch`) |

Set this in **Dynatrace > Automations > Settings > Environment Variables**.
