# QuickCart

Microservices order processing demo deployed on a single GCP VM with k3s. Demonstrates service-to-service communication, failure injection, and automated problem detection with Dynatrace.

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
| **frontend** | 3000 | API gateway — receives requests and forwards to order-service |
| **order-service** | 3001 | Orchestrates orders — calls payment-service and inventory-service in parallel |
| **payment-service** | 3002 | Processes payments — calls notification-service on success. Supports `FAILURE_RATE` env var to simulate failures |
| **inventory-service** | 3003 | Checks stock availability (leaf service) |
| **notification-service** | 3004 | Sends order confirmations via email (leaf service) |
| **load-generator** | — | Continuously hits `frontend /order` every 2 seconds to generate traffic |

All services are minimal Node.js/Express apps with structured JSON logging and health endpoints (`GET /health`).

## EasyTrade Feature Flags

EasyTrade exposes 4 problem patterns via its feature flag service:

| Flag | Affected Service | What It Simulates |
|---|---|---|
| `db_not_responding` | Login/Account/Trade services | Database unavailability — prevents new trades (~20 min to observe) |
| `factory_crisis` | Third-Party Service | Credit card manufacturing halt — blocks card processing |
| `ergo_aggregator_slowdown` | Offer/Aggregator Services | Aggregator degradation — slow responses, reduced traffic |
| `high_cpu_usage` | Broker Service | Artificial CPU load — increased latency and CPU throttling |

Flags are toggled via: `PUT /feature-flag-service/v1/flags/{flag_key}` with body `{"enabled": true/false}`

## GitHub Actions Pipelines

### Feature Flag Workflows (one per flag)

Each workflow is a `workflow_dispatch` with an **enable/disable** choice. It toggles the flag on EasyTrade and sends a `CUSTOM_DEPLOYMENT` event to Dynatrace.

| Workflow | File |
|---|---|
| Release: DB Not Responding | `.github/workflows/ff-db-not-responding.yaml` |
| Release: Factory Crisis | `.github/workflows/ff-factory-crisis.yaml` |
| Release: Aggregator Slowdown | `.github/workflows/ff-ergo-aggregator-slowdown.yaml` |
| Release: High CPU Usage | `.github/workflows/ff-high-cpu-usage.yaml` |

### Auto-Remediation Pipeline

**File:** `.github/workflows/auto-remediation.yaml`

Triggered automatically by Dynatrace via `repository_dispatch` (event type: `remediation`). Receives `{ "ff_key": "<flag>" }` in the payload, disables the specified feature flag, and sends a remediation event back to Dynatrace.

### Build and Push

**File:** `.github/workflows/build-and-push.yaml`

Builds all 5 service Docker images on push to `main` (when `services/` changes) and pushes them to GHCR.

### Deploy Bad Release (Custom Services)

**File:** `.github/workflows/deploy-bad-release.yaml`

Manual `workflow_dispatch` to set `FAILURE_RATE` on payment-service via SSH into the VM. Supports `deploy-bad-release` and `rollback` actions.

## Dynatrace Workflow

**File:** `dynatrace-workflow.json`

Import into Dynatrace via **Automations > Workflows**. The workflow:

1. **Triggers** on Davis problem detection (error category on EasyTrade entities)
2. **Identifies** the responsible feature flag by mapping the affected service name
3. **Calls** the GitHub `auto-remediation` pipeline via `repository_dispatch` to disable the flag

### Remediation Loop

```
1. Trigger feature flag pipeline (enable) ──> EasyTrade starts failing
2. Dynatrace detects failure rate increase ──> Davis opens a problem
3. Dynatrace workflow fires ──> identifies the flag ──> calls GitHub API
4. auto-remediation.yaml runs ──> disables the flag ──> sends event to Dynatrace
5. Service recovers ──> problem closes
```

## Manual Scripts

| Script | Description |
|---|---|
| `scripts/deploy-bad-release.sh [RATE]` | Sets `FAILURE_RATE` on payment-service (default: 0.7 = 70% failures) |
| `scripts/rollback.sh` | Resets `FAILURE_RATE` to 0 |

Run these directly on the VM where k3s is running.

## Startup Script

**File:** `startup.sh`

Referenced by Terraform `google_compute_instance`. Bootstraps the VM:

1. Installs Docker and k3s (single-node cluster)
2. Clones this repository
3. Builds all service Docker images locally
4. Imports images into k3s containerd
5. Applies all Kubernetes manifests

## K8s Manifests

All manifests are in `k8s/` and deploy to the `workshop` namespace:

- `namespace.yaml` — creates the `workshop` namespace
- `frontend.yaml` — Deployment (2 replicas) + ClusterIP Service
- `order-service.yaml` — Deployment (2 replicas) + ClusterIP Service
- `payment-service.yaml` — Deployment (2 replicas) + ClusterIP Service
- `inventory-service.yaml` — Deployment (2 replicas) + ClusterIP Service
- `notification-service.yaml` — Deployment (1 replica) + ClusterIP Service
- `load-generator.yaml` — Deployment running a curl loop for continuous traffic

## Required Secrets

### GitHub Repository Secrets

| Secret | Description |
|---|---|
| `EASYTRADE_BASE_URL` | EasyTrade base URL, e.g. `http://<VM-IP>` |
| `DT_ENV_URL` | Dynatrace environment URL, e.g. `https://abc12345.live.dynatrace.com` |
| `DT_API_TOKEN` | Dynatrace API token with `events.ingest` scope |
| `GCP_SA_KEY` | GCP service account key JSON (for deploy-bad-release SSH) |
| `GCP_PROJECT` | GCP project ID |
| `VM_NAME` | GCP VM instance name |
| `VM_ZONE` | GCP VM zone |

### Dynatrace

| Setting | Description |
|---|---|
| `GITHUB_PAT` environment variable | GitHub Personal Access Token with `repo` scope (for repository_dispatch) |

Set this in **Dynatrace > Automations > Settings > Environment Variables**.
