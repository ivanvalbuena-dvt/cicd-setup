variable "project_id" { type = string }
variable "project_name" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "dataset_raw" { type = string }
variable "schema_name" { type = string }
variable "schema_version" { type = string }
variable "schema_definition" { type = string }
variable "table_id" { type = string }
variable "authorized_file_providers" { type = list(string) }
variable "ingestion_types" { type = list(string) }
variable "subscription_service_account" { type = string }
variable "ingestion_api_service_account" { type = string }
variable "event_dispatcher_url" { type = string }
variable "ingestion_api_url" { type = string }
variable "audit_topic_id" { type = string }
variable "appengine_region" { type = string }
variable "nearline_age_cond" { type = number }
variable "coldline_age_cond" { type = number }
variable "archive_age_cond" { type = number }
variable "force_destroy" {
  type    = string
  default = false
}
variable "partitioning_config" {
  type    = any
  default = null
}
variable "clustering" {
  type    = any
  default = null
}
variable "deletion_protection" {
  type    = string
  default = true
}
variable "table_prefix" {
  type    = string
  default = "raw"
}

locals {
  ingestion_types_authorized_file_providers_combinations = [
    for pair in setproduct(var.ingestion_types, var.authorized_file_providers) : {
      ingestion_type    = pair[0]
      authorized_member = pair[1]
    }
  ]
  landing_bucket_name              = "${var.project_id}-${var.project_name}-${var.schema_name}-${var.schema_version}-landing"
  errors_bucket_name               = "${var.project_id}-${var.project_name}-${var.schema_name}-${var.schema_version}-errors"
  archive_bucket_name              = "${var.project_id}-${var.project_name}-${var.schema_name}-${var.schema_version}-archive"
  landing_events_topic_name        = "${var.project_name}-landing-events-${var.schema_name}-${var.schema_version}"
  landing_events_subscription_name = "${var.project_name}-landing-events-${var.schema_name}-${var.schema_version}-dispatch"
  ingestion_queue_name             = "${var.project_name}-file-ingestion-queue-${join("-", regexall("[a-zA-Z0-9]+", var.schema_name))}-${var.schema_version}"
  raw_table_id                     = "t_${var.table_prefix}_${var.table_id}_${var.schema_version}"
}

# STORAGE

