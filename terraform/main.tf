# Habilitar las APIs necesarias (Se activaron a mano, pero así queda en el código también)
resource "google_project_service" "run_api" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifact_registry_api" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# Artifact Registry: Para guardar las imagenes docker en el GCP
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "api-repo-jve"
  format        = "DOCKER"

  cleanup-policy_dry_run = false

  cleanup_policies {
    id = "conservar-ultimas-versiones"
    action = "KEEP"
    most_recent_version {
      keep_count = 5
    }
  }

  cleanup_policies {
    id = "borrar-antiguas"
    action = "DELETE"
    condition{
      older_than = "2592000s"
    }
  }

  depends_on = [google_project_service.artifact_registry_api]
}

# Cloud Run: El servicio para manipular los contenedores
resource "google_cloud_run_v2_service" "app" {
  name     = var.service_name
  location = var.region

  template {
    containers {
      image = "us-central1-docker.pkg.dev/${var.project_id}/api-repo-jve/demo-api:v1"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
  }

  depends_on = [google_project_service.run_api]
}

# Permitir acceso público (le damos acceso publico ya que el proyecto es chiquitito)
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  location = google_cloud_run_v2_service.app.location
  name     = google_cloud_run_v2_service.app.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}