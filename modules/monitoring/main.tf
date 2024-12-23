variable "environment" { type = string }
variable "channels_mails" { type = map(string) }
variable "project_name" { type = string }

terraform {
  required_version = ">= 1.7.4, < 2.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.5.0, <5.0.0"
    }
  }
}

resource "google_monitoring_notification_channel" "notification_emails" {
  for_each = var.channels_mails

  display_name = upper(each.key)
  type         = "email"
  labels = {
    email_address = each.value
  }
}

resource "google_monitoring_alert_policy" "ingestion_error" {
  display_name          = "${var.project_name} | Metric | Storage | Clone to Errors Bucket Requests Count"
  enabled               = var.environment == "pd" ? true : false # TODO enable only for relevant channel (i.e. business, etc)
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.notification_emails["dev_team"].id, google_monitoring_notification_channel.notification_emails["run_team"].id, google_monitoring_notification_channel.notification_emails["users"].id]
  conditions {
    display_name = "GCS Bucket - Clone to Errors API Request Count"
    condition_threshold {
      filter          = "metric.type=\"storage.googleapis.com/api/request_count\" resource.type=\"gcs_bucket\" metric.label.method=\"CloneObject.To\" resource.label.\"bucket_name\"=monitoring.regex.full_match(\".*(${var.project_name}).*(error).*\")"
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        per_series_aligner   = "ALIGN_MAX"
        alignment_period     = "60s"
        group_by_fields      = ["resource.bucket_name"]
        cross_series_reducer = "REDUCE_MAX"
      }
    }
  }
}

#Metric | Cloud Workflows | Failed workflow
resource "google_monitoring_alert_policy" "cloud_workflows_failed" {
  display_name          = "${var.project_name} | Metric | Cloud Workflows | Failed workflow"
  enabled               = var.environment == "pd" ? true : false
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.notification_emails["dev_team"].id, google_monitoring_notification_channel.notification_emails["run_team"].id, google_monitoring_notification_channel.notification_emails["users"].id]
  conditions {
    display_name = "Cloud Workflows - Execution Failure"
    condition_threshold {
      filter          = "metric.type=\"workflows.googleapis.com/finished_execution_count\" resource.type=\"workflows.googleapis.com/Workflow\" metric.labels.status=FAILED resource.label.\"workflow_id\"=monitoring.regex.full_match(\".*(${var.project_name}).*\")"
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        per_series_aligner   = "ALIGN_SUM"
        alignment_period     = "60s"
        group_by_fields      = ["resource.workflow_id"]
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
}
