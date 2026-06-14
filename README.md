# GCP Multi-Region GenAI Gateway & Routing Layer

A production-grade, multi-region API gateway that fronts Google Vertex AI's
Gemini models with a hybrid (exact + semantic) cache, OIDC-enforced edge
authentication, multi-region failover, and defense-in-depth security
controls. Built as a portfolio piece demonstrating senior-level GCP
architecture: zero application-code authentication, dual-topology Vertex AI
routing (single-region for embeddings, multi-region for generation), CMEK
encryption end-to-end, and Infrastructure Manager–managed Terraform.

**Live endpoint:** `https://ai.poweraim.net/v1/generate`
(OIDC token required — see [Quick Start](#quick-start))

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Key Design Decisions](#key-design-decisions)
- [GCP Services](#gcp-services)
- [Repository Structure](#repository-structure)
- [Quick Start](#quick-start)
- [Troubleshooting](#troubleshooting)
- [Enterprise Hardening — Layered Approach](#enterprise-hardening--layered-approach)
- [Cost Estimate](#cost-estimate)

---

## Overview

This gateway is a FastAPI proxy in front of Vertex AI Gemini, deployed to
Cloud Run across two regions (`us-east1` and `europe-west1`) behind a global
HTTPS load balancer. It exists to demonstrate a complete production pattern
for serving LLM traffic in a multi-region GCP environment.

**Functional capabilities**

- Hybrid cache: SHA-256 exact-hash + cosine-similarity semantic match over
  the recent 200 prompts. Sub-100ms response on hit, ~1.5s on miss.
- Multi-region failover: on Vertex AI 429/5xx in the local region, the
  request transparently retries in the peer region.
- Edge authentication: requests without a valid Google OIDC token bound to
  the gateway's custom audience are rejected by Google's edge before
  reaching the container.
- WAF + rate limiting: Cloud Armor with OWASP CRS preconfigured expressions
  (SQLi, XSS, RCE) plus per-IP rate-based ban (100 req/60s, 10-min ban on
  breach).
- Zero downloadable credentials: callers impersonate a service account to
  mint short-lived OIDC tokens. No JSON keys.

**Non-functional properties**

- All data at rest encrypted with customer-managed KMS keys (CMEK) per region.
- All Redis traffic encrypted in transit (TLS) with per-instance AUTH password.
- VPC-SC perimeter capable (variable-gated; see `var.vpc_sc_access_policy_id`).
- Direct VPC Egress (no Serverless VPC Connector) — Cloud Run instances
  attach directly to private subnets.
- Scale-to-zero idle cost on Cloud Run; cold start ~3s, warm latency ~500ms.

---

## Architecture

```
                            Internet
                                │
                                ▼
              ┌─────────────────────────────────┐
              │ Cloud Armor (Layer 7)            │
              │ — Rate-based ban: 100/60s/IP    │
              │ — OWASP CRS: SQLi/XSS/RCE       │
              │ — Adaptive Protection (DDoS L7) │
              └─────────────────────────────────┘
                                │
                                ▼
              ┌─────────────────────────────────┐
              │ Global HTTPS Load Balancer       │
              │ — Anycast IP: 34.8.143.146       │
              │ — Managed SSL: ai.poweraim.net   │
              │ — SSL policy: modern (TLS 1.3+)  │
              └─────────────────────────────────┘
                                │
                                ▼
        ┌────────────────────────────────────────────┐
        │ Google Edge: OIDC Token Validation         │
        │ — Audience match: https://ai.poweraim.net  │
        │ — Signature + expiry verification          │
        │ — IAM check: gateway-consumer@... only     │
        └────────────────────────────────────────────┘
                                │
            ┌───────────────────┴───────────────────┐
            ▼                                       ▼
    ┌──────────────────┐                    ┌──────────────────┐
    │ Cloud Run        │                    │ Cloud Run        │
    │ us-east1         │  ◄─── failover ──► │ europe-west1     │
    │ (Direct VPC Egr) │                    │ (Direct VPC Egr) │
    └──────────────────┘                    └──────────────────┘
            │                                       │
            ├─── TLS+AUTH ──► Memorystore Redis     │
            │                  (genai-cache, CMEK) │
            │                                       │
            ▼                                       ▼
    Vertex AI Routing:
      ├─ Embeddings  → us-east1 / europe-west1 (single-region)
      └─ Generation  → us / eu                 (multi-region)
```

---

## Key Design Decisions

### 1. Edge authentication, not in-application JWT validation
Cloud Run is configured with `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`
and `roles/run.invoker` is bound exclusively to a dedicated
`gateway-consumer` service account — never to `allUsers`. Token validation
happens in Google's edge infrastructure before the request reaches the
container. The FastAPI app contains zero authentication code; identity is a
platform concern, not an application concern.

### 2. Custom audience for multi-region failover
A standard OIDC token's `aud` claim is tied to a specific Cloud Run service URL.
On failover from `us-east1` to `europe-west1`, the audience check would fail
with 403. Both services declare `custom_audiences = ["https://ai.poweraim.net"]`,
so a single token validates against either backend.

### 3. Service-account impersonation, not JSON keys
Callers obtain identity tokens by impersonating `gateway-consumer@...` via
`roles/iam.serviceAccountTokenCreator`. No long-lived credentials are
created or distributed. Token rotation is automatic (1-hour expiry).

### 4. Dual-topology Vertex AI routing
Vertex segments models across two endpoint types:
- **Single-region** (`us-east1`, `europe-west1`): `text-embedding-004` and
  legacy/custom-deployed models.
- **Multi-region** (`us`, `eu`): Gemini 2.5+/3.x SaaS models. URL form:
  `aiplatform.{us|eu}.rep.googleapis.com`.

A request to the wrong topology returns 404 with no helpful diagnostic.
Each `VertexClient` maintains two `genai.Client` instances — one per
topology — and selects the correct one per method (`embed` vs `generate`).

### 5. `google-genai` SDK over legacy `vertexai` module
The legacy SDK uses a process-global `vertexai.init()` singleton that
races between concurrent multi-region clients (local and peer
`VertexClient` instances overwrite each other's location). The
`google-genai` SDK uses per-instance Client objects with no global state —
the only safe choice for multi-region failover patterns.

### 6. Hybrid cache (exact + semantic)
Exact cache (SHA-256 hash of prompt) catches verbatim repeats. Semantic
cache (cosine similarity over `text-embedding-004` embeddings, 0.92
threshold, recent-200 window) catches paraphrased repeats. Runs on
Memorystore BASIC — no RediSearch module needed.

### 7. CMEK + TLS + AUTH on Memorystore
Three layers: customer-managed KMS key for encryption at rest,
`SERVER_AUTHENTICATION` for TLS in transit, per-instance AUTH password
required before any command. The auth string is sourced from
Memorystore's managed API via Terraform and injected as a Cloud Run env var.

### 8. Direct VPC Egress over Serverless VPC Connector
Cloud Run instances attach directly to subnets with
`PRIVATE_RANGES_ONLY` egress. Lower latency, lower cost, no separate
connector resource to maintain.

### 9. Infrastructure Manager (managed Terraform)
Cloud Deployment Manager is EOL March 2026. Infrastructure Manager is its
replacement and runs Terraform 1.5.7 in a Google-managed worker. No local
Terraform install required; state lives in GCS managed by Google.

---

## GCP Services

| Service | Purpose |
|---|---|
| Cloud Run v2 | Stateless gateway containers, scale-to-zero |
| Vertex AI | Gemini Flash for generation, text-embedding-004 for caching |
| Memorystore Redis | Hybrid cache (CMEK + TLS + AUTH) |
| Cloud Load Balancing | Global HTTPS LB with Serverless NEGs |
| Cloud Armor | WAF + rate limiting |
| Cloud KMS | CMEK for Redis and logs, per region |
| Secret Manager | Third-party LLM API keys (placeholder slot) |
| Service Networking + PSC | Private connectivity to Vertex AI APIs |
| Cloud DNS | Externally managed (GoDaddy) — A record to LB IP |
| Artifact Registry | Container image hosting |
| Cloud Build | CI for container builds |
| Infrastructure Manager | Managed Terraform 1.5.7 |
| IAM | Workload identity + impersonation for callers |
| Cloud Logging | Structured JSON logs from FastAPI |

---

## Repository Structure

```
gcp-genai-gateway/
├── *.tf                          # Terraform (root module)
│   ├── network.tf                # VPC, subnets, firewall, PSC, PSA
│   ├── compute.tf                # Cloud Run + IAM auth wiring
│   ├── cache.tf                  # Memorystore Redis (per region)
│   ├── security.tf               # KMS keyrings + Secret Manager
│   ├── armor.tf                  # Cloud Armor policy
│   ├── lb.tf                     # Global LB, NEGs, backend, URL map
│   ├── variables.tf              # Variable definitions
│   ├── outputs.tf                # Exposed values (IP, SA, audience)
│   └── terraform.tfvars          # Project-specific values
├── container/
│   ├── Dockerfile                # Multi-stage Python 3.12-slim
│   ├── requirements.txt          # fastapi, uvicorn, redis, google-genai
│   ├── build_and_push.ps1        # Cloud Build → Artifact Registry
│   └── app/
│       ├── main.py               # FastAPI: routes, lifespan, request flow
│       ├── llm.py                # VertexClient (dual-topology)
│       ├── cache.py              # SemanticCache (Redis TLS+AUTH)
│       └── pii.py                # PII scrubbing for log safety
├── scripts/
│   └── deploy.ps1                # Package + submit to Infra Manager
└── docs/
    ├── architecture.md           # Deeper architectural narrative
    └── threat-model.md           # STRIDE threat model
```

---

## Quick Start

### Prerequisites

- GCP project with billing enabled
- `gcloud` CLI ≥ 500.0.0 logged in as a project Owner
- PowerShell 7 (Windows) or any POSIX shell
- A domain you control for the gateway hostname

### One-time setup

```powershell
# Set the quota project for local credentials
gcloud auth application-default set-quota-project "<your-project-id>"
gcloud services enable aiplatform.googleapis.com --project="<your-project-id>"

# Copy terraform.tfvars.example to terraform.tfvars and fill in:
#   project_id, project_number, gateway_hostname, container_image
```

### Deploy

```powershell
# 1. Build and push the container
cd container
.\build_and_push.ps1
cd ..

# 2. Apply infrastructure
.\scripts\deploy.ps1
```

Deploy takes ~5 minutes for a fresh project, ~1-2 minutes for incremental
changes. Watch progress:

```powershell
gcloud infra-manager deployments describe genai-gateway `
  --location=us-east1 --project=<your-project-id> `
  --format="value(state,latestRevision)"
```

When the state reaches `ACTIVE`, grab the LB IP and add a DNS A record at
your registrar:

```powershell
gcloud compute addresses describe genai-gateway-ip --global `
  --project=<your-project-id> --format="value(address)"
```

DNS propagation: 5-30 minutes. SSL cert provisioning: 15-60 minutes after
DNS resolves.

### Invoke

```powershell
$token = gcloud auth print-identity-token `
  --impersonate-service-account=gateway-consumer@<project>.iam.gserviceaccount.com `
  --audiences=https://<your-hostname>

Invoke-RestMethod -Uri "https://<your-hostname>/v1/generate" `
  -Method Post -ContentType "application/json" `
  -Headers @{ Authorization = "Bearer $token" } `
  -Body (@{prompt="What is the capital of Poland?"} | ConvertTo-Json)
```

Expected response:
```
response          : The capital of Poland is **Warsaw**.
cached            : False
served_by_region  : us-east1
latency_ms        : ~1500
```

Run a second time with the same prompt: `cached: True`, `latency_ms < 100`.

---

## Troubleshooting

### Pull the latest container logs

```powershell
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="ai-gateway-us-east1"' `
  --project=<project> --limit=20 --format=json --order=desc | `
  ConvertFrom-Json | ForEach-Object {
    Write-Host "---"; Write-Host $_.timestamp; Write-Host $_.severity
    Write-Host $_.textPayload; Write-Host ($_.jsonPayload | ConvertTo-Json -Compress)
  }
```

### Pull Infrastructure Manager apply artifacts

```powershell
$rev = (gcloud infra-manager deployments describe genai-gateway `
  --location=us-east1 --project=<project> `
  --format="value(latestRevision)").Split("/")[-1]

Remove-Item "$env:TEMP\im-logs" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$env:TEMP\im-logs" -Force | Out-Null
gcloud storage cp --recursive `
  "gs://<project-number>-us-east1-blueprint-config/genai-gateway/$rev/apply_results/artifacts/*" `
  "$env:TEMP\im-logs"

Get-Content "$env:TEMP\im-logs\log.json" | `
  Select-String -Pattern "Error:|level=error" | Select-Object -Last 30
```

### Verify Cloud Run service health

```powershell
gcloud run services list --project=<project> `
  --format="table(metadata.name,status.url,status.conditions[0].status,status.latestReadyRevisionName)"
```

### Verify identity and IAM

```powershell
# What identity am I?
gcloud auth list

# Can I impersonate the consumer SA?
gcloud iam service-accounts get-iam-policy `
  gateway-consumer@<project>.iam.gserviceaccount.com --project=<project>

# Does the gateway runner SA have aiplatform.user?
gcloud projects get-iam-policy <project> `
  --flatten="bindings[].members" `
  --filter="bindings.members:ai-gateway-runner AND bindings.role:roles/aiplatform.user" `
  --format="value(bindings.role)"
```

### Check the managed SSL certificate

```powershell
gcloud compute ssl-certificates describe genai-gateway-cert --global `
  --project=<project> `
  --format="value(managed.status,managed.domainStatus)"
```

Statuses: `PROVISIONING/PROVISIONING` (waiting), `PROVISIONING/FAILED_NOT_VISIBLE`
(DNS not propagated yet), `ACTIVE/ACTIVE` (ready to serve).

### List available Gemini models in your project

```powershell
gcloud ai model-garden models list `
  --project="<project>" `
  --billing-project="<project>" | Select-String "gemini"
```

### Test a specific Vertex AI model identifier directly

```powershell
$at = gcloud auth print-access-token
$url = "https://aiplatform.us.rep.googleapis.com/v1/projects/<project>/locations/us/publishers/google/models/gemini-3.5-flash:generateContent"
$body = '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
Invoke-RestMethod -Uri $url -Method Post `
  -Headers @{Authorization="Bearer $at"} `
  -ContentType "application/json" -Body $body
```

If this works but the gateway doesn't, the issue is in the container code,
not Vertex availability.

### Force a Cloud Run revision rebuild (no Terraform change needed)

```powershell
gcloud run services update ai-gateway-us-east1 --region=us-east1 `
  --project=<project> --update-env-vars=REDEPLOY_TS=$(Get-Date -UFormat %s)
gcloud run services update ai-gateway-europe-west1 --region=europe-west1 `
  --project=<project> --update-env-vars=REDEPLOY_TS=$(Get-Date -UFormat %s)
```

---

## Enterprise Hardening — Layered Approach

The deployed stack covers Layers 1-4 below. Layers 5-7 are documented as
the production-readiness roadmap.

### Layer 1 — Network isolation (deployed)
- Cloud Run with `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` (no direct `*.run.app` exposure)
- Direct VPC Egress with `PRIVATE_RANGES_ONLY`
- Custom VPC with regional subnets, no auto-mode networking
- Firewall rules: explicit allow for internal traffic and Google private APIs only
- PSC forwarding rule for private Vertex AI connectivity

### Layer 2 — Identity & access (deployed)
- No `allUsers` invoker bindings anywhere
- Consumer SA + `iam.serviceAccountTokenCreator` impersonation pattern
- Per-region custom audience eliminates cross-region 403s
- OIDC token validation at Google's edge before traffic hits container
- Workload service account (`ai-gateway-runner`) with least-privilege role set:
  `aiplatform.user`, `logging.logWriter`, `monitoring.metricWriter`,
  `secretmanager.secretAccessor`

### Layer 3 — Edge protection (deployed)
- Cloud Armor security policy attached to backend service
- Per-IP rate-based ban (100 req/60s, 10-min ban duration)
- OWASP CRS preconfigured expressions: SQLi, XSS, RCE
- Adaptive Protection L7 DDoS defense enabled
- Modern SSL policy (TLS 1.3+)

### Layer 4 — Data encryption (deployed)
- CMEK on Memorystore Redis (per-region keys in matching regional keyrings)
- TLS in transit for Redis (`transit_encryption_mode = SERVER_AUTHENTICATION`)
- Per-instance Redis AUTH password, injected via Cloud Run env from Terraform
- CMEK keyring for Cloud Logging (per region)
- Secret Manager for third-party API key storage with placeholder version

### Layer 5 — VPC Service Controls (capability included, perimeter not joined)
The Terraform supports VPC-SC via `var.vpc_sc_access_policy_id`. In an
enterprise deployment, the project would be added to a perimeter that
restricts Vertex AI, Secret Manager, and KMS to internal traffic only.
This requires an organization-level access policy that a portfolio project
in a personal account cannot create.

### Layer 6 — Audit and observability (roadmap)
- Cloud Audit Logs (Admin Activity) are on by default; Data Access logs
  should be enabled for `secretmanager.googleapis.com` and `aiplatform.googleapis.com`
- Custom log-based metrics for rate-limit hits, cache hit ratio, failover frequency
- Cloud Monitoring dashboards: p50/p95/p99 latency per region, error budget burn
- BigQuery sink for long-term retention of structured request logs

### Layer 7 — Operational maturity (roadmap)
- Move Redis AUTH string into Secret Manager with rotation policy
- Switch managed SSL cert to a wildcard or multi-SAN cert for additional hostnames
- Add canary deployment via Cloud Run traffic splitting (10% to new revision, then 100%)
- Add scheduled chaos test: kill a region's Cloud Run service, verify gateway
  failover and SLO compliance
- Migrate Cloud Armor to per-customer rate limit keys (e.g. `enforce_on_key = HTTP_HEADER`
  keyed on `Authorization` token hash) for multi-tenant fairness

---

## Cost Estimate

Steady-state at light traffic (this portfolio configuration):

| Resource | Monthly cost |
|---|---|
| Cloud Run × 2 (scale-to-zero, idle) | ~$0 |
| Memorystore Redis BASIC 5GB × 2 | ~$300 |
| KMS keys × 4 (per-region + per-purpose) | ~$0.24 |
| Global LB forwarding rule | ~$18 |
| Cloud Armor policy | ~$5 base + $1/M requests |
| Managed SSL certificate | $0 |
| Artifact Registry storage (single image) | ~$0.10 |
| Cloud Logging + Monitoring | ~$0-5 |
| Vertex AI calls (Gemini 2.5/3.5 Flash) | Per-token, ~$0.07/$0.30 per 1M tokens |
| Network egress (US/EU intra-region) | ~$0 |
| **Total baseline** | **~$330/month** |

Cost can drop ~$60/month by switching Memorystore to a single
`BASIC 1GB` instance and skipping the secondary region (single-region
deployment), at the cost of failover capability.

Cost can rise meaningfully under sustained traffic — the Cloud Armor
per-million-requests charge dominates above ~10M req/month, and
Vertex AI Gemini calls scale linearly with token volume.

---

## License

MIT
