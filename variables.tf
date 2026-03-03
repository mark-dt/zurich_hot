# --------- Config ----------
variable "project_id" {
  type    = string
  default = "acetaskforceemea"
}
variable "region" {
  type    = string
  default = "europe-west1"
}
variable "zone" {
  type    = string
  default = "europe-west1-b"
}

# How many instances to create
variable "instance_count" {
  type    = number
  default = 1
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

variable "dynatrace_installer_url" {
  type      = string
  sensitive = true
  description = "Dynatrace OneAgent installer URL"
}

variable "dynatrace_api_token" {
  type      = string
  sensitive = true
  description = "Dynatrace API token"
}

variable "dynatrace_arguments" {
  type        = string
  default     = ""
  description = "Additional OneAgent installer arguments"
}

variable "dynatrace_operator_token" {
  type        = string
  sensitive   = true
  description = "Dynatrace API token for the operator (apiToken)"
}

variable "dynatrace_data_ingest_token" {
  type        = string
  sensitive   = true
  description = "Dynatrace data ingest token (dataIngestToken)"
}

variable "edgeconnect_oauth_client_id" {
  type        = string
  sensitive   = true
  description = "OAuth client ID for EdgeConnect"
}

variable "edgeconnect_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "OAuth client secret for EdgeConnect"
}

variable "edgeconnect_oauth_endpoint" {
  type        = string
  description = "OAuth token endpoint for EdgeConnect (e.g. https://{env}.apps.dynatrace.com/sso/oauth2/token)"
}

variable "edgeconnect_oauth_resource" {
  type        = string
  description = "OAuth resource URN for EdgeConnect (e.g. urn:dtaccount:{account-uuid})"
}