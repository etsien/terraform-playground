# main

# Configure the Google Cloud provider
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Enable required GCP APIs
resource "google_project_service" "gcp_services" {
  for_each = toset([
    "container.googleapis.com",    # Kubernetes Engine API
    "containerregistry.googleapis.com", # Container Registry API
    "compute.googleapis.com",      # Compute Engine API
    "monitoring.googleapis.com",   # Cloud Monitoring API
    "logging.googleapis.com",      # Cloud Logging API
    "cloudtrace.googleapis.com",   # Cloud Trace API
    "cloudbuild.googleapis.com",   # Cloud Build API
    "sqladmin.googleapis.com",     # Cloud SQL Admin API
    "secretmanager.googleapis.com" # Secret Manager API
  ])
  project = var.project_id
  service = each.key

  disable_on_destroy = false
}

# Create VPC network for GKE cluster
resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.gcp_services]
}

# Create subnet for GKE cluster
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.prefix}-subnet"
  ip_cidr_range = "10.0.0.0/18"
  region        = var.region
  network       = google_compute_network.vpc.id
  
  secondary_ip_range {
    range_name    = "pod-range"
    ip_cidr_range = "10.48.0.0/14"
  }
  
  secondary_ip_range {
    range_name    = "service-range"
    ip_cidr_range = "10.52.0.0/20"
  }
}

# Create a GKE cluster for microservices
resource "google_container_cluster" "primary" {
  name     = "${var.prefix}-gke-cluster"
  location = var.zone
  
  # We can't create a cluster with no node pool defined, so we create the smallest possible default node pool
  # and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
  
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id
  
  ip_allocation_policy {
    cluster_secondary_range_name  = "pod-range"
    services_secondary_range_name = "service-range"
  }
  
  # Enable workload identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

# Create CPU node pool for API and database workloads
resource "google_container_node_pool" "general_purpose" {
  name       = "${var.prefix}-general-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = var.general_node_count
  
  node_config {
    preemptible  = var.use_preemptible
    machine_type = var.general_machine_type
    disk_size_gb = 100
    
    # Set service account and OAuth scopes
    service_account = google_service_account.gke_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    
    # Enable workload identity on node pool
    workload_identity_config {
      workload_metadata_config {
        mode = "GKE_METADATA"
      }
    }
    
    # Apply labels and taints
    labels = {
      component = "general"
    }
  }
}

# Create GPU node pool for LLM inference workloads
resource "google_container_node_pool" "gpu" {
  name       = "${var.prefix}-gpu-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = var.gpu_node_count
  
  node_config {
    preemptible  = var.use_preemptible
    machine_type = var.gpu_machine_type
    disk_size_gb = 200
    
    # Configure GPU
    guest_accelerator {
      type  = var.gpu_type
      count = var.gpu_count_per_node
    }
    
    # Set service account and OAuth scopes
    service_account = google_service_account.gke_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    
    # Enable workload identity on node pool
    workload_identity_config {
      workload_metadata_config {
        mode = "GKE_METADATA"
      }
    }
    
    # Apply labels and taints for GPU-only workloads
    labels = {
      component = "gpu"
    }
    
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
  }
}

# Create a service account for GKE nodes
resource "google_service_account" "gke_sa" {
  account_id   = "${var.prefix}-gke-sa"
  display_name = "GKE Service Account"
  depends_on   = [google_project_service.gcp_services]
}

# Grant required roles to the GKE service account
resource "google_project_iam_member" "gke_sa_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/storage.objectViewer",
    "roles/artifactregistry.reader"
  ])
  
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# Create Cloud SQL PostgreSQL instance for user data and conversation history
resource "google_sql_database_instance" "llm_db" {
  name             = "${var.prefix}-db-instance"
  database_version = "POSTGRES_14"
  region           = var.region
  
  settings {
    tier      = "db-g1-small"
    disk_size = 20
    
    backup_configuration {
      enabled = true
    }
    
    ip_configuration {
      ipv4_enabled    = true
      private_network = google_compute_network.vpc.id
    }
  }
  
  depends_on = [google_project_service.gcp_services]
  deletion_protection = false
}

# Create database for the application
resource "google_sql_database" "database" {
  name     = "${var.prefix}_db"
  instance = google_sql_database_instance.llm_db.name
}

# Create PostgreSQL user with a generated password
resource "google_sql_user" "db_user" {
  name     = "${var.prefix}_user"
  instance = google_sql_database_instance.llm_db.name
  password = var.db_password
}

