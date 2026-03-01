# --------- Outputs ----------
output "public_ips" {
  value       = [for i in range(var.instance_count) : google_compute_instance.vm[i].network_interface[0].access_config[0].nat_ip]
  description = "Public IPs of the VMs in order."
}

output "ssh_commands" {
  value       = [for i in range(var.instance_count) : "ssh user${i + 1}@${google_compute_instance.vm[i].network_interface[0].access_config[0].nat_ip}"]
  description = "SSH commands for each instance."
}

output "credentials_file" {
  value       = abspath(local_file.ssh_credentials.filename)
  description = "Path to the generated CSV file containing usernames, passwords, IPs, and SSH commands."
}

# Optional: suppress password in outputs (we only write to file)
# If you also want passwords in outputs, uncomment below (not recommended).
# output "passwords" {
#   value       = [for i in range(var.instance_count) : random_password.vm_password[i].result]
#   description = "Generated passwords in order (user1..userN)."
#   sensitive   = true
# }