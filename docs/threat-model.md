# Threat Model — GenAI Gateway

Concise threat-to-mitigation matrix mapped to this codebase. Use this as the security narrative for the portfolio piece.

| # | Threat | Attack vector | Mitigation in this repo | File |
|---|---|---|---|---|
| T1 | **LLM cost-depletion / abuse** | Attacker fires high-volume requests to drain Vertex AI quota and inflate the bill | Cloud Armor per-IP throttle (`var.rate_limit_rpm` req/60s), `deny(429)` on exceed; adaptive L7 DDoS defense | `armor.tf` |
| T2 | **Prompt injection / OWASP web attacks** | Crafted payload abuses parser or downstream model | Cloud Armor preconfigured WAF rules: argument injection, SQLi, XSS | `armor.tf` |
| T3 | **Data exfiltration to external GCP project** | Compromised SA copies cache or logs out of the perimeter | VPC Service Controls perimeter restricts `aiplatform`, `run`, `redis`, `secretmanager`, `storage` to the project | `security.tf` |
| T4 | **Bypassing the gateway** | Client tries to call Cloud Run directly, skipping Armor + rate limit | `ingress = INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` rejects all non-LB traffic | `compute.tf` |
| T5 | **Public-internet exposure of Vertex AI traffic** | Egress traverses public internet, opens MITM/exfil surface | Private Service Connect endpoint for `aiplatform.googleapis.com`; Cloud Run uses Direct VPC Egress with `PRIVATE_RANGES_ONLY` | `network.tf`, `compute.tf` |
| T6 | **Excessive blast radius from runtime SA** | A compromised container assumes too much project authority | Dedicated SA with only `aiplatform.user`, `secretmanager.secretAccessor`, `logging.logWriter`, `monitoring.metricWriter` | `security.tf` |
| T7 | **Cache poisoning / cache-at-rest disclosure** | Attacker reads physical disks or peeks at Redis | Memorystore with CMEK (Cloud KMS), `transit_encryption_mode=SERVER_AUTHENTICATION`, AUTH enabled, PRIVATE_SERVICE_ACCESS | `cache.tf`, `security.tf` |
| T8 | **Single-region outage** | A regional Vertex AI or Cloud Run outage takes down the service | Multi-region Cloud Run behind a global ALB with geo-DNS; gateway code implements circuit-breaker to peer region | `loadbalancer.tf`, `dns.tf`, app code |
| T9 | **Secret leakage** | Static keys in container images or env files | Secrets mounted from Secret Manager at runtime; CMEK on logging bucket prevents accidental exposure via log dumps | `compute.tf`, `security.tf` |
| T10 | **PII in logs** | Application writes request bodies to Cloud Logging | Gateway code MUST scrub PII before logging — enforced in container, audited via Log Router sample | (app code) |
| T11 | **TLS downgrade** | Attacker forces obsolete cipher | `MODERN` SSL policy, TLS 1.2 minimum, Google-managed cert | `loadbalancer.tf` |

## What's intentionally NOT in scope here

- **Binary Authorization** — recommended for prod (see README hardening checklist), omitted to keep the dev footprint minimal.
- **Cloud IDS** — optional add-on; for a portfolio piece, the ALB + Armor + VPC-SC combo is the defensible minimum.
- **Org Policy constraints** — these belong at org/folder scope, not in a project-scoped module.
