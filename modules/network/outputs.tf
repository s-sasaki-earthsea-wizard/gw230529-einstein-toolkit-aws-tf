# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet ids, one per availability zone."
  value       = [for s in aws_subnet.public : s.id]
}

output "public_subnet_ids_by_az" {
  description = "Public subnet ids keyed by availability zone name."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "security_group_id" {
  description = "Security group for the compute node."
  value       = aws_security_group.node.id
}
