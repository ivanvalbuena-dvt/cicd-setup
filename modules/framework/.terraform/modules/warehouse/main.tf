variable "project_id" { type = string }
variable "project_name" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "module_name" {
  type    = string
  default = "warehouse"
}
variable "schema_version" { type = string }
variable "schema_definition" { type = string }
variable "warehouse_dataset" { type = string }
variable "staging_dataset" { type = string }
variable "subscription_service_account" { type = string }
variable "ingestion_api_service_account" { type = string }
variable "workflow_service_account" { type = string }
variable "event_dispatcher_url" { type = string }
variable "appengine_region" { type = string }
variable "access_policies" { type = map(any) }
variable "warehouse_name" { type = string }
variable "short_name" {
  type    = string
  default = ""
}

variable "transaction_query" {
  type = string
}
variable "reload_workflow_path" {
  type        = string
  default     = "reload-warehouse.yaml"
  description = "Can be customised but starts with path.module/ => be carefull this means you start from environments/env/.terraform/modules/project_name.file_provider location"
}
variable "reload_warehouse_procedure" {
  type        = string
  default     = "p_warehouse_reload.sql"
  description = "SQL transaction that will launch all the delete + load queries to reload the warehouses"
}
variable "partitioning_config" {
  type    = any
  default = null
}
variable "clustering" {
  type    = any
  default = null
}
variable "successful_reload_events_topics_admin" {
  type    = string
  default = ""
}


locals {
  short_name                          = length(var.short_name) == 0 ? var.warehouse_name : var.short_name
  warehouse_table_id                  = "t_${var.warehouse_name}_${var.schema_version}"
  warehouse_table_description         = "EMEA ${var.project_name} ${local.short_name} data (${var.schema_version})"
  reload_workflow_name                = "${var.project_name}-reload-${join("-", regexall("[a-zA-Z0-9]+", local.short_name))}-${var.module_name}-${var.schema_version}-full"
  reload_workflow_description         = "Reload the ${local.warehouse_table_id} table"
  reload_events_topic_name            = "${var.project_name}-reload-events-${var.module_name}-${join("-", regexall("[a-zA-Z0-9]+", local.short_name))}-${var.schema_version}"
  reload_events_subscription_name     = "${var.project_name}-reload-events-${var.module_name}-${join("-", regexall("[a-zA-Z0-9]+", local.short_name))}-${var.schema_version}-dispatch"
  reload_queue_name                   = "${var.project_name}-${var.module_name}-reload-queue-${join("-", regexall("[a-zA-Z0-9]+", local.short_name))}-${var.schema_version}"
  successful_reload_events_topic_name = "${var.project_name}-successful-reload-events-${var.module_name}-${join("-", regexall("[a-zA-Z0-9]+", local.short_name))}-${var.schema_version}"
  successful_reload_events_message    = "{'reloaded_table' : ${local.warehouse_table_id}, 'project_id' : ${var.project_id}}"
  default_rls_query                   = "SELECT 'NO RLS POLICIES HAVE BEEN DEFINED' AS RLS_VALUE"
  rls_query                           = length(var.access_policies) == 0 ? local.default_rls_query : join("; ", [for key, value in var.access_policies : contains(keys(value.filter), var.warehouse_name) ? "CREATE OR REPLACE ROW ACCESS POLICY ${key}_filter ON ${var.warehouse_dataset}.${local.warehouse_table_id} GRANT TO (${join(", ", [for grantee in value.grantees : " '${grantee}' "])}) FILTER USING (${value.filter["${var.warehouse_name}"]})" : "SELECT 'NO RLS POLICIES FOR UPPER(${var.warehouse_name})' AS RLS_VALUE"])
  reload_workflow_path                = "${path.module}/${var.reload_workflow_path}"
  reload_procedure_path               = "${path.module}/${var.reload_warehouse_procedure}"
}

resource "google_bigquery_table" "warehouse_table" {
  deletion_protection = false
  dataset_id          = var.warehouse_dataset
  table_id            = local.warehouse_table_id
  friendly_name       = local.warehouse_table_id
  description         = local.warehouse_table_description
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

# WAREHOUSE RELOAD PROCEDURE
resource "google_bigquery_routine" "warehouse_reload_procedure" {
  dataset_id   = var.warehouse_dataset
  routine_id   = "p_warehouse_reload_${join("_", regexall("[a-zA-Z0-9]+", local.short_name))}_${var.schema_version}"
  routine_type = "PROCEDURE"
  language     = "SQL"
  definition_body = templatefile(
    local.reload_procedure_path,
    {
      transactionQuery = var.transaction_query
  })
}

# PUB/SUB

resource "google_pubsub_topic" "reload_events" {
  name = local.reload_events_topic_name
}

resource "google_pubsub_topic_iam_member" "ingestion_api_pubsub_publisher" {
  project = google_pubsub_topic.reload_events.project
  topic   = google_pubsub_topic.reload_events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.ingestion_api_service_account}"
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

# successful reload event

resource "google_pubsub_topic" "successful_reload_events" {
  name = local.successful_reload_events_topic_name
}

resource "google_pubsub_topic_iam_member" "successful_reload_pubsub_publisher" {
  project = google_pubsub_topic.successful_reload_events.project
  topic   = google_pubsub_topic.successful_reload_events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.workflow_service_account}"
}

resource "google_pubsub_topic_iam_binding" "successful_reload_pubsub_admin" {
  project = google_pubsub_topic.successful_reload_events.project
  topic   = google_pubsub_topic.successful_reload_events.name
  role    = "roles/pubsub.admin"
  members = var.successful_reload_events_topics_admin != "" ? ["serviceAccount:${var.successful_reload_events_topics_admin}"] : []
}


# CLOUD TASKS

resource "google_cloud_tasks_queue" "reload_queue" {
  name     = local.reload_queue_name
  location = var.appengine_region
  rate_limits {
    max_dispatches_per_second = 0.002
    max_concurrent_dispatches = 1
  }
  retry_config {
    max_attempts  = 5
    min_backoff   = "2s"
    max_doublings = 16
  }
  stackdriver_logging_config {
    sampling_ratio = 1
  }

  lifecycle {
    prevent_destroy = true
  }
}

# WAREHOUSE RELOAD WORKFLOW
resource "google_workflows_workflow" "reload_warehouse" {
  name        = local.reload_workflow_name
  region      = "europe-west4"
  description = local.reload_workflow_description
  source_contents = templatefile(
    local.reload_workflow_path,
    {
      reloadScript                        = "CALL `${var.project_id}.${var.warehouse_dataset}.${google_bigquery_routine.warehouse_reload_procedure.routine_id}`();"
      successful_reload_events_topic_name = local.successful_reload_events_topic_name
      successful_reload_events_message    = local.successful_reload_events_message
    }
  )
  service_account = var.workflow_service_account
}

# ROW ACCESS POLICIES
resource "google_bigquery_job" "row_access_policy" {
  job_id   = "row_access_${local.warehouse_table_id}_${google_bigquery_table.warehouse_table.creation_time}_${md5(local.rls_query)}"
  location = var.location
  depends_on = [
    google_bigquery_table.warehouse_table
  ]
  query {
    query              = local.rls_query
    create_disposition = ""
    write_disposition  = ""
  }

  lifecycle {
    ignore_changes = [query]
  }

}
