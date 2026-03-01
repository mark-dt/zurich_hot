
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }
}

# --------- Random passwords (one per instance) ----------
resource "random_password" "vm_password" {
  count            = var.instance_count
  length           = 20
  #special          = true
  special          = false
  override_special = "!@#%^*-_=+"
}

# --------- Compute instances (count) ----------
resource "google_compute_instance" "vm" {
  count        = var.instance_count
  name         = "simple-vm-${count.index + 1}"
  # machine_type = "e2-micro" # small and cost-friendly
  machine_type = "e2-standard-8" # small and cost-friendly
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 40
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP
  }

  # Explicitly disable OS Login and project-wide SSH keys
  metadata = {
    block-project-ssh-keys  = "true"
    enable-guest-attributes = "false"
    enable-oslogin          = "FALSE"
    startup-script = templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
      base = templatefile("${path.module}/scripts/parts/10-base.sh.tpl", {
        username                 = "user${count.index + 1}"
        password                 = random_password.vm_password[count.index].result
        dynatrace_operator_token = var.dynatrace_operator_token
        dynatrace_data_token     = var.dynatrace_data_ingest_token
      })

      easytrade = file("${path.module}/scripts/parts/30-easytrade.sh")
      easytrade_ingress = file("${path.module}/scripts/parts/40-easytrade-ingress.sh")

    })
  }

  /*
  metadata_startup_script = <<-EOT
  

  EOT
  */

  tags = ["ssh"]
}

resource "google_compute_firewall" "allow_k8s_api" {
  name        = "allow-k8s-api"
  network     = "default"
  direction   = "INGRESS"
  target_tags = ["ssh"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  # For workshops you can keep this open;
  # ideally restrict to your IP later
  source_ranges = ["0.0.0.0/0"]
}

# --------- Firewall: allow SSH to instances with tag "ssh" ----------
resource "google_compute_firewall" "allow_ssh_to_tag" {
  name        = "allow-ssh-to-tag"
  network     = "default"
  direction   = "INGRESS"
  target_tags = ["ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # For quick testing; consider restricting to your IP later
  source_ranges = ["0.0.0.0/0"]
}

# --------- Credentials file (CSV) ----------
# username,password,public_ip,ssh_command
locals {
  vm_public_ips = [
    for i in range(var.instance_count) :
    google_compute_instance.vm[i].network_interface[0].access_config[0].nat_ip
  ]

  credentials_lines = [
    for i in range(var.instance_count) :
    format("user%d,%s,%s,ssh user%d@%s",
      i + 1,
      random_password.vm_password[i].result,
      local.vm_public_ips[i],
      i + 1,
      local.vm_public_ips[i]
    )
  ]

  credentials_csv = join("\n", concat(
    ["username,password,public_ip,ssh_command"],
    local.credentials_lines
  ))
}

resource "local_file" "ssh_credentials" {
  filename = "ssh_credentials.csv"
  content  = local.credentials_csv
  # Note: this file contains sensitive data (passwords). Handle with care.
}
