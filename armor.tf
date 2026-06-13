resource "google_compute_security_policy" "armor" {
  name        = "genai-gateway-armor"
  description = "WAF + rate limit for the GenAI gateway"

  # Rule 1000: per-IP rate limit — defends against LLM-cost depletion attacks
  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.rate_limit_rpm
        interval_sec = 60
      }
      ban_duration_sec = 600
    }
    description = "Per-IP: ${var.rate_limit_rpm} req/60s, 10min ban on exceed"
  }

  # Rule 2000: OWASP preconfigured — argument injection
  rule {
    action   = "deny(403)"
    priority = 2000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rce-v33-stable')"
      }
    }
    description = "Block remote code execution / argument injection (OWASP CRS)"
  }

  # Rule 2100: OWASP preconfigured — SQLi
  rule {
    action   = "deny(403)"
    priority = 2100
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection (OWASP CRS)"
  }

  # Rule 2200: OWASP preconfigured — XSS
  rule {
    action   = "deny(403)"
    priority = 2200
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block XSS (OWASP CRS)"
  }

  # Default allow
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }
}
