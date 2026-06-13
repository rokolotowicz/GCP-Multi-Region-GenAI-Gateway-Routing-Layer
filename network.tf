# ----------------------------------------------------------------------------
# VPC + regional subnets
# ----------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "genai-gateway-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnets" {
  for_each = {
    (var.primary_region)   = "10.10.0.0/24"
    (var.secondary_region) = "10.20.0.0/24"
  }
  name                     = "gw-subnet-${each.key}"
  ip_cidr_range            = each.value
  region                   = each.key
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Reserved range for Service Networking (Memorystore private services access)
resource "google_compute_global_address" "psa_range" {
  name          = "psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}

# ----------------------------------------------------------------------------
# Private Service Connect endpoint for Vertex AI (per region)
# Routes all aiplatform.googleapis.com calls over Google's private backbone.
# ----------------------------------------------------------------------------
resource "google_compute_global_address" "psc_vertex" {
  name         = "psc-vertex-endpoint-ip"
  address_type = "INTERNAL"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = google_compute_network.vpc.id
  address      = "10.100.0.5"
}

resource "google_compute_global_forwarding_rule" "psc_vertex" {
  name                  = "pscvertex"
  target                = "all-apis"
  network               = google_compute_network.vpc.id
  ip_address            = google_compute_global_address.psc_vertex.id
  load_balancing_scheme = ""
}

# ----------------------------------------------------------------------------
# Firewall: deny-all egress baseline, then allow only what's needed
# ----------------------------------------------------------------------------
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc.id
  direction = "INGRESS"
  source_ranges = ["10.10.0.0/24", "10.20.0.0/24"]
  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "allow_google_apis" {
  name      = "allow-google-private-apis"
  network   = google_compute_network.vpc.id
  direction = "EGRESS"
  destination_ranges = ["199.36.153.8/30"] # private.googleapis.com
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}
