variable "project_id" { type = string }
variable "env" { type = string }
variable "usecase" { type = string }
variable "repo_name" { type = string }
variable "orga_name" { type = string }
variable "apis_to_activate" { type = list(any) }
variable "region" { type = string }

terraform {
  required_version = ">= 1.7.4, < 2.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.5.0, <5.0.0"
    }
  }
}

locals {
  env_branch = {
    "dv" = "develop"
    "qa" = "develop"
    "np" = "integration"
    "pd" = "main"
  }
}

resource "google_project_service" "apis" {
  for_each                   = toset(var.apis_to_activate)
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
}

resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = "${var.usecase}-sa-cloudbuild-${var.env}"
  description  = "Custom Cloud Build service account in ${var.usecase}"
  display_name = "Cloud Build custom service account"
}

# TODO: Uncomment if you need to create a secret in Secret Manager
# resource "google_secret_manager_secret" "secret-basic" {
#   secret_id = "terraform-cloud-credentials"
#   replication {
#     user_managed {
#       replicas {
#         location = "europe-west1"
#       }
#       replicas {
#         location = "europe-west2"
#       }
#     }
#   }
# }

# Trigger to plan changes when a PR is opened against integration or main
resource "google_cloudbuild_trigger" "tf-plan" {
  github {
    owner = var.orga_name
    name  = var.repo_name
    pull_request {
      branch = "^(${local.env_branch[var.env]})$"
    }
  }

  substitutions = {
    _APPLY_CHANGES = "false"
    _ENV           = var.env
    _USECASE       = var.usecase
  }
  name            = "emea-dtf-${var.usecase}-tf-plan" #TODO: Change name if it is not deployed in DTF
  description     = "Triggers a plan when a Pull Request targeting ${local.env_branch[var.env]} branch is open"
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.deploy.id
  depends_on      = [google_project_service.apis, google_service_account.deploy]
  location        = var.region
}

# Trigger to apply changes when a PR is merged into develop (dv or qa) or integration (np)
resource "google_cloudbuild_trigger" "tf-apply" {
  count = var.env != "pd" ? 1 : 0

  github {
    owner = var.orga_name
    name  = var.repo_name
    push {
      branch = "^${local.env_branch[var.env]}$"
    }
  }

  substitutions = {
    _APPLY_CHANGES = "true"
    _ENV           = var.env
    _USECASE       = var.usecase
  }
  name            = "emea-dtf-${var.usecase}-tf-apply" #TODO: Change name if it is not deployed in DTF
  description     = "Triggers non-production deployments when a Pull Request targeting ${local.env_branch[var.env]} is merged"
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.deploy.id
  depends_on      = [google_project_service.apis, google_service_account.deploy, google_cloudbuild_trigger.tf-plan]
  location        = var.region
}

# Trigger to apply changes when a tag is created (pd)
resource "google_cloudbuild_trigger" "tf-apply-release" {
  count = var.env == "pd" ? 1 : 0

  github {
    owner = var.orga_name
    name  = var.repo_name
    push {
      tag = "^v[0-9]+.[0-9]+.[0-9]+$"
    }
  }

  substitutions = {
    _APPLY_CHANGES = "true"
    _ENV           = var.env
    _USECASE       = var.usecase
  }
  name            = "emea-dtf-${var.usecase}-tf-apply-release" #TODO: Change name if it is not deployed in DTF
  description     = "Triggers production deployment when a tag is created in the repository"
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.deploy.id
  depends_on      = [google_project_service.apis, google_service_account.deploy, google_cloudbuild_trigger.tf-plan]
  location        = var.region
}

# Trigger to run pre-commits when a PR is opened against develop (dv and qa), integration (np) or main (pd) branches
resource "google_cloudbuild_trigger" "test-precommit" {
  github {
    owner = var.orga_name
    name  = var.repo_name
    pull_request {
      branch = "^(${local.env_branch[var.env]})$"
    }
  }

  substitutions = {
    _APPLY_CHANGES = "true"
    _ENV           = var.env
    _USECASE       = var.usecase
  }
  name            = "emea-dtf-${var.usecase}-test-precommit"
  description     = "Triggers pre-commit tests when a Pull Request targeting ${local.env_branch[var.env]} branch is open"
  filename        = "cloudbuild-precommit.yaml"
  service_account = google_service_account.deploy.id
  location        = var.region
}