# Create a Secret Manager secret for the database password
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.prefix}-db-password"
  
  replication {
    automatic = true
  }
  
  depends_on = [google_project_service.gcp_services]
}

# Store the database password in the secret
resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

# Create service account for accessing the database
resource "google_service_account" "db_sa" {
  account_id   = "${var.prefix}-db-sa"
  display_name = "Database Service Account"
  depends_on   = [google_project_service.gcp_services]
}

# Grant the database service account access to the secret
resource "google_secret_manager_secret_iam_member" "db_sa_access" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.db_sa.email}"
}

# Create a Cloud Storage bucket for model storage
resource "google_storage_bucket" "model_storage" {
  name     = "${var.project_id}-llm-models"
  location = var.region
  uniform_bucket_level_access = true
}

# Kubernetes resources using kubectl provider
provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

# Helm provider for installing charts
provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

# Get GCP project configuration
data "google_client_config" "default" {}

# Create namespaces
resource "kubernetes_namespace" "llm_api" {
  metadata {
    name = "llm-api"
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# Install NGINX Ingress Controller
resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "kube-system"
  
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

# Install Prometheus and Grafana for monitoring
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
}

# Create Kubernetes secret for database credentials
resource "kubernetes_secret" "db_credentials" {
  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  data = {
    username = google_sql_user.db_user.name
    password = var.db_password
    database = google_sql_database.database.name
    host     = google_sql_database_instance.llm_db.private_ip_address
  }
}

# Kubernetes ConfigMap for API configuration
resource "kubernetes_config_map" "api_config" {
  metadata {
    name      = "api-config"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  data = {
    "config.json" = jsonencode({
      model_name     = "llama-3-3-7b"
      max_token_limit = 4096
      temperature    = 0.7
      streaming      = true
    })
  }
}

# Kubernetes Deployment for the LLM inference service
resource "kubernetes_deployment" "llm_inference" {
  metadata {
    name      = "llm-inference"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
    labels = {
      app = "llm-inference"
    }
  }
  
  spec {
    replicas = 1
    
    selector {
      match_labels = {
        app = "llm-inference"
      }
    }
    
    template {
      metadata {
        labels = {
          app = "llm-inference"
        }
      }
      
      spec {
        node_selector = {
          component = "gpu"
        }
        
        # Toleration for GPU nodes
        toleration {
          key    = "nvidia.com/gpu"
          value  = "present"
          effect = "NO_SCHEDULE"
        }
        
        container {
          name  = "llm-inference"
          image = "${var.container_registry}/llm-inference:latest"
          
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
              memory           = "24Gi"
              cpu              = "4"
            }
            requests = {
              memory = "16Gi"
              cpu    = "2"
            }
          }
          
          port {
            container_port = 8000
          }
          
          env {
            name  = "MODEL_PATH"
            value = "/models/llama-3-3-7b"
          }
          
          env {
            name = "LOG_LEVEL"
            value = "INFO"
          }
          
          volume_mount {
            name       = "model-storage"
            mount_path = "/models"
          }
          
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 60
            period_seconds        = 10
          }
        }
        
        # Volume for models
        volume {
          name = "model-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.model_storage.metadata[0].name
          }
        }
      }
    }
  }
}

# Kubernetes PersistentVolume for model storage
resource "kubernetes_persistent_volume" "model_storage" {
  metadata {
    name = "model-storage"
  }
  
  spec {
    capacity = {
      storage = "50Gi"
    }
    access_modes = ["ReadOnlyMany"]
    persistent_volume_source {
      gce_persistent_disk {
        pd_name = google_compute_disk.model_disk.name
      }
    }
  }
}

# Create a Compute Engine disk for model storage
resource "google_compute_disk" "model_disk" {
  name  = "${var.prefix}-model-disk"
  type  = "pd-standard"
  zone  = var.zone
  size  = 50
}

