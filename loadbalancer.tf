# ----------------------------------------------------------------------------
# Serverless NEGs pointing at each Cloud Run service
# ----------------------------------------------------------------------------
resource "google_compute_region_network_endpoint_group" "neg" {
  for_each              = google_cloud_run_v2_service.gateway
  name                  = "cloud-run-${each.key}-neg"
  region                = each.key
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = each.value.name
  }
}

# ----------------------------------------------------------------------------
# Backend service — multi-region with Armor attached, CDN off (POST traffic)
# ----------------------------------------------------------------------------
resource "google_compute_backend_service" "gateway" {
  name                  = "genai-gateway-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  enable_cdn            = false
  security_policy       = google_compute_security_policy.armor.id

  dynamic "backend" {
    for_each = google_compute_region_network_endpoint_group.neg
    content {
      group = backend.value.id
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# ----------------------------------------------------------------------------
# URL map → all paths to the gateway backend
# ----------------------------------------------------------------------------
resource "google_compute_url_map" "gateway" {
  name            = "genai-gateway-urlmap"
  default_service = google_compute_backend_service.gateway.id
}

# ----------------------------------------------------------------------------
# Google-managed SSL cert (modern profile)
# ----------------------------------------------------------------------------
resource "google_compute_managed_ssl_certificate" "gateway" {
  provider = google-beta
  name     = "genai-gateway-cert"
  managed {
    domains = [trimsuffix(var.dns_record_name, ".")]
  }
}

resource "google_compute_ssl_policy" "modern" {
  name            = "genai-gateway-ssl-modern"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "gateway" {
  name             = "genai-gateway-https-proxy"
  url_map          = google_compute_url_map.gateway.id
  ssl_certificates = [google_compute_managed_ssl_certificate.gateway.id]
  ssl_policy       = google_compute_ssl_policy.modern.id
}

# ----------------------------------------------------------------------------
# Global anycast IP + forwarding rule on :443
# ----------------------------------------------------------------------------
resource "google_compute_global_address" "gateway" {
  name         = "genai-gateway-ip"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "genai-gateway-fr-https"
  target                = google_compute_target_https_proxy.gateway.id
  port_range            = "443"
  ip_address            = google_compute_global_address.gateway.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
