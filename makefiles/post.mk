# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
# Post-processing targets
# =======================================================
# Figures and the movie for the finished run, produced locally from a synced
# copy of the S3 output. Everything here is read-only towards AWS, so the
# observer profile is enough for the one target that talks to it at all:
#
#   make fetch-results AWS_PROFILE=gw230529-observer
#   make postproc-image
#   make figures
#   make movie
#   make ledger-chart AWS_PROFILE=gw230529-observer
#   make pack-results        # when the figures are done and approved
#
# Local rather than cloud on purpose. The whole run wrote ~10 GB and the
# figures read ~300 MB of it; that is a download, not a reason to ship a
# rendering environment into Lambda or EC2. The analysis runs inside a
# pinned Docker image so the figures reproduce months later; the scripts are
# bind mounted, so editing one never requires an image rebuild.

POSTPROC_IMAGE ?= gw230529-postproc:local
RESULTS_ROOT := results

# The run to process: the sole directory under results/, override with
# RUN_NAME=... when more than one run has been fetched.
RUN_NAME ?= $(notdir $(patsubst %/,%,$(firstword $(wildcard $(RESULTS_ROOT)/*/))))

# Which unit systems the figures are drawn in, space separated. Geometric is
# what Cactus stores and what the Einstein Toolkit gallery prints; SI is what
# the OpenCAE audience reads, and the abstract already quotes the run in
# milliseconds. Both by default: the SI files carry an _si suffix, so the two
# sets never collide, and re-rendering the pair costs seconds for the figures.
# Narrow it with UNITS=si when only one is wanted -- that halves make movie,
# which is the only target here where the second pass is not free.
UNITS ?= geom si

# The published reference run, once `make fetch-inputs ARGS=--reference` has
# unpacked it under INPUTS_DIR. plot_psi4.py overlays its waveform on this
# run's and skips that figure when the file is absent, so the mount is
# conditional too: docker would otherwise create the missing host directory
# itself, root-owned, and the figure would silently never appear.
REFERENCE_DIR := $(INPUTS_DIR)/bhns_20252103
REF_MOUNT := $(if $(wildcard $(REFERENCE_DIR)),-v $(abspath $(REFERENCE_DIR)):/ref:ro,)

# The container runs as the invoking user so the outputs are not root-owned;
# the two /tmp cache dirs silence matplotlib and fontconfig complaints that
# a read-only home causes.
define POSTPROC_RUN
docker run --rm -u $$(id -u):$$(id -g) \
	-e MPLCONFIGDIR=/tmp -e XDG_CACHE_HOME=/tmp \
	-v $(abspath postprocessing):/app:ro \
	-v $(abspath $(RESULTS_ROOT)/$(RUN_NAME)):/data:ro \
	-v $(abspath postprocessing/out/$(RUN_NAME)):/out \
	$(REF_MOUNT) \
	-w /app $(POSTPROC_IMAGE)
endef

# The same, without the run tree. The node timeline is drawn from the ledger
# rather than from the simulation output, so it keeps working after
# make pack-results has compressed results/ away.
define POSTPROC_RUN_OUT
docker run --rm -u $$(id -u):$$(id -g) \
	-e MPLCONFIGDIR=/tmp -e XDG_CACHE_HOME=/tmp \
	-v $(abspath postprocessing):/app:ro \
	-v $(abspath postprocessing/out/$(RUN_NAME)):/out \
	-w /app $(POSTPROC_IMAGE)
endef

.PHONY: ledger-preflight
ledger-preflight:
	@test -n "$(RUN_NAME)" || \
		{ echo "no run under $(RESULTS_ROOT)/ -- run make fetch-results first, or set RUN_NAME="; exit 1; }
	@docker image inspect $(POSTPROC_IMAGE) >/dev/null 2>&1 || \
		{ echo "image $(POSTPROC_IMAGE) not found -- run make postproc-image"; exit 1; }
	@mkdir -p postprocessing/out/$(RUN_NAME)

.PHONY: postproc-preflight
postproc-preflight: ledger-preflight
	@test -d "$(RESULTS_ROOT)/$(RUN_NAME)/run" || \
		{ echo "$(RESULTS_ROOT)/$(RUN_NAME)/run is missing -- is the fetch complete?"; exit 1; }

##@ Post-processing

.PHONY: fetch-results
fetch-results: ## Sync the run's output from S3 into results/ (observer profile works)
	@TF="$(TF)" scripts/fetch_results.sh $(ARGS)

.PHONY: postproc-image
postproc-image: ## Build the pinned Docker image the figures are rendered in
	@docker build -t $(POSTPROC_IMAGE) postprocessing

.PHONY: figures
figures: postproc-preflight ## Render the Psi4 waveform and the time-series figures (UNITS="geom si")
	@for u in $(UNITS); do \
		$(POSTPROC_RUN) python plot_psi4.py --units $$u || exit 1; \
		$(POSTPROC_RUN) python plot_timeseries.py --units $$u || exit 1; \
	done

.PHONY: movie
movie: postproc-preflight ## Render the density frames, movie and 3-panel snapshot (ARGS=--help)
	@for u in $(UNITS); do \
		$(POSTPROC_RUN) python render_frames.py --units $$u $(ARGS) || exit 1; \
	done

.PHONY: ledger-chart
ledger-chart: ledger-preflight ## Draw the node timeline from the S3 ledger (observer profile works)
	@scripts/run_ledger.sh --tsv $(ARGS) > postprocessing/out/$(RUN_NAME)/ledger.tsv
	@$(POSTPROC_RUN_OUT) python plot_ledger.py

.PHONY: pack-results
pack-results: ## Compress a fetched results tree to tar.gz and delete the tree (asks first)
	@scripts/pack_results.sh $(ARGS)
