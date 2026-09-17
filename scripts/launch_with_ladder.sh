#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Launch the run node, treating spot capacity as a search rather than a
# parameter. Issue #22.
#
# WHAT WENT WRONG WITHOUT IT
#
# On 2026-08-27 the first production node was reclaimed with
# instance-terminated-no-capacity, and the relaunch into the same zone could
# not be filled either -- no instance and no spot request was ever created,
# the provider simply retried inside RunInstances until a human noticed the
# apply was hanging, worked out which failure it was, and edited
# availability_zone in terraform.tfvars. That happened three times.
#
# The fallback order existed. It was written in the tfvars comments, in
# prose, and nothing executable walked it.
#
# Worse, the evening showed the prose had the wrong shape. The crunch was
# specific to the c7a pools, not to the zones: five consecutive c7a nodes in
# us-west-2a were reaped inside half an hour each, banking nothing, while an
# m7a request in the same zone was filled on the first sixty second poll.
# c7a and m7a 48xlarge are the same Genoa silicon with the same twelve memory
# channels, so for a bandwidth-bound evolution the only thing c7a buys is the
# lower price. A search that refuses to leave the c7a row optimises 0.7 USD/h
# while burning 3 USD/h on recomputation.
#
# So a rung is a (zone, instance type) pair, and the ladder crosses both.
#
# HOW LONG A RUNG IS GIVEN
#
# InsufficientInstanceCapacity is an EC2 server error, so the AWS SDK retries
# it like any 500. At the provider default of 25 attempts with a 300 second
# backoff cap, one rung would hold the ladder for the better part of an hour.
# LADDER_RETRIES lowers it, and the ladder cycles instead: sampling six pools
# ten times finds a pool that frees up sooner than waiting on the first one,
# and nothing is created or billed by an attempt that fails this way.
#
# WHAT IT REFUSES TO DO
#
# Walk past a failure it does not recognise, and walk past a quota. Another
# pool cannot fix either, and an unattended loop stepping through a ladder at
# 3 USD/h on a misunderstanding is the failure mode this is supposed to
# prevent rather than introduce.
#
# Usage:
#   scripts/launch_with_ladder.sh            # ladder from .env, or one rung
#                                            # from terraform.tfvars
#
# Environment (usually set in .env):
#   LAUNCH_LADDER      space separated zone:type rungs, tried in order
#   LADDER_RETRIES     SDK attempts per rung (default 4)
#   LADDER_PASSES      full passes before giving up (default 3)
#   LADDER_PASS_SLEEP  seconds between passes (default 300)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

if [ -f "${REPO_ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.env"
fi

TF="${TF:-terraform}"
LAUNCH_LADDER="${LAUNCH_LADDER:-}"
LADDER_RETRIES="${LADDER_RETRIES:-4}"
LADDER_PASSES="${LADDER_PASSES:-3}"
LADDER_PASS_SLEEP="${LADDER_PASS_SLEEP:-300}"

say() { echo "[$(date -u +%FT%TZ)] $*"; }

# ------------------------------------------------------------------
# The ladder, and whether the foundation stack can actually serve it
# ------------------------------------------------------------------
# A zone with no subnet fails at plan time with a missing map key, which
# during a crunch would read as one more capacity problem. Checking first
# turns a typo into one line before anything is attempted.
ZONES_JSON="$(${TF} -chdir=stacks/compute output -json available_zones 2>/dev/null)" || {
  echo "cannot read the compute stack -- no session? eval \"\$(make login)\" first" >&2
  exit 1
}

read -r -a RUNGS <<< "${LAUNCH_LADDER}"
if [ "${#RUNGS[@]}" -eq 0 ]; then
  # No ladder configured: one rung, taken from terraform.tfvars, which is
  # exactly what `make run` did before this script existed.
  say "no LAUNCH_LADDER set -- launching once with the settings in terraform.tfvars"
  # One empty rung: no -var overrides, so terraform.tfvars decides. This is
  # exactly what `make run` did before the ladder existed, which is what the
  # unset default should stay.
  RUNGS=("")
fi

for rung in "${RUNGS[@]}"; do
  zone="${rung%%:*}"
  [ -n "${zone}" ] || continue
  if ! printf '%s' "${ZONES_JSON}" | grep -q "\"${zone}\""; then
    echo "rung ${rung} names ${zone}, which the foundation stack has no subnet in." >&2
    echo "Zones available: ${ZONES_JSON}" >&2
    echo "Add it to availability_zones in stacks/foundation, or fix LAUNCH_LADDER." >&2
    exit 2
  fi
done

# ------------------------------------------------------------------
# Classify a failed apply
# ------------------------------------------------------------------
# next   this pool cannot serve us; another might
# retry  nothing to do with the pool; the same rung is still the best one
# stop   another pool cannot help, so stop and let a human look
classify() {
  local out="$1"
  if grep -q 'InsufficientInstanceCapacity' "${out}"; then echo "next:capacity"; return; fi
  # A price ceiling below the market, or a type the zone does not offer. Both
  # are properties of the rung, and both fail immediately rather than after a
  # wait, so walking on costs nothing.
  if grep -qE 'SpotMaxPriceTooLow|Unsupported' "${out}"; then echo "next:pool-shape"; return; fi
  # Throttling says the account is busy, not that the pool is empty.
  if grep -qE 'RequestLimitExceeded|Throttling' "${out}"; then echo "retry:throttled"; return; fi
  # A quota is account-wide. Every other rung would fail the same way.
  if grep -qE 'MaxSpotInstanceCountExceeded|VcpuLimitExceeded|InstanceLimitExceeded' "${out}"; then
    echo "stop:quota"; return
  fi
  if grep -qE 'ExpiredToken|InvalidClientTokenId|RequestExpired' "${out}"; then
    echo "stop:credentials"; return
  fi
  echo "stop:unknown"
}

# ------------------------------------------------------------------
# Walk it
# ------------------------------------------------------------------
ATTEMPTS="[]"
# Colon-free, because this becomes an S3 key. Legal with colons, awkward to
# paste into a URL afterwards, and the other markers in this prefix avoid them.
STARTED="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

record() {   # rung, outcome, seconds
  ATTEMPTS="$(printf '%s' "${ATTEMPTS}" | jq -c \
    --arg rung "$1" --arg outcome "$2" --argjson seconds "$3" \
    '. + [{rung: $rung, outcome: $outcome, seconds: $seconds}]')"
}

publish() {  # result, instance id
  local prefix
  prefix="$(${TF} -chdir=stacks/compute output -raw log_prefix 2>/dev/null)" || return 0
  jq -n --arg started "${STARTED}" --arg finished "$(date -u +%Y%m%dT%H%M%SZ)" \
        --arg result "$1" --arg instance "$2" --argjson attempts "${ATTEMPTS}" \
    '{started: $started, finished: $finished, result: $result,
      instance_id: $instance, attempts: $attempts}' \
    | aws s3 cp - "${prefix}launch-${STARTED}.json" --only-show-errors || true
  say "attempt record written to ${prefix}launch-${STARTED}.json"
}

for pass in $(seq 1 "${LADDER_PASSES}"); do
  for rung in "${RUNGS[@]}"; do
    zone="${rung%%:*}"
    type="${rung##*:}"

    args=(-input=false -auto-approve -var run_enabled=true
          -var "aws_max_retries=${LADDER_RETRIES}")
    [ -n "${zone}" ] && args+=(-var "availability_zone=${zone}")
    [ -n "${type}" ] && args+=(-var "instance_type=${type}")

    say "pass ${pass}/${LADDER_PASSES}, rung ${rung:-<tfvars>}: apply"
    t0=$SECONDS
    if ${TF} -chdir=stacks/compute apply "${args[@]}" 2>&1 | tee "${OUT}"; then
      elapsed=$((SECONDS - t0))
      instance="$(${TF} -chdir=stacks/compute output -raw instance_id 2>/dev/null)"
      record "${rung:-tfvars}" "launched" "${elapsed}"
      say "launched ${instance} on ${rung:-<tfvars>} after ${elapsed}s"
      publish "launched" "${instance}"
      exit 0
    fi
    elapsed=$((SECONDS - t0))

    verdict="$(classify "${OUT}")"
    record "${rung:-tfvars}" "${verdict}" "${elapsed}"
    case "${verdict}" in
      next:*)
        say "${rung:-<tfvars>} declined after ${elapsed}s (${verdict#next:}) -- next rung"
        ;;
      retry:*)
        say "${rung:-<tfvars>} hit ${verdict#retry:} after ${elapsed}s -- pausing 60s and retrying it"
        sleep 60
        ;;
      stop:credentials)
        say "the operator session has expired. The RUN IS UNAFFECTED."
        say "eval \"\$(make login)\" and start this again."
        publish "stopped-credentials" ""
        exit 3
        ;;
      stop:quota)
        say "a service quota stopped this, and no other pool can fix it."
        say "Check L-34B43A08 (spot vCPUs) for this region."
        publish "stopped-quota" ""
        exit 4
        ;;
      *)
        say "unrecognised failure -- stopping rather than stepping the ladder."
        say "The terraform output is above."
        publish "stopped-unknown" ""
        exit 5
        ;;
    esac
  done

  if [ "${pass}" -lt "${LADDER_PASSES}" ]; then
    say "every rung declined; sleeping ${LADDER_PASS_SLEEP}s before pass $((pass + 1))"
    sleep "${LADDER_PASS_SLEEP}"
  fi
done

say "no pool on the ladder had capacity in ${LADDER_PASSES} passes."
say "Widen LAUNCH_LADDER, or try again later -- make region-scout shows current scores."
publish "exhausted" ""
exit 6