# Kubernetes PersistentVolumeClaim for model storage
resource "kubernetes_persistent_volume_claim" "model_storage" {
  metadata {
    name      = "model-storage"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  spec {
    access_modes = ["ReadOnlyMany"]
    resources {
      requests = {
        storage = "50Gi"
      }
    }
    volume_name = kubernetes_persistent_volume.model_storage.metadata[0].name
  }
}

# Kubernetes Service for the LLM inference service
resource "kubernetes_service" "llm_inference" {
  metadata {
    name      = "llm-inference"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  spec {
    selector = {
      app = "llm-inference"
    }
    
    port {
      port        = 80
      target_port = 8000
    }
  }
}

# Kubernetes Deployment for the API service
resource "kubernetes_deployment" "api_service" {
  metadata {
    name      = "api-service"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
    labels = {
      app = "api-service"
    }
  }
  
  spec {
    replicas = 2
    
    selector {
      match_labels = {
        app = "api-service"
      }
    }
    
    template {
      metadata {
        labels = {
          app = "api-service"
        }
      }
      
      spec {
        container {
          name  = "api-service"
          image = "${var.container_registry}/api-service:latest"
          
          resources {
            limits = {
              memory = "1Gi"
              cpu    = "1"
            }
            requests = {
              memory = "512Mi"
              cpu    = "0.5"
            }
          }
          
          port {
            container_port = 8080
          }
          
          env {
            name  = "LLM_SERVICE_URL"
            value = "http://llm-inference"
          }
          
          env {
            name = "DB_HOST"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "host"
              }
            }
          }
          
          env {
            name = "DB_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "username"
              }
            }
          }
          
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "password"
              }
            }
          }
          
          env {
            name = "DB_NAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "database"
              }
            }
          }
          
          volume_mount {
            name       = "api-config"
            mount_path = "/app/config"
          }
          
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 20
            period_seconds        = 10
          }
        }
        
        # Volume for API configuration
        volume {
          name = "api-config"
          config_map {
            name = kubernetes_config_map.api_config.metadata[0].name
          }
        }
      }
    }
  }
}

# Kubernetes Service for the API service
resource "kubernetes_service" "api_service" {
  metadata {
    name      = "api-service"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  spec {
    selector = {
      app = "api-service"
    }
    
    port {
      port        = 80
      target_port = 8080
    }
  }
}

# Kubernetes Deployment for the frontend
resource "kubernetes_deployment" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
    labels = {
      app = "frontend"
    }
  }
  
  spec {
    replicas = 2
    
    selector {
      match_labels = {
        app = "frontend"
      }
    }
    
    template {
      metadata {
        labels = {
          app = "frontend"
        }
      }
      
      spec {
        container {
          name  = "frontend"
          image = "${var.container_registry}/frontend:latest"
          
          resources {
            limits = {
              memory = "512Mi"
              cpu    = "0.5"
            }
            requests = {
              memory = "256Mi"
              cpu    = "0.2"
            }
          }
          
          port {
            container_port = 80
          }
          
          env {
            name  = "API_BASE_URL"
            value = "/api"
          }
          
          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }
}

# Kubernetes Service for the frontend
resource "kubernetes_service" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  spec {
    selector = {
      app = "frontend"
    }
    
    port {
      port        = 80
      target_port = 80
    }
  }
}

# Kubernetes Ingress for the entire application
resource "kubernetes_ingress_v1" "llm_app" {
  metadata {
    name      = "llm-app-ingress"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "8m"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
    }
  }
  
  spec {
    rule {
      http {
        path {
          path = "/api"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.api_service.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
        
        path {
          path = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.frontend.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# Create a Kubernetes job to download and install the LLM model
resource "kubernetes_job" "model_download" {
  metadata {
    name      = "model-download"
    namespace = kubernetes_namespace.llm_api.metadata[0].name
  }
  
  spec {
    template {
      metadata {
        labels = {
          job = "model-download"
        }
      }
      
      spec {
        container {
          name    = "model-download"
          image   = "google/cloud-sdk:slim"
          command = ["/bin/sh", "-c"]
          args    = [
            <<-EOT
            # Download the model files from GCS
            mkdir -p /models/llama-3-3-7b
            gsutil -m cp gs://${var.model_bucket_name}/llama-3-3-7b/* /models/llama-3-3-7b/
            # Set appropriate permissions
            chmod -R 755 /models
            EOT
          ]
          
          volume_mount {
            name       = "model-storage"
            mount_path = "/models"
          }
        }
        
        # Volume for models
        volume {
          name = "model-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.model_storage.metadata[0].name
          }
        }
        
        restart_policy = "Never"
      }
    }
    
    backoff_limit = 2
  }
}

# Output the external IP address for accessing the application
output "app_url" {
  value = "http://${kubernetes_ingress_v1.llm_app.status.0.load_balancer.0.ingress.0.ip}"
}

# Output connection information for the database
output "db_connection_info" {
  value = "Instance: ${google_sql_database_instance.llm_db.name}, Database: ${google_sql_database.database.name}, User: ${google_sql_user.db_user.name}"
  sensitive = true
}