resource "google_storage_bucket" "landing" {
  #checkov:skip=CKV_GCP_62:
  for_each                    = toset(var.ingestion_types)
  name                        = format("%s%s", local.landing_bucket_name, each.value == "full" ? "" : "-${each.value}")
  location                    = var.location
  force_destroy               = false
  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "errors" {
  #checkov:skip=CKV_GCP_62:
  for_each                    = toset(var.ingestion_types)
  name                        = format("%s%s", local.errors_bucket_name, each.value == "full" ? "" : "-${each.value}")
  location                    = var.location
  force_destroy               = false
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition {
      age = var.nearline_age_cond
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition {
      age = var.coldline_age_cond
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  lifecycle_rule {
    condition {
      age = var.archive_age_cond
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }
}

resource "google_storage_bucket" "archive" {
  #checkov:skip=CKV_GCP_62:
  for_each                    = toset(var.ingestion_types)
  name                        = format("%s%s", local.archive_bucket_name, each.value == "full" ? "" : "-${each.value}")
  location                    = var.location
  force_destroy               = var.force_destroy
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition {
      age = var.nearline_age_cond
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition {
      age = var.coldline_age_cond
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  lifecycle_rule {
    condition {
      age = var.archive_age_cond
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }
}

# PUB/SUB

resource "google_pubsub_topic" "landing_events" {
  for_each = toset(var.ingestion_types)
  name     = format("%s%s", local.landing_events_topic_name, each.value == "full" ? "" : "-${each.value}")
}

data "google_storage_project_service_account" "default_service_account" {}

resource "google_pubsub_topic_iam_binding" "gcs_pubsub_publisher" {
  for_each = toset(var.ingestion_types)
  topic    = google_pubsub_topic.landing_events[each.value].id
  role     = "roles/pubsub.publisher"
  members  = ["serviceAccount:${data.google_storage_project_service_account.default_service_account.email_address}"]
}

resource "google_storage_notification" "landing_object_finalize" {
  for_each       = toset(var.ingestion_types)
  bucket         = google_storage_bucket.landing[each.key].name
  topic          = google_pubsub_topic.landing_events[each.key].id
  payload_format = "JSON_API_V1"
  event_types    = ["OBJECT_FINALIZE"]
  depends_on     = [google_pubsub_topic_iam_binding.gcs_pubsub_publisher]
}

resource "google_pubsub_subscription" "landing_events_dispatcher" {
  for_each             = toset(var.ingestion_types)
  name                 = format("%s%s", local.landing_events_subscription_name, each.value == "full" ? "" : "-${each.value}")
  topic                = google_pubsub_topic.landing_events[each.key].name
  ack_deadline_seconds = 60
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
  name     = local.ingestion_queue_name
  location = var.appengine_region
  rate_limits {
    max_dispatches_per_second = 0.2
    max_concurrent_dispatches = 1
  }
  retry_config {
    max_attempts  = 10
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

# BIG QUERY

resource "google_bigquery_table" "raw_table" {
  deletion_protection = var.deletion_protection
  dataset_id          = var.dataset_raw
  table_id            = local.raw_table_id
  friendly_name       = local.raw_table_id
  description         = "RAW table for ${var.schema_name} (${var.schema_version})"
  schema              = var.schema_definition
  dynamic "time_partitioning" {
    for_each = try(var.partitioning_config.partitioning_type == "time_partitioning", false) ? ["time_partitioning"] : []
    content {
      type                     = var.partitioning_config.time_partitionning_type
      field                    = var.partitioning_config.field
      require_partition_filter = var.partitioning_config.require
    }
  }
  /*
  dynamic "range_partitioning" {
    for_each = var.partitioning_config.partitioning_type == "time_partitioning" ? ["time_partitioning"] : []
    content {
      field = var.partitioning_config.field
      range = {
        start    = var.partitioning_config.range.interval
        end      = var.partitioning_config.range.interval
        interval = var.partitioning_config.range.interval
      }
    }
  }
  */
  clustering = try(var.clustering, null)
}

# IAM

resource "google_storage_bucket_iam_member" "ingestion_api_storage_admin_landing" {
  for_each = toset(var.ingestion_types)
  bucket   = google_storage_bucket.landing[each.key].name
  role     = "roles/storage.admin"
  member   = "serviceAccount:${var.ingestion_api_service_account}"
}

resource "google_storage_bucket_iam_member" "ingestion_api_storage_admin_errors" {
  for_each = toset(var.ingestion_types)
  bucket   = google_storage_bucket.errors[each.key].name
  role     = "roles/storage.admin"
  member   = "serviceAccount:${var.ingestion_api_service_account}"
}

resource "google_storage_bucket_iam_member" "ingestion_api_storage_admin_archive" {
  for_each = toset(var.ingestion_types)
  bucket   = google_storage_bucket.archive[each.key].name
  role     = "roles/storage.admin"
  member   = "serviceAccount:${var.ingestion_api_service_account}"
}

#tfsec:ignore:google-iam-no-user-granted-permissions
resource "google_storage_bucket_iam_member" "members_landing_admin" {
  for_each = {
    for combination in local.ingestion_types_authorized_file_providers_combinations :
    "${combination.ingestion_type}-${combination.authorized_member}" => combination
    # we do not grant general access to the taint landing bucket
    if combination.ingestion_type != "taint"
  }

  bucket = google_storage_bucket.landing[each.value.ingestion_type].name
  role   = "roles/storage.admin"
  member = each.value.authorized_member
}

#tfsec:ignore:google-iam-no-user-granted-permissions
resource "google_storage_bucket_iam_member" "members_errors" {
  for_each = {
    for combination in local.ingestion_types_authorized_file_providers_combinations : "${combination.ingestion_type}-${combination.authorized_member}" => combination
  }
  bucket = google_storage_bucket.errors[each.value.ingestion_type].name
  role   = "roles/storage.objectViewer"
  member = each.value.authorized_member
}

#tfsec:ignore:google-iam-no-user-granted-permissions
resource "google_storage_bucket_iam_member" "members_archive" {
  for_each = {
    for combination in local.ingestion_types_authorized_file_providers_combinations : "${combination.ingestion_type}-${combination.authorized_member}" => combination
  }
  bucket = google_storage_bucket.archive[each.value.ingestion_type].name
  role   = "roles/storage.objectViewer"
  member = each.value.authorized_member
}
