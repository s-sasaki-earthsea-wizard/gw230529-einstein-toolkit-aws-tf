# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "launch_template_id" {
  description = "Launch template id."
  value       = module.spot_node.launch_template_id
}

output "instance_id" {
  description = "Instance id while a run is active, null otherwise."
  value       = module.spot_node.instance_id
}

output "ssm_session_command" {
  description = "Ready-to-paste command that opens a shell on the node."
  value       = module.spot_node.ssm_session_command
}

output "run_prefix" {
  description = "S3 prefix this run writes to."
  value       = "s3://${local.foundation.data_bucket}/${var.run_name}/"
}
