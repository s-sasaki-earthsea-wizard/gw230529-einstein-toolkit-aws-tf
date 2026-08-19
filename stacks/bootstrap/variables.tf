# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "aws_region" {
  description = "Region holding the state bucket. Use the same region as the foundation stack."
  type        = string
}

variable "state_bucket_name" {
  description = <<-EOT
    Globally unique name for the Terraform state bucket. Set it in
    terraform.tfvars, which is gitignored, so it stays out of the public
    repository.
  EOT
  type        = string
}

variable "default_tags" {
  description = "Tags applied to every resource."
  type        = map(string)

  default = {
    Project   = "gw230529"
    ManagedBy = "terraform"
  }
}
