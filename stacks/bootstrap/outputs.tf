# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "state_bucket" {
  description = "State bucket name. Copy it into each stack's backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "backend_hcl" {
  description = "Ready-to-paste partial backend configuration for the other stacks."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "<stack>/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
