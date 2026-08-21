#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Read evolution throughput out of a Cactus run log and turn it into hours and
# dollars.
#
# sec/iter is the number the whole cost model rests on, and until this script
# existed it was being eyeballed. The log offers two independent ways to get
# it and they check each other:
#
#   Carpet's own reading.  Carpet::physical_time_per_hour is the second column
#     of the CarpetIOBasic info line, in M of simulation time per hour of wall
#     clock. It is a trailing average over Carpet::timing_average_window_minutes
#     (10 by default), so it settles within a few window lengths and needs no
#     clock in the log at all -- which is why this script works on runs that
#     predate the line stamping.
#
#   The wall clock.  Runs from 2026-08-21 onwards carry an ISO timestamp on
#     every line, so the elapsed time between two info lines divides straight
#     into the iterations between them.
#
# The two agree only if nothing is being missed. Carpet's average is over a
# window it chooses; the wall clock covers whatever window is asked for,
# including the seconds a checkpoint write stops every rank. A gap between the
# two is a real finding, not noise -- it is the tax the run pays outside the
# evolution loop, and the budget has to carry it.
#
# The window matters more than the arithmetic. Phase 2 of the simulation
# repository once read 30 sec/iter off iterations 32-36 of a run whose settled
# rate was 43, because the start of a run is dominated by things that happen
# once: the first AHFinderDirect search, the initial 2D output, the caches
# filling. --skip-minutes drops that head before anything is fitted.
#
# Usage:
#   scripts/read_throughput.sh [options] [log|s3://...]
#
#   With no log argument the current run's log is fetched from the bucket.
#
# Options:
#   --skip-minutes N   discard the first N minutes of evolution (default 15)
#   --target-time M    physical time to project to, in M (default 2000)
#   --usd-per-hour X   spot price used for the projection (default 2.978)
#   --window-from IT   start the window at iteration IT instead of by time
#
# Examples:
#   scripts/read_throughput.sh
#   scripts/read_throughput.sh --target-time 1500 run/cactus-stdout.log
#   scripts/read_throughput.sh --usd-per-hour 3.05 s3://bucket/run/.../log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TF="${TF:-terraform}"

SKIP_MINUTES=15
TARGET_TIME=2000
# us-west-2d, c7a.48xlarge, measured 2026-08-21. Override for another zone or
# a different instance type -- the projection is linear in it.
USD_PER_HOUR=2.978
WINDOW_FROM=""
SOURCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-minutes) SKIP_MINUTES="$2"; shift 2 ;;
    --target-time)  TARGET_TIME="$2";  shift 2 ;;
    --usd-per-hour) USD_PER_HOUR="$2"; shift 2 ;;
    --window-from)  WINDOW_FROM="$2";  shift 2 ;;
    -h|--help)      sed -n '36,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 2 ;;
    *)              SOURCE="$1"; shift ;;
  esac
done

TMP=""
cleanup() { [ -n "${TMP}" ] && rm -f "${TMP}" || true; }
trap cleanup EXIT

# ------------------------------------------------------------------
# Locate the log
# ------------------------------------------------------------------
if [ -z "${SOURCE}" ]; then
  cd "${REPO_ROOT}"
  PREFIX="$(${TF} -chdir=stacks/compute output -raw run_prefix 2>/dev/null || true)"
  if [ -z "${PREFIX}" ]; then
    echo "no log given and stacks/compute has no run_prefix output." >&2
    echo "Pass a path, or an s3:// URL." >&2
    exit 1
  fi
  # The run name appears twice in the path. That is issue #5, not a typo: the
  # sync mirrors $WORK_DIR/simulations/ into <run>/output/ and the run
  # directory inside it is already named after the run.
  RUN_NAME="$(basename "${PREFIX%/}")"
  SOURCE="${PREFIX}output/${RUN_NAME}/run/cactus-stdout.log"
fi

