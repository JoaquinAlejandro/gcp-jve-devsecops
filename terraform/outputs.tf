output "service_url" {
  description = "URL pública del servicio desplegado"
  value       = google_cloud_run_v2_service.app.uri
}

output "artifact_registry_repo" {
  description = "Ruta del repositorio de imágenes Docker"
  value       = google_artifact_registry_repository.repo.name
}