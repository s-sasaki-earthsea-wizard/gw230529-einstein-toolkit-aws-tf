# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
# Terraform targets
# =======================================================
# Three stacks with different lifetimes:
#
#   bootstrap   the state bucket. Applied once, then left alone.
#   foundation  VPC, data bucket, ECR, IAM, budgets. Months. Idle cost ~0.
#   compute     the spot instance. Created for a run, destroyed after.
#
# Ordinary flow:  make setup -> check-permissions -> bootstrap -> foundation
#                 -> push-image -> upload-inputs -> run -> ssm -> stop

# Load .env when present (AWS_PROFILE, AWS_REGION, scout settings).
ifneq (,$(wildcard .env))
include .env
export
endif

TF := terraform
LOCAL_IMAGE ?= gw230529-et:local
IMAGE_TAG ?= latest

# Where the Einstein Toolkit gallery artefacts live locally. They are fetched,
# not redistributed, so the simulation repository keeps them in a gitignored
# upstream/ directory.
INPUTS_DIR ?= ../gw230529-einstein-toolkit/upstream

# Share one copy of the provider plugins across all three stacks. The AWS
# provider is ~840 MB; without this, each stack keeps its own copy under
# .terraform/ and the checkout grows to 2.5 GB.
export TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache

##@ Setup

.PHONY: setup
setup: ## Create .env, backend.hcl and terraform.tfvars from the templates
	@test -f .env || (cp .env.example .env && echo "created .env")
	@for s in bootstrap foundation compute; do \
		if [ -f stacks/$$s/terraform.tfvars.example ]; then \
			test -f stacks/$$s/terraform.tfvars || \
				(cp stacks/$$s/terraform.tfvars.example stacks/$$s/terraform.tfvars && \
				 echo "created stacks/$$s/terraform.tfvars"); \
		fi; \
		if [ -f stacks/$$s/backend.hcl.example ]; then \
			test -f stacks/$$s/backend.hcl || \
				(cp stacks/$$s/backend.hcl.example stacks/$$s/backend.hcl && \
				 echo "created stacks/$$s/backend.hcl"); \
		fi; \
	done
	@echo ""
	@echo "Now edit the CHANGEME values. None of these files are tracked by git."

.PHONY: region-scout
region-scout: ## Compare candidate regions on spot score, price and quota
	@scripts/region_scout.sh

.PHONY: check-permissions
check-permissions: ## Simulate every IAM action against a live principal (PRINCIPAL=<arn>)
	@scripts/check_permissions.sh $(PRINCIPAL)

.PHONY: check-permissions-policy
check-permissions-policy: ## Simulate the same actions against policies/terraform-operator.json
	@scripts/check_permissions.sh --policy policies/terraform-operator.json

##@ Quality

.PHONY: fmt
fmt: ## Rewrite all Terraform files in canonical format
	@$(TF) fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not canonically formatted
	@$(TF) fmt -recursive -check -diff .

.PHONY: validate
validate: ## Validate every stack without contacting a backend
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@for s in bootstrap foundation compute; do \
		echo "--- validating stacks/$$s ---"; \
		$(TF) -chdir=stacks/$$s init -backend=false -input=false >/dev/null || exit 1; \
		$(TF) -chdir=stacks/$$s validate || exit 1; \
	done

.PHONY: check-secrets
check-secrets: ## Fail if a tracked file contains an account id, ARN or access key
	@scripts/check_secrets.sh

.PHONY: check
check: fmt-check validate check-secrets ## Run every pre-commit check

##@ Stacks

.PHONY: init-%
init-%: ## Initialise a stack, e.g. make init-foundation
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@if [ "$*" = "bootstrap" ]; then \
		$(TF) -chdir=stacks/$* init -input=false; \
	else \
		test -f stacks/$*/backend.hcl || \
			{ echo "stacks/$*/backend.hcl is missing -- run make setup"; exit 1; }; \
		$(TF) -chdir=stacks/$* init -input=false -backend-config=backend.hcl; \
	fi

