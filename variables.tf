variable "project_id" {
  description = "GCP project ID hosting the GenAI gateway"
  type        = string
}

variable "project_number" {
  description = "GCP project number (required for VPC-SC perimeter membership)"
  type        = string
}

variable "primary_region" {
  description = "Primary region for Cloud Run + Memorystore"
  type        = string
  default     = "us-east1"
}

variable "secondary_region" {
  description = "Failover region for Cloud Run + Memorystore"
  type        = string
  default     = "europe-west1"
}

variable "dns_zone_name" {
  description = "Existing Cloud DNS managed zone name (without trailing dot)"
  type        = string
}

variable "dns_record_name" {
  description = "Fully-qualified hostname for the gateway, with trailing dot"
  type        = string
  # example: "ai.example.com."
}

variable "container_image" {
  description = "Fully-qualified Artifact Registry image for the gateway container"
  type        = string
  # example: "us-east1-docker.pkg.dev/PROJECT/gateway/proxy:v1"
}

variable "redis_tier" {
  description = "Memorystore tier — BASIC for dev, STANDARD_HA for prod"
  type        = string
  default     = "BASIC"
  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.redis_tier)
    error_message = "redis_tier must be BASIC or STANDARD_HA."
  }
}

variable "redis_size_gb" {
  description = "Memorystore Redis cache size in GB"
  type        = number
  default     = 5
}

variable "rate_limit_rpm" {
  description = "Cloud Armor per-IP rate-limit threshold (requests per 60s)"
  type        = number
  default     = 100
}

variable "vpc_sc_access_policy_id" {
  description = "Access Context Manager access policy ID for the org. Leave empty to skip VPC-SC."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default = {
    workload    = "genai-gateway"
    environment = "dev"
    managed_by  = "infra-manager"
  }
}
variable "gateway_hostname" {
  description = "Public DNS hostname for the gateway (also used as Cloud Run custom audience)"
  type        = string
  default     = "ai.poweraim.net"
}


