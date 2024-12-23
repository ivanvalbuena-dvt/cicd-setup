variable "project_id" {
  type        = string
  description = "id of the GCP project e.g. for EMEA SDDS value is \"emea-datafoundat-gbl-emea-dv\""
}
variable "project_name" {
  type        = string
  description = "Name of the project, gcp recources will be tagged with this value e.g. \"kepler\" created raw dataset will be \"d_kepler_raw_eu\" "
}
variable "dataset_raw" {
  type        = string
  description = "Target dataset to locate the table to ingest the raw data"
}
variable "schema_name" {
  type        = string
  description = "Name given to the resource for a particular provider NB: this value should be aligned with the json schema name file"
}
variable "schema_version" {
  type        = string
  description = "version number of the schema e.g.  \"v1\""
}
variable "schema_definition" {
  type        = string
  description = "Path to the json file where the schema is defined"
}
variable "subscription_service_account" {
  type        = string
  description = "Email of the event dispatcher Service account"
}
variable "event_dispatcher_url" {
  type        = string
  description = "Dispatcher Gcloud run service url"
}
variable "appengine_region" {
  type        = string
  description = "Region of the appengine"
}
variable "reload_schedule_times" {
  type        = string
  description = "String with the cron job configuration to schedule the reloads"
}

locals {
  raw_table_id                    = "t_raw_${var.schema_name}_${var.schema_version}"
  reload_scheduler_name           = "${var.project_name}-reload-${var.schema_name}-${var.schema_version}"
  reload_events_topic_name        = "${var.project_name}-reload-events-${var.schema_name}-${var.schema_version}"
  reload_events_subscription_name = "${var.project_name}-reload-events-${var.schema_name}-${var.schema_version}-dispatch"
  table_ingestion_queue_name      = "${var.project_name}-table-ingestion-queue-${var.schema_name}-${var.schema_version}"
}

output "raw_table" {
  value = "${var.project_id}.${var.dataset_raw}.${google_bigquery_table.raw_table.table_id}"
}

# BIG QUERY

resource "google_bigquery_table" "raw_table" {
  deletion_protection = true
  dataset_id          = var.dataset_raw
  table_id            = local.raw_table_id
  friendly_name       = local.raw_table_id
  description         = "RAW table for ${var.schema_name} (${var.schema_version})"
  schema              = var.schema_definition
}

# SCHEDULER

resource "google_cloud_scheduler_job" "reload_scheduler" {
  region      = var.appengine_region
  name        = local.reload_scheduler_name
  description = "Triggers full reload of ${local.raw_table_id}"
  schedule    = var.reload_schedule_times
  time_zone   = "Europe/Paris"

  pubsub_target {
    topic_name = google_pubsub_topic.reload_events.id
    attributes = {
      provider = "${var.schema_name}_${var.schema_version}"
    }
  }
}

# PUB/SUB

resource "google_pubsub_topic" "reload_events" {
  name = local.reload_events_topic_name
}

resource "google_pubsub_subscription" "reload_events_dispatcher" {
  name                 = local.reload_events_subscription_name
  topic                = google_pubsub_topic.reload_events.name
  ack_deadline_seconds = 20
  push_config {
    push_endpoint = var.event_dispatcher_url
    oidc_token {
      service_account_email = var.subscription_service_account
    }
  }
  expiration_policy {
    ttl = ""
  }
}

# CLOUD TASKS

resource "google_cloud_tasks_queue" "ingestion_queue" {
  name     = local.table_ingestion_queue_name
  location = var.appengine_region
  rate_limits {
    max_dispatches_per_second = 0.01
    max_concurrent_dispatches = 1
  }
  retry_config {
    max_attempts  = 1
    min_backoff   = "2s"
    max_doublings = 16
  }
  stackdriver_logging_config {
    sampling_ratio = 1.0
  }

  lifecycle {
    prevent_destroy = true
  }
}
