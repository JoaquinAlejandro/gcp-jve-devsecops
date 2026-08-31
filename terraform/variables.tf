variable "project_id" {
  description = "ID del proyecto en GCP"
  type        = string
}

variable "region" {
  description = "Región donde se despliega la infraestructura"
  type        = string
  default     = "us-central1"
}

variable "service_name" {
  description = "Nombre del servicio en Cloud Run"
  type        = string
  default     = "demo-api-jve-tf"
}