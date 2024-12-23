
# DATASETS
resource "google_bigquery_dataset" "common_datasets" {
  location      = "europe-west1"
  dataset_id    = "d_cicd_setup"
  friendly_name = "cicd_setup"
}
