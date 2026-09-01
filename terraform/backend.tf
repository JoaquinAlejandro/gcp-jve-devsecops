terraform {
  backend "gcs" {
    bucket = "tfstate-jve-demo-gcp"
    prefix = "terraform/state"
  }
}