#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Append one row per (configuration, region, zone) of the current Spot
# placement score. Built to be run hourly from cron. Issue #22.
#
# WHY SAMPLE SOMETHING AWS ALREADY PUBLISHES
#
# Because AWS does not publish it over time. Three sources touch spot
# capacity and none of them resolves time of day:
#
#   Spot Instance Advisor   interruption frequency, 30-day average, coarse
#                           buckets, no hour
#   placement score         forward-looking 1-10, for this instant only, no
#                           history and no archive to ask for one
#   spot price history      90 days at fine resolution -- and price stopped
#                           tracking capacity in 2017, so it answers a
#                           different question
#
# The 2026-08 run left a diurnal fingerprint worth naming: every node that
# died before banking a checkpoint started between 05:30 and 09:00 US
# Pacific, and the longest-lived node started at 16:43 Pacific and ran
# through the night. That is suggestive and not established -- the switch
# from c7a to m7a happened at the same time as the shift out of US morning,
# so the two explanations are fully confounded in that run's data.
#
# Settling it needs a series nobody has, and the call that would build one is
# free. A week of rows is the dataset; two weeks covers a weekend twice.
#
# WHAT IS NOT SAMPLED, AND WHY
#
# Price. It is retrievable for 90 days after the fact in one call, so
# recording it hourly would only duplicate an archive AWS already keeps.
# Scores are sampled precisely because no such archive exists.
#
# HOW THE CONFIGURATIONS ARE CHOSEN
#
# Not freely. Two constraints from the API shape them:
#
#   - Fewer than three instance types returns a deliberately low score, so a
#     per-type series is not a thing that can be asked for. What can be asked
#     is "how well supplied is this set", which is what a ladder picks from
#     anyway.
#   - AWS may cap the number of NEW request configurations in 24 hours.
#     Re-sending one already used does not count, so the lists below are
#     fixed and must stay byte-identical between runs. Do not make them
#     configurable.
#
# Usage:
#   scripts/sample_placement_scores.sh          # one sample, appended
#   SPOT_SAMPLE_DIR=/elsewhere scripts/...      # somewhere other than the repo
#
# Hourly, with no MFA, through the read-only observer role:
#   0 * * * * cd <repo> && AWS_PROFILE=gw230529-observer \
#               scripts/sample_placement_scores.sh >> .spot-samples/cron.log 2>&1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

OUT_DIR="${SPOT_SAMPLE_DIR:-${REPO_ROOT}/.spot-samples}"
CSV="${OUT_DIR}/placement-scores.csv"
API_REGION="${AWS_REGION:-us-west-2}"
REGIONS="us-west-2 us-east-1 us-east-2"

# name|target vCPUs|instance types
#
# gw230529: the pools scripts/launch_with_ladder.sh chooses between.
# bns96:    the sizes the BNS grid fits, for that project's own scouting.
CONFIGS=(
  "gw230529-192|192|c7a.48xlarge m7a.48xlarge r7a.48xlarge"
  "bns-96|96|c7a.24xlarge c7a.16xlarge c7a.48xlarge"
)

mkdir -p "${OUT_DIR}"
[ -f "${CSV}" ] || echo "ts_utc,config,target_vcpus,region,az_id,score" > "${CSV}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
read -r -a REGION_LIST <<< "${REGIONS}"
rows=0

for config in "${CONFIGS[@]}"; do
  IFS='|' read -r name target types <<< "${config}"
  read -r -a TYPE_LIST <<< "${types}"

  if ! out="$(aws ec2 get-spot-placement-scores \
      --region "${API_REGION}" \
      --instance-types "${TYPE_LIST[@]}" \
      --target-capacity "${target}" \
      --target-capacity-unit-type vcpu \
      --single-availability-zone \
      --region-names "${REGION_LIST[@]}" \
      --query 'SpotPlacementScores[].[Region,AvailabilityZoneId,Score]' \
      --output text 2>&1)"; then
    # Quiet on the one failure that is expected until the observer role has
    # been re-applied with ec2:GetSpotPlacementScores. An hourly cron that
    # mails a stack trace until someone runs terraform is how a useful series
    # gets switched off before it has any rows in it.
    case "${out}" in
      *AccessDenied*|*UnauthorizedOperation*)
        echo "${TS} not permitted yet: apply the observer role with GetSpotPlacementScores"
        exit 0 ;;
      *)
        echo "${TS} ${name}: ${out}" >&2
        continue ;;
    esac
  fi

  while read -r region az score; do
    [ -n "${region}" ] || continue
    printf '%s,%s,%s,%s,%s,%s\n' "${TS}" "${name}" "${target}" "${region}" "${az}" "${score}" >> "${CSV}"
    rows=$((rows + 1))
  done <<< "${out}"
done

echo "${TS} appended ${rows} rows to ${CSV}"
