terraform {
  required_version = ">= 1.7.4, < 2.0.0"
  backend "gcs" {
    bucket = "ivan-valbuena-sandbox-01-cicd-gcs-tfstate" #TODO: Change to your bucket name
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.5.0, <5.0.0"
    }
    restapi = {
      source  = "mastercard/restapi"
      version = "1.16.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }
  }
}

provider "google" {
  project = local.project_id
}

locals {
  project_id       = "ivan-valbuena-sandbox-01" #TODO: Change to your project name
  env              = "dv"
  location         = "EU"
  region           = "europe-west1"
  appengine_region = "europe-west2"
  repo_name        = "cicd-setup" #TODO: Change to your repo name
  orga_name        = "ivanvalbuena-dvt"
  usecase          = "cicd" #TODO: Change to your use case name

}

module "init" {
  source           = "../../modules/init"
  project_id       = local.project_id
  env              = local.env
  usecase          = local.usecase
  apis_to_activate = []
  orga_name        = local.orga_name
  repo_name        = local.repo_name
  region           = local.region
}

/* TODO: Uncomment this module after the project initialization
module "framework" {
  source           = "../../modules/framework"
  config_path      = "./../../config"
  project_id       = local.project_id
  env              = local.env
  usecase          = local.usecase
  default_location = local.location
  default_region   = local.region
  appengine_region = local.appengine_region
}
*/
