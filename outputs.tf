output "gateway_ip" {
  description = "Global anycast IP of the load balancer"
  value       = google_compute_global_address.gateway.address
}

output "gateway_hostname" {
  description = "Public hostname served by the gateway"
  value       = trimsuffix(var.dns_record_name, ".")
}

output "cloud_run_services" {
  description = "Cloud Run service URLs per region (internal, not directly reachable)"
  value       = { for k, v in google_cloud_run_v2_service.gateway : k => v.uri }
}

output "redis_endpoints" {
  description = "Redis host:port per region"
  value       = { for k, v in google_redis_instance.cache : k => "${v.host}:${v.port}" }
  sensitive   = true
}

output "service_account" {
  description = "Cloud Run runtime SA email"
  value       = google_service_account.gateway.email
}
