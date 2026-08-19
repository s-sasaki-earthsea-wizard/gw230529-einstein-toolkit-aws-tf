# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "repository_name" {
  description = "ECR repository name holding the Einstein Toolkit image."
  type        = string
  default     = "gw230529/einstein-toolkit"
}

variable "keep_last_images" {
  description = <<-EOT
    Number of images retained by the lifecycle policy. The image is 5-8 GB,
    so each extra generation costs roughly 0.5-0.8 USD/month.
  EOT
  type        = number
  default     = 3
}

variable "force_delete" {
  description = "Allow `terraform destroy` to delete a repository that still holds images."
  type        = bool
  default     = false
}
