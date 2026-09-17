# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration; see backend.hcl.example.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # How long a dry pool is waited on, in effect.
  #
  # InsufficientInstanceCapacity is documented as an EC2 *server* error, so
  # the AWS SDK treats it like any 500 and retries it inside RunInstances --
  # the provider's own retry around that call covers only IAM propagation.
  # With the default of 25 attempts and a 300 second backoff cap, an apply
  # into a dry pool blocks for the better part of an hour before returning.
  #
  # That is the right behaviour when there is one pool and nothing better to
  # do: it costs nothing, creates nothing, and returns the moment capacity
  # appears. Waits of 15, 42 and about 12 minutes were measured that way on
  # 2026-08-27, and all three were eventually filled.
  #
  # It is the wrong behaviour when five other pools are waiting to be tried.
  # The same evening ended with a switch to m7a in the same zone being filled
  # instantly, after hours spent on c7a. scripts/launch_with_ladder.sh lowers
  # this so a rung fails fast and the ladder walks, then cycles -- sampling
  # every pool ten times beats sitting on the first one.
  max_retries = var.aws_max_retries

  default_tags {
    tags = var.default_tags
  }
}
