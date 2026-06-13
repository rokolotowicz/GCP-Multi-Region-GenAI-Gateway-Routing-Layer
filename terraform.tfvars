project_id       = "vertexai-436401"
project_number   = "361143538229"
primary_region   = "us-east1"
secondary_region = "europe-west1"

dns_zone_name   = ""
dns_record_name = "ai.poweraim.net."

# Build & push your gateway container first (Go/Python proxy), then:
container_image = "us-east1-docker.pkg.dev/vertexai-436401/gateway/proxy:v1"

redis_tier    = "BASIC"      # flip to STANDARD_HA for production
redis_size_gb = 5
rate_limit_rpm = 100

# Optional — leave empty to skip VPC-SC.
# Get the ID with:  gcloud access-context-manager policies list --organization ORG_ID
vpc_sc_access_policy_id = ""

labels = {
  workload    = "genai-gateway"
  environment = "dev"
  managed_by  = "infra-manager"
}
