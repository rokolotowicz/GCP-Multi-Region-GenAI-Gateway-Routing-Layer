# Map each region to its in-region CMEK key.
locals {
  redis_cmek_keys = {
    (var.primary_region)   = google_kms_crypto_key.redis.id
    (var.secondary_region) = google_kms_crypto_key.redis_secondary.id
  }
}


# Per-region Redis for semantic caching of prompt embeddings.
resource "google_redis_instance" "cache" {
  for_each = toset(local.regions)

  name           = "genai-cache-${each.key}"
  tier           = var.redis_tier        # BASIC (dev) or STANDARD_HA (prod)
  memory_size_gb = var.redis_size_gb
  region         = each.key

  authorized_network      = google_compute_network.vpc.id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  auth_enabled            = true

  redis_version = "REDIS_7_2"

  # CMEK for cache at rest
  customer_managed_key = local.redis_cmek_keys[each.key]

  labels = var.labels

  depends_on = [
    google_service_networking_connection.psa,
    google_kms_crypto_key_iam_member.redis_cmek,
    google_kms_crypto_key_iam_member.redis_cmek_secondary,
  ]
}