case "${SOURCE}" in
  s3://*)
    TMP="$(mktemp)"
    if ! aws s3 cp "${SOURCE}" "${TMP}" --only-show-errors; then
      echo "could not fetch ${SOURCE}" >&2
      echo "A run that has not reached its first sync has nothing there yet." >&2
      exit 1
    fi
    LOG="${TMP}"
    ;;
  *)
    LOG="${SOURCE}"
    [ -f "${LOG}" ] || { echo "no such log: ${LOG}" >&2; exit 1; }
    ;;
esac

echo "log            ${SOURCE}"
echo ""

# ------------------------------------------------------------------
# Parse
#
# Everything below is one pass. Timestamps are converted without mktime, which
# is a gawk extension -- the operator's machine may well have mawk, and the
# whole point of this script is that it runs anywhere the log can be read.
# ------------------------------------------------------------------
awk \
  -v skip_minutes="${SKIP_MINUTES}" \
  -v target_time="${TARGET_TIME}" \
  -v usd_per_hour="${USD_PER_HOUR}" \
  -v window_from="${WINDOW_FROM}" \
  '
function isleap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

function iso2epoch(s,   y, mo, d, h, mi, se, days, i, md) {
  y  = substr(s,  1, 4) + 0; mo = substr(s,  6, 2) + 0; d  = substr(s,  9, 2) + 0
  h  = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
  days = 0
  for (i = 1970; i < y; i++) days += isleap(i) ? 366 : 365
  split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ")
  for (i = 1; i < mo; i++) { days += md[i]; if (i == 2 && isleap(y)) days += 1 }
  days += d - 1
  return ((days * 24 + h) * 60 + mi) * 60 + se
}

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function hms(sec,   h, m) {
  h = int(sec / 3600); m = int((sec - h * 3600) / 60)
  return sprintf("%dh %02dm", h, m)
}

BEGIN {
  n = 0; stamped = 0; unstamped = 0; import_total = 0; import_levels = 0
  nckpt = 0
}

{
  line = $0
  ts = -1
  # A stamped line is "[YYYY-MM-DDTHH:MM:SSZ] ..." -- 22 characters of prefix.
  if (substr(line, 1, 1) == "[" && substr(line, 22, 1) == "]") {
    ts = iso2epoch(substr(line, 2, 20))
    line = substr(line, 24)
    stamped++
  } else {
    unstamped++
  }

  # Initial data. One "Filling took" per refinement level; the sum is what an
  # interruption costs when IO::checkpoint_ID is not set.
  if (line ~ /KadathImporter.*Filling took/) {
    split(line, ft, "Filling took")
    import_total += ft[2] + 0
    import_levels++
  }

  if (line ~ /Dumping .* checkpoint at iteration/) {
    nckpt++
    ckpt_line[nckpt] = trim(line)
    ckpt_ts[nckpt] = ts
  }

  # CarpetIOBasic info line: "<it> <time> | <physical_time_per_hour> | ..."
  # The header carries the same shape with a non-numeric first field, and the
  # rule lines have no pipe at all.
  if (index(line, "|") == 0) next
  nf = split(line, f, "|")
  if (nf < 2) next
  head = trim(f[1])
  if (split(head, h2, /[ \t]+/) != 2) next
  if (h2[1] !~ /^[0-9]+$/) next
  if (h2[2] !~ /^[0-9]+(\.[0-9]+)?$/) next

  n++
  it[n] = h2[1] + 0
  pt[n] = h2[2] + 0
  ptph[n] = trim(f[2]) + 0
  wall[n] = ts
}

