# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Summoning a spot interruption, for issue #24.
#
# WHY THIS EXISTS
#
# The interruption handler in templates/user_data.sh.tftpl has fired for real
# a dozen times, so the common case is proven. What is not proven is any case
# we cannot choose the moment of: a notice arriving while a sync tick holds
# the lock, or while a checkpoint set is still being written. Both are
# reasoned about in comments and neither has been observed, because until now
# the only way to see one was to be lucky while AWS reclaimed a node.
#
# aws:ec2:send-spot-instance-interruptions delivers a real notice on demand.
# The node reads the same IMDS response it reads in production, so what is
# under test is the handler rather than a mock of it. Immediately on start the
# target gets a rebalance recommendation; durationBeforeInterruption later the
# interruption notice arrives; two minutes after that the instance is gone.
#
# WHERE THE BOUNDARY IS
#
# Not on the fis: actions, which cannot be scoped -- a FIS ARN carries a
# generated id and no project name, the same shape as EC2. The boundary is
# this role. An experiment does only what the role it names can do, and
# creating a template requires iam:PassRole on that role, which the operator
# policy allows only for role/gw230529-*. This one may send a spot
# interruption to an instance tagged Project=gw230529 and nothing else -- the
# same event spot sends those instances anyway, several times a night.
#
# WHY IT IS KEPT RATHER THAN CREATED FOR AN EXPERIMENT
#
# A role and a template cost nothing to hold, and `make stop` does not touch
# them, so an experiment can be fired at a node that is already running. The
# flag defaults to false: production runs should not carry a way to interrupt
# themselves, and turning it on is a deliberate edit to terraform.tfvars.

data "aws_caller_identity" "current" {}

locals {
  fis_count = var.fis_enabled ? 1 : 0
}

# Who may act as the experiment role.
#
# aws:SourceAccount pins the confused deputy shut: without it, a template in
# another account naming this role by ARN would be able to use it, because the
# service principal alone says only "some FIS experiment somewhere".
data "aws_iam_policy_document" "fis_assume_role" {
  statement {
    sid     = "FisServiceWithSourceAccount"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# What the experiment may do.
#
# One action, fenced by the tag the provider stamps on everything this project
# creates -- the same fence the operator policy uses for destructive EC2, and
# verified there to return explicitDeny for an untagged or foreign instance.
# DescribeInstances is required by the action and has no resource-level
# permissions, so it is the usual `*`.
data "aws_iam_policy_document" "fis_spot_interrupt" {
  statement {
    sid       = "InterruptProjectSpotInstances"
    effect    = "Allow"
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.default_tags["Project"]]
    }
  }

  statement {
    sid       = "DescribeInstancesHasNoResourceScope"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "fis" {
  count = local.fis_count

  name               = "${local.foundation.name_prefix}-fis-spot-interrupt"
  description        = "Role AWS FIS assumes to send a spot interruption notice to a GW230529 node."
  assume_role_policy = data.aws_iam_policy_document.fis_assume_role.json
}

resource "aws_iam_role_policy" "fis" {
  count = local.fis_count

  name   = "${local.foundation.name_prefix}-fis-spot-interrupt"
  role   = aws_iam_role.fis[0].id
  policy = data.aws_iam_policy_document.fis_spot_interrupt.json
}

# The experiment.
#
# selection_mode is ALL rather than the tutorial's COUNT(1). This project runs
# one node at a time, so the two are the same set -- but COUNT(1) means "pick
# one at random from whatever matches", and if a second node ever exists the
# experiment would silently interrupt a coin flip instead of failing. ALL says
# what is meant. The State.Name filter keeps a terminating node from counting
# as a target.
#
# durationBeforeInterruption is the minimum the API accepts. The two minutes
# between notice and termination are fixed by EC2 and are the window under
# test; this parameter only adds a delay before the notice, which would make
# the moment harder to aim at, not easier.
#
# No stop condition. A CloudWatch alarm halting the experiment would halt the
# very thing being measured, and the experiment is over in two minutes.
resource "aws_fis_experiment_template" "spot_interruption" {
  count = local.fis_count

  description = "Interrupt the GW230529 spot node on demand (issue #24)"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-the-run-node"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "the-run-node"
    }
  }

  target {
    name           = "the-run-node"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "Project"
      value = var.default_tags["Project"]
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = {
    Name = "${local.foundation.name_prefix}-spot-interruption"
  }
}
