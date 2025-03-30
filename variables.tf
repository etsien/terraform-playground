# variables

variable "project_id" {
  description = "The GCP project ID to deploy resources"
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy resources"
  type        = string
  default     = "us-central1-a"
}

variable "prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "llama-app"
}

variable "container_registry" {
  description = "Container registry URL for Docker images"
  type        = string
}

variable "model_bucket_name" {
  description = "GCS bucket name where the Llama 3.3 7B model is stored"
  type        = string
}

variable "db_password" {
  description = "Password for the database user"
  type        = string
  sensitive   = true
}

variable "use_preemptible" {
  description = "Use preemptible VMs for cost savings (not recommended for production)"
  type        = bool
  default     = false
}

variable "general_node_count" {
  description = "Number of general-purpose nodes for API and databases"
  type        = number
  default     = 2
}

variable "general_machine_type" {
  description = "Machine type for general-purpose nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "gpu_node_count" {
  description = "Number of GPU nodes for LLM inference"
  type        = number
  default     = 1
}

variable "gpu_machine_type" {
  description = "Machine type for GPU nodes"
  type        = string
  default     = "n1-standard-8"
}

variable "gpu_type" {
  description = "Type of GPU to use for LLM inference"
  type        = string
  default     = "nvidia-tesla-t4"
}

variable "gpu_count_per_node" {
  description = "Number of GPUs per node"
  type        = number
  default     = 1
}