END {
  if (n < 2) {
    print "no evolution in this log: fewer than two CarpetIOBasic info lines."
    print "A memory probe or a run that died during the initial data import"
    print "will look like this."
    if (import_levels > 0)
      printf "initial data   %d levels, %.1f s total\n", import_levels, import_total
    exit 3
  }

  have_clock = (stamped > unstamped / 4)

  # ---------------- initial data ----------------
  if (import_levels > 0)
    printf "initial data   %d levels imported, %.0f s (%.1f min) total\n", \
      import_levels, import_total, import_total / 60
  else
    print  "initial data   no Kadath import in this log (recovered from a checkpoint)"

  # ---------------- evolution extent ----------------
  dt = (pt[n] - pt[1]) / (it[n] - it[1])
  printf "evolution      iterations %d..%d, t = %.2f..%.2f M, dt = %.4f M\n", \
    it[1], it[n], pt[1], pt[n], dt
  printf "info lines     %d, %s\n", n, \
    have_clock ? "wall clock stamps present" : "NO wall clock stamps -- Carpet reading only"
  print ""

  # ---------------- pick the window ----------------
  start = 1
  if (window_from != "") {
    for (i = 1; i <= n; i++) if (it[i] >= window_from + 0) { start = i; break }
    reason = sprintf("from iteration %d as asked", it[start])
  } else if (have_clock) {
    for (i = 1; i <= n; i++)
      if (wall[i] > 0 && wall[i] - wall[1] >= skip_minutes * 60) { start = i; break }
    reason = sprintf("first %g minutes of evolution discarded", skip_minutes)
  } else {
    # No clock: fall back to a fixed number of iterations. 64 is what the
    # dx=28 run needed before its reading stopped climbing.
    for (i = 1; i <= n; i++) if (it[i] >= it[1] + 64) { start = i; break }
    reason = "first 64 iterations discarded (no clock to measure minutes with)"
  }
  if (start >= n) { start = 1; reason = reason " -- log too short, using all of it" }

  printf "window         iterations %d..%d (%s)\n", it[start], it[n], reason
  window_span = (have_clock && wall[start] > 0 && wall[n] > 0) ? wall[n] - wall[start] : -1
  if (window_span >= 0)
    printf "               %s of wall clock\n", hms(window_span)

  # Is the window long enough to mean anything?
  #
  # Carpet averages its own reading over 10 wall clock minutes by default, so
  # anything shorter than a couple of those is still reporting the start-up
  # transient. Unclocked, iterations are the only proxy: the dx=28 run needed
  # about 64 before its reading stopped climbing, so 256 is a fair margin.
  #
  # This guard is here because the mistake has already been made twice. The
  # simulation repository read 30 sec/iter off iterations 32-36 of a run whose
  # settled rate was 43, and the 2026-08-20 memory probe stopped at iteration
  # 4 -- from which this script will still happily compute a number to the
  # nearest dollar if nothing stops it.
  settled = 1
  if (window_span >= 0) {
    if (window_span < 20 * 60) { settled = 0; why = sprintf("%s of wall clock, against the 20 min two Carpet averaging windows need", hms(window_span)) }
  } else if (it[n] - it[start] < 256) {
    settled = 0; why = sprintf("%d iterations, against the 256 a rate needs to stop climbing", it[n] - it[start])
  }
  if (!settled) {
    print ""
    print "*** NOT SETTLED ***"
    printf "    %s.\n", why
    print "    Everything below is arithmetic on a start-up transient. Treat it"
    print "    as an order of magnitude and run the probe for longer."
  }
  print ""

  # ---------------- the Carpet reading ----------------
  # Median rather than mean: the sample right after a checkpoint write is a
  # genuine outlier and the median is what a long run behaves like.
  m = 0
  for (i = start; i <= n; i++) if (ptph[i] > 0) { m++; s[m] = ptph[i] }
  if (m > 0) {
    for (i = 1; i < m; i++) for (j = i + 1; j <= m; j++) if (s[j] < s[i]) { t = s[i]; s[i] = s[j]; s[j] = t }
    med = (m % 2) ? s[(m + 1) / 2] : (s[m / 2] + s[m / 2 + 1]) / 2
    printf "Carpet         %.2f M/h median over the window (last %.2f, min %.2f, max %.2f)\n", \
      med, ptph[n], s[1], s[m]
    printf "               = %.2f sec/iter at dt = %.4f M\n", dt * 3600 / med, dt
    carpet_mph = med
  }

  # ---------------- the wall clock ----------------
  if (have_clock && wall[start] > 0 && wall[n] > 0 && wall[n] > wall[start]) {
    elapsed = wall[n] - wall[start]
    iters = it[n] - it[start]
    spi_all = elapsed / iters

    # Per-sample rates, so that the stop-the-world events can be separated
    # from the evolution loop. The median sample is the loop; the mean over
    # the whole window is what the run actually costs.
    k = 0
    for (i = start; i < n; i++) {
      if (wall[i] <= 0 || wall[i + 1] <= 0) continue
      d = (wall[i + 1] - wall[i]) / (it[i + 1] - it[i])
      k++; r[k] = d
    }
    if (k > 0) {
      for (i = 1; i < k; i++) for (j = i + 1; j <= k; j++) if (r[j] < r[i]) { t = r[i]; r[i] = r[j]; r[j] = t }
      spi_med = (k % 2) ? r[(k + 1) / 2] : (r[k / 2] + r[k / 2 + 1]) / 2
    } else spi_med = spi_all

    printf "wall clock     %.2f sec/iter mean over the window (%d iterations in %s)\n", \
      spi_all, iters, hms(elapsed)
    printf "               %.2f sec/iter median sample -- the evolution loop alone\n", spi_med
    if (spi_med > 0)
      printf "               overhead outside the loop: %+.1f%%\n", (spi_all / spi_med - 1) * 100
    printf "               = %.2f M/h\n", dt * 3600 / spi_all

    if (carpet_mph > 0) {
      disagree = (dt * 3600 / carpet_mph) / spi_all
      printf "cross-check    Carpet / wall clock = %.3f", disagree
      if (disagree < 0.9 || disagree > 1.1)
        print "  <- they disagree; trust the wall clock and find out why"
      else
        print "  (consistent)"
    }
    spi = spi_all
  } else if (carpet_mph > 0) {
    spi = dt * 3600 / carpet_mph
  } else {
    print "nothing usable in this log."
    exit 3
  }

  # ---------------- stalls ----------------
  if (have_clock) {
    print ""
    printf "stalls over %.0f sec/iter (three times the median sample):\n", spi_med * 3
    found = 0
    for (i = start; i < n; i++) {
      if (wall[i] <= 0 || wall[i + 1] <= 0) continue
      d = (wall[i + 1] - wall[i]) / (it[i + 1] - it[i])
      if (d > spi_med * 3) {
        found++
        printf "  iterations %d..%d  %.0f s  (%.1f sec/iter)\n", \
          it[i], it[i + 1], wall[i + 1] - wall[i], d
      }
    }
    if (!found) print "  none"
  }

  if (nckpt > 0) {
    print ""
    print "checkpoints written:"
    for (i = 1; i <= nckpt; i++) print "  " ckpt_line[i]
  }

  # ---------------- projection ----------------
  print ""
  print "----------------------------------------------------------------"
  remaining_iters = (target_time - pt[n]) / dt
  if (remaining_iters < 0) remaining_iters = 0
  total_iters = target_time / dt
  total_h = total_iters * spi / 3600
  printf "projection to t = %g M at %.2f sec/iter%s\n", target_time, spi, \
    settled ? "" : "  [NOT SETTLED -- see above]"
  printf "  %.0f iterations from t = 0, %.1f h of evolution, %.0f USD at %.3f USD/h\n", \
    total_iters, total_h, total_h * usd_per_hour, usd_per_hour
  printf "  still to run from t = %.1f M: %.1f h, %.0f USD\n", \
    pt[n], remaining_iters * spi / 3600, remaining_iters * spi / 3600 * usd_per_hour
  print ""
  print "Add the initial data import once, and whatever the merger costs above"
  print "the inspiral -- this projection is linear in a rate measured before it."
}
' "${LOG}"
