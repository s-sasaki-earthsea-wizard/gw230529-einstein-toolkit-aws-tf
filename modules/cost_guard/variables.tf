# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "alert_email" {
  description = <<-EOT
    Address that receives budget and anomaly alerts. AWS sends a confirmation
    mail after the first apply; the subscription stays PendingConfirmation
    until the link in it is clicked.
  EOT
  type        = string
}

variable "budget_limit_usd" {
  description = "Total project spend cap in USD. Used as the budget amount and the forecast threshold."
  type        = number
  default     = 300
}

variable "budget_thresholds_usd" {
  description = <<-EOT
    Absolute USD thresholds that trigger an alert, in ascending order. AWS
    allows at most five notifications per budget, so the list is split across
    as many budgets as needed.
  EOT
  type        = list(number)
  default     = [50, 100, 150, 200, 250, 300]
}

variable "budget_period_start" {
  description = "Start of the budget period, formatted YYYY-MM-DD_HH:MM."
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}_\\d{2}:\\d{2}$", var.budget_period_start))
    error_message = "budget_period_start must look like 2026-08-01_00:00."
  }
}

variable "cost_allocation_tag" {
  description = <<-EOT
    Optional cost allocation tag filter, as { key = "Project", value = "gw230529" }.

    Leave this null. A tag filter only matches once the tag has been activated
    in the Billing console AND enough time has passed for it to appear in the
    cost data -- until then the budget silently matches nothing and no alert
    ever fires. An account-wide budget is the safe default; narrow it later
    only if this account starts carrying unrelated spend.
  EOT
  type = object({
    key   = string
    value = string
  })
  default = null
}

variable "anomaly_impact_threshold_usd" {
  description = "Minimum absolute anomaly impact in USD before a notification is sent."
  type        = number
  default     = 10
}