.PHONY: plan-%
plan-%: ## Show the plan for a stack, e.g. make plan-foundation
	@$(TF) -chdir=stacks/$* plan -input=false

.PHONY: apply-%
apply-%: ## Apply a stack, e.g. make apply-foundation
	@$(TF) -chdir=stacks/$* apply -input=false

.PHONY: destroy-%
destroy-%: ## Destroy a stack, e.g. make destroy-compute
	@$(TF) -chdir=stacks/$* destroy -input=false

.PHONY: output-%
output-%: ## Show a stack's outputs, e.g. make output-foundation
	@$(TF) -chdir=stacks/$* output

##@ Image and inputs

.PHONY: upload-inputs
upload-inputs: ## Upload the parfile and FUKA initial data to the data bucket
	@test -d "$(INPUTS_DIR)" || \
		{ echo "INPUTS_DIR=$(INPUTS_DIR) not found -- fetch the gallery artefacts first"; exit 1; }
	@bucket=$$($(TF) -chdir=stacks/foundation output -raw data_bucket) && \
	echo "Uploading four gallery artefacts (~1.6 MB) to s3://$$bucket/inputs/" && \
	echo "These are upstream Einstein Toolkit files: not committed, not in the image." && \
	aws s3 cp "$(INPUTS_DIR)/bhns_gw230529.par" "s3://$$bucket/inputs/" && \
	aws s3 cp "$(INPUTS_DIR)/bhns_gw230529_ID/" "s3://$$bucket/inputs/" \
		--recursive --exclude '*' \
		--include '*.info' --include '*.dat' --include 'gam2.polytrope' && \
	echo "" && \
	echo "Check the parfile carries the spot settings before a production run:" && \
	echo "  IO::checkpoint_ID                   = \"yes\"" && \
	echo "  IO::checkpoint_every_walltime_hours = 1.0" && \
	echo "  IO::checkpoint_keep                 = 2" && \
	echo "  IO::recover                         = \"autoprobe\""

.PHONY: push-image
push-image: ## Push the locally built Einstein Toolkit image to ECR
	@repo=$$($(TF) -chdir=stacks/foundation output -raw ecr_repository_url) && \
	region=$$($(TF) -chdir=stacks/foundation output -raw aws_region) && \
	aws ecr get-login-password --region $$region \
		| docker login --username AWS --password-stdin $$repo && \
	docker tag $(LOCAL_IMAGE) $$repo:$(IMAGE_TAG) && \
	docker push $$repo:$(IMAGE_TAG) && \
	echo "" && \
	echo "Pushed. Pin production runs to the digest above rather than the tag."

##@ Run control

.PHONY: run
run: ## Launch the spot instance and start a run
	@echo "This starts billing. The node self-terminates when the run ends."
	@$(TF) -chdir=stacks/compute apply -input=false -var run_enabled=true

.PHONY: stop
stop: ## Terminate the spot instance, keeping the launch template
	@$(TF) -chdir=stacks/compute apply -input=false -var run_enabled=false

.PHONY: status
status: ## Show the current run's instance id and S3 prefix
	@$(TF) -chdir=stacks/compute output

.PHONY: ssm
ssm: ## Open a shell on the running node through SSM Session Manager
	@cmd=$$($(TF) -chdir=stacks/compute output -raw ssm_session_command 2>/dev/null) && \
	if [ -z "$$cmd" ] || [ "$$cmd" = "null" ]; then \
		echo "no instance is running -- make run first"; exit 1; \
	fi && \
	echo "$$cmd" && exec $$cmd

.PHONY: heartbeat
heartbeat: ## Print the latest heartbeat object written by the node
	@bucket=$$($(TF) -chdir=stacks/foundation output -raw data_bucket) && \
	run=$$($(TF) -chdir=stacks/compute output -raw run_prefix) && \
	aws s3 cp $${run}heartbeat/latest.json - 2>/dev/null || \
		echo "no heartbeat yet in $$bucket"
