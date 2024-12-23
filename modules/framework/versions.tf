terraform {
  required_version = ">= 1.7.4, <2.0.0"
  required_providers {
    google = {
      version = ">= 4.5.0, <5.0.0"
    }
    restapi = {
      source  = "mastercard/restapi"
      version = "1.16.1"
    }
    random = {
      version = "= 3.5.1"
    }
  }
}
