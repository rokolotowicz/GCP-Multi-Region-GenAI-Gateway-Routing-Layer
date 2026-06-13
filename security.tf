# ----------------------------------------------------------------------------
# Cloud KMS — CMEK for Redis cache + logging
# ----------------------------------------------------------------------------
resource "google_kms_key_ring" "main" {
  name       = "genai-gateway-kr-v2"
  location   = var.primary_region
  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "redis" {
  name            = "cmek-redis-key"
  key_ring        = google_kms_key_ring.main.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"
}

resource "google_kms_crypto_key" "logging" {
  name            = "cmek-logging-key"
  key_ring        = google_kms_key_ring.main.id
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"
}

# Allow the Redis service agent to use the CMEK key
data "google_project" "current" {}

resource "google_kms_crypto_key_iam_member" "redis_cmek" {
  crypto_key_id = google_kms_crypto_key.redis.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@cloud-redis.iam.gserviceaccount.com"
}

# Secondary-region KMS — required because CMEK keys must live in the same
# region as the Memorystore instance that uses them.
resource "google_kms_key_ring" "secondary" {
  name       = "genai-gateway-kr-eu-v2"
  location   = var.secondary_region
  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "redis_secondary" {
  name            = "cmek-redis-key-eu"
  key_ring        = google_kms_key_ring.secondary.id
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"
}

resource "google_kms_crypto_key_iam_member" "redis_cmek_secondary" {
  crypto_key_id = google_kms_crypto_key.redis_secondary.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@cloud-redis.iam.gserviceaccount.com"
}

# ----------------------------------------------------------------------------
# Service account for Cloud Run
# Least privilege: only Vertex AI user + Secret accessor
# ----------------------------------------------------------------------------
resource "google_service_account" "gateway" {
  account_id   = "ai-gateway-runner"
  display_name = "GenAI Gateway Cloud Run runtime SA"
}

resource "google_project_iam_member" "gateway_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.gateway.email}"
}

resource "google_project_iam_member" "gateway_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.gateway.email}"
}

resource "google_project_iam_member" "gateway_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gateway.email}"
}

resource "google_project_iam_member" "gateway_metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gateway.email}"
}

# ----------------------------------------------------------------------------
# Secret Manager — third-party LLM provider keys (for hybrid fallback)
# ----------------------------------------------------------------------------
resource "google_secret_manager_secret" "third_party_keys" {
  secret_id = "third-party-api-keys"
  replication {
    user_managed {
      replicas {
        location = var.primary_region
      }
      replicas {
        location = var.secondary_region
      }
    }
  }
  depends_on = [google_project_service.apis]
}

# Placeholder version so Cloud Run can mount the secret at startup.
# Replace via console / gcloud once you have real provider keys.
resource "google_secret_manager_secret_version" "third_party_keys_initial" {
  secret      = google_secret_manager_secret.third_party_keys.id
  secret_data = "PLACEHOLDER_REPLACE_VIA_CONSOLE"
}

# ----------------------------------------------------------------------------
# VPC Service Controls perimeter
# Created in DRY-RUN mode so violations are logged but not blocked.
# Flip use_explicit_dry_run_spec=false and remove dry_run wrappers for enforced.
# ----------------------------------------------------------------------------
resource "google_access_context_manager_service_perimeter" "genai_perimeter" {
  count  = var.vpc_sc_access_policy_id == "" ? 0 : 1
  parent = "accessPolicies/${var.vpc_sc_access_policy_id}"
  name   = "accessPolicies/${var.vpc_sc_access_policy_id}/servicePerimeters/genai_gateway"
  title  = "genai_gateway"

  use_explicit_dry_run_spec = true

  spec {
    resources = ["projects/${var.project_number}"]
    restricted_services = [
      "aiplatform.googleapis.com",
      "run.googleapis.com",
      "redis.googleapis.com",
      "secretmanager.googleapis.com",
      "storage.googleapis.com",
    ]
    vpc_accessible_services {
      enable_restriction = true
      allowed_services   = ["RESTRICTED-SERVICES"]
    }
  }
}
