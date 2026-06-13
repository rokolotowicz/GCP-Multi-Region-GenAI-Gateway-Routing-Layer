# Cloud Run services in both regions, scale-to-zero, Direct VPC Egress on.
resource "google_cloud_run_v2_service" "gateway" {
  for_each            = toset(local.regions)
  name                = "ai-gateway-${each.key}"
  location            = each.key
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  deletion_protection = false
  custom_audiences    = ["https://${var.gateway_hostname}"]
  template {
    service_account = google_service_account.gateway.email
    scaling {
      min_instance_count = 0   # scale-to-zero
      max_instance_count = 100
    }
    # Direct VPC Egress — no Serverless VPC Connector needed
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.subnets[each.key].id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }
    containers {
      image = var.container_image
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "REDIS_HOST"
        value = google_redis_instance.cache[each.key].host
      }
      env {
        name  = "REDIS_PORT"
        value = google_redis_instance.cache[each.key].port
      }
      env {
        name  = "REDIS_AUTH"
        value = google_redis_instance.cache[each.key].auth_string
      }
      env {
        name  = "PRIMARY_REGION"
        value = var.primary_region
      }
      env {
        name  = "SECONDARY_REGION"
        value = var.secondary_region
      }
      env {
        name  = "LOCAL_REGION"
        value = each.key
      }
      env {
        name  = "VERTEX_ENDPOINT"
        value = "aiplatform.googleapis.com"
      }
      env {
        name = "THIRD_PARTY_API_KEYS"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.third_party_keys.secret_id
            version = "latest"
          }
        }
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }
    }
  }
  labels = var.labels
  depends_on = [
    google_project_iam_member.gateway_vertex,
    google_redis_instance.cache,
    google_secret_manager_secret_version.third_party_keys_initial,
  ]
}

# ----------------------------------------------------------------------------
# Authentication: zero-code OIDC validation at the edge
# ----------------------------------------------------------------------------
# Consumer SA — callers impersonate this to mint short-lived OIDC ID tokens.
# No JSON key files are ever downloaded. Identity is a platform concern.
resource "google_service_account" "gateway_consumer" {
  account_id   = "gateway-consumer"
  display_name = "Gateway API Consumer"
  description  = "Identity granted roles/run.invoker on the gateway. Callers impersonate this SA to obtain OIDC tokens scoped to the custom audience."
}

# Grant run.invoker on each Cloud Run service to the consumer SA only.
# allUsers is intentionally NOT granted — unauthenticated requests are
# rejected at Google's edge (LB + Cloud Run frontend) before reaching the container.
resource "google_cloud_run_v2_service_iam_member" "consumer_invoke" {
  for_each = google_cloud_run_v2_service.gateway
  name     = each.value.name
  location = each.value.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.gateway_consumer.email}"
}

# Allow the human operator to impersonate the consumer SA to mint identity tokens.
# In production this would be replaced/augmented with CI service accounts.
resource "google_service_account_iam_member" "consumer_token_creator" {
  service_account_id = google_service_account.gateway_consumer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:okolotowicz.robert@gmail.com"
}