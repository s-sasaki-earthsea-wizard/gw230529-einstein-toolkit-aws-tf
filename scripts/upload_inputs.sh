#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Derive the cloud parameter file from the pristine gallery one, check that it
# can survive a spot interruption, and upload it with the initial data.
#
# The gallery parfile is written for COSMA8, where jobs are capped at 30 hours
# and a checkpoint every 29 hours costs nothing. Two settings have to change
# before it is fit for a spot instance:
#
#   IO::checkpoint_every_walltime_hours   29 -> 1.0
#       Expected loss on an interruption is about half the checkpoint interval.
#       A cloud run is 38-76 hours, so leaving it at 29 means an interruption
#       costs 14.5 hours on average -- a fifth to nearly half the whole run.
#       Writing 78 GB stops every rank for ~78 seconds, which at hourly is
#       2.2% of wall clock: cheap against what it protects.
#
#   IO::checkpoint_ID                     absent -> "yes"
#       Absent means "no" (CactusBase/IOUtil param.ccl). The FUKA import took
#       24.9 minutes locally at dx=28 and parallelises only over MPI ranks,
#       so without an initial-data checkpoint every interruption pays it again
#       before evolution can resume.
#
# The upstream file is left untouched; the cloud variant is derived into a
# separate file. Two settings the gallery already gets right for our purposes
# -- recover = "autoprobe" and checkpoint_keep = 2 -- are asserted rather than
# set, so that an upstream change is caught here rather than at 3 USD/hour.
#
# Every rewrite is checked afterwards. A sed that silently matches nothing is
# the failure mode this whole script exists to prevent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

TF="${TF:-terraform}"
SRC_DIR="${INPUTS_DIR:-upstream}"
PARFILE="bhns_gw230529.par"
ID_DIR="bhns_gw230529_ID"
BUILD_DIR="${SRC_DIR}/.cloud"

CADENCE_HOURS="${CHECKPOINT_WALLTIME_HOURS:-1.0}"

if [ ! -f "${SRC_DIR}/${PARFILE}" ] || [ ! -d "${SRC_DIR}/${ID_DIR}" ]; then
  echo "gallery artefacts not found under ${SRC_DIR}/"
  echo "Fetch them first:"
  echo "  make fetch-inputs"
  echo "or point INPUTS_DIR at a directory that already has them."
  exit 1
fi

mkdir -p "${BUILD_DIR}"
OUT="${BUILD_DIR}/${PARFILE}"
cp "${SRC_DIR}/${PARFILE}" "${OUT}"

# Both IO:: and IOUtil:: name the same thorn and the gallery file uses both,
# so every pattern here accepts either.
P='(IO|IOUtil)'

set_or_append() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^[[:space:]]*${P}::${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s#^([[:space:]]*${P}::${key}[[:space:]]*=[[:space:]]*).*\$#\\1${value}#" "${file}"
  else
    # Keep it with the other checkpoint settings when there is an anchor to
    # hang it on, rather than orphaning it at the end of the file.
    if grep -qE "^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=" "${file}"; then
      sed -i -E "/^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=/a IO::${key} = ${value}" "${file}"
    else
      printf '\nIO::%s = %s\n' "${key}" "${value}" >> "${file}"
    fi
  fi
}

echo "Deriving the cloud parfile from ${SRC_DIR}/${PARFILE}"
set_or_append "checkpoint_every_walltime_hours" "${CADENCE_HOURS}" "${OUT}"
set_or_append "checkpoint_ID"                   '"yes"'            "${OUT}"

echo ""
echo "Difference from upstream:"
diff -u "${SRC_DIR}/${PARFILE}" "${OUT}" | sed -n '3,$p' | sed 's/^/  /' || true

# --------------------------------------------------------------------
# Assertions. Two we just set, two the gallery is trusted for -- all four
# checked the same way, because the point is whether the file that reaches S3
# can survive an interruption, not whether a particular sed fired.
# --------------------------------------------------------------------
status=0

assert() {
  local label="$1" pattern="$2" why="$3" line
  # `|| true`: a failing grep is the whole point of this function, and under
  # `set -e` with `pipefail` an unguarded one kills the script at the first
  # missing setting -- reporting nothing, which is the silent failure this
  # script exists to prevent.
  line="$(grep -hE "${pattern}" "${OUT}" | head -1 | sed 's/^[[:space:]]*//' || true)"
  if [ -n "${line}" ]; then
    printf '  %-34s OK   %s\n' "${label}" "${line}"
  else
    printf '  %-34s FAIL %s\n' "${label}" "${why}"
    status=1
  fi
}

echo ""
echo "Spot survivability of the derived parfile:"
assert "checkpoint_every_walltime_hours" \
  "^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=[[:space:]]*${CADENCE_HOURS}([[:space:]]|\$)" \
  "not set to ${CADENCE_HOURS} -- the rewrite did not take"
assert "checkpoint_ID" \
  "^[[:space:]]*${P}::checkpoint_ID[[:space:]]*=[[:space:]]*\"?yes\"?[[:space:]]*\$" \
  "not \"yes\" -- every interruption would re-import the FUKA data"
assert "recover" \
  "^[[:space:]]*${P}::recover[[:space:]]*=[[:space:]]*\"?autoprobe\"?[[:space:]]*\$" \
  "not \"autoprobe\" -- a relaunched node would start from scratch"
assert "checkpoint_keep" \
  "^[[:space:]]*${P}::checkpoint_keep[[:space:]]*=[[:space:]]*[2-9][0-9]*[[:space:]]*\$" \
  "below 2 -- no local fallback if the newest checkpoint is unreadable"

if [ "${status}" -ne 0 ]; then
  echo ""
  echo "Refusing to upload a parfile that cannot survive an interruption."
  echo "Nothing was sent to S3."
  exit 1
fi

# --------------------------------------------------------------------
# Upload
# --------------------------------------------------------------------
BUCKET="$(${TF} -chdir=stacks/foundation output -raw data_bucket 2>/dev/null)"
if [ -z "${BUCKET}" ]; then
  echo ""
  echo "cannot read data_bucket from stacks/foundation -- apply it first"
  exit 1
fi

echo ""
echo "Uploading to s3://${BUCKET}/inputs/"
echo "Upstream gallery material: not committed here, not baked into the image."

aws s3 cp "${OUT}" "s3://${BUCKET}/inputs/${PARFILE}"
aws s3 cp "${SRC_DIR}/${ID_DIR}/" "s3://${BUCKET}/inputs/" \
  --recursive --exclude '*' \
  --include '*.info' --include '*.dat' --include 'gam2.polytrope'

echo ""
echo "Done. The node rewrites the .info eosfile path at boot and aborts if"
echo "that rewrite does not take, so the placeholder in the uploaded copy is"
echo "expected."
