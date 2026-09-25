# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Plot the (l=2, m=2) mode of Psi4 at the outermost extraction radius.

Reads the Multipole thorn's HDF5 output directly (mp_psi4.h5). The ASCII
multipole files of this run are useless for this figure -- they carry the
same 15.36 M sampling but were confused with the reference run's dense ones
once already, so the HDF5 file is the single source here.

Sampling honesty: dt = 15.36 M gives ~7 samples per gravitational-wave cycle
through merger and ~5 in ringdown. The chirp and the peak are resolved; the
ringdown tail is visibly angular. That is a property of the run's Multipole
output cadence, not of this script, and it cannot be improved after the fact.

--units si restates both axes for an audience outside numerical relativity:
milliseconds, and the s^-2 that Psi4 carries as the second time derivative
of a dimensionless strain. What SI does NOT buy here is meaning -- the
quantity a non-specialist recognises is the strain h, and recovering it
takes a double time integration this script deliberately does not attempt.

When the published reference run's waveform is mounted (make fetch-inputs
ARGS=--reference puts it under INPUTS_DIR), a second figure overlays the two
and draws their difference underneath. The reference is a line and this run
is a marker on it, the oldest idiom there is for "the published curve, and
our points on it" -- two curves of similar weight agree into a single line,
and a pale one under a dark one only reads as a band around it. The
lower panel is what turns it into a number: the two start at machine
precision (same initial data), sit near 1e-14 while nothing has happened
yet, and then drift apart through inspiral and merger by thirteen orders of
magnitude -- they were never the same computation (480 ranks on 12 nodes
against 192 on one, on different hardware), and the merger amplifies
whatever they disagree on -- to end at a few 1e-4 of the peak. The reference
file shares this run's 15.36 M sampling exactly, so the subtraction
involves no interpolation at all.
"""

import argparse
import os
import re
from collections import namedtuple

import h5py
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.lines import Line2D

from common import (
    BLUE,
    FIGSIZE,
    GREEN,
    UNIT_SYSTEMS,
    VERMILLION,
    add_units_argument,
    apply_style,
    dedup_sorted,
    fmt_value,
    save,
)


def mark_peak(ax, tpk, us, annotate):
    ax.axvline(tpk, color="0.5", linewidth=1, linestyle="--")
    if annotate:
        ax.annotate(
            rf"peak $t={fmt_value(tpk)}\,{us.time_unit}$",
            xy=(tpk, 1.0),
            xycoords=("data", "axes fraction"),
            xytext=(6, -14),
            textcoords="offset points",
            fontsize=11,
            color="0.35",
        )


def psi4_ylabel(radius, us, prefix=""):
    r_txt = rf"{fmt_value(float(radius) * us.length)}\,{us.length_unit}"
    return us.label(rf"{prefix}\Psi_4^{{2,2}}\ \mathrm{{at}}\ r = {r_txt}", us.psi4_unit)


def plot_waveform(t, re, im, radius, us, outdir, stem):
    """Real part with the amplitude envelope, one run on its own."""
    t = t * us.time
    re, im = re * us.psi4, im * us.psi4
    amp = np.hypot(re, im)
    tpk = t[amp.argmax()]

    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.fill_between(t, -amp, amp, color=VERMILLION, alpha=0.15, linewidth=0)
    ax.plot(t, amp, color=VERMILLION, linewidth=1.2, label=r"$|\Psi_4|$")
    ax.plot(t, re, color=BLUE, linewidth=2.0, label=r"$\mathrm{Re}\,\Psi_4$")
    mark_peak(ax, tpk, us, annotate=True)
    # Force the exponent into the offset text. Psi4 is ~1e-6 in geometric
    # units and ~1e5 in SI, and matplotlib only volunteers an offset for the
    # first: left alone, the SI figure prints six-digit tick labels.
    ax.ticklabel_format(axis="y", style="sci", scilimits=(0, 0))
    ax.set_xlabel(us.label("t", us.time_unit))
    ax.set_ylabel(psi4_ylabel(radius, us))
    ax.legend(loc="upper left", frameon=False)
    fig.tight_layout()
    save(fig, outdir, stem)


# A Cactus info line: "[<iso>]   <iteration>   <cctk_time> | ..."
INFO_LINE = re.compile(r"^\[(\S+)\]\s+(\d+)\s+([0-9.]+)\s+\|")

# One resumption: where the run had got to before it lost its node, and
# where the next node picked up. The iterations ride along so a row can be
# checked against `make ledger` without deriving them again.
Resumption = namedtuple("Resumption", "it_lost t_lost it_resume t_resume")


def load_resumptions(datadir):
    """Find where the run resumed from a checkpoint, in simulation time.

    A spot reclaim leaves no marker in the Cactus log -- the process simply
    stops mid-line. What it does leave is the next node's recovery: the
    iteration counter jumps backwards to the last banked checkpoint. Every
    backward step in the log is therefore one resumption, and the pair it
    yields is (the time the run had reached, the time it restarted from).
    The gap between them is work that had to be computed twice.

    One resumption per interruption is not guaranteed, and on the 2026-08
    run it did not hold: a node reclaimed before Cactus started writes
    nothing here, so its loss folds into the next resumption. That is why
    the log shows twelve and EC2 reclaimed thirteen -- see
    count_interruptions for the second number.

    Read from the log rather than from the ledger because the positions are
    the log's to give: the ledger knows iterations per node, but the log is
    where the run itself says where it went back to, and it travels with the
    run data this figure already needs.
    """
    path = f"{datadir}/cactus-stdout.log"
    if not os.path.exists(path):
        return []
    seen = []
    with open(path, errors="replace") as f:
        for line in f:
            m = INFO_LINE.match(line)
            if m:
                seen.append((int(m.group(2)), float(m.group(3))))
    return [
        Resumption(*seen[i], *seen[i + 1])
        for i in range(len(seen) - 1)
        if seen[i + 1][0] < seen[i][0]
    ]


# How the two ends of each resumption are drawn. Lines only, no shading between
# them: a fill sits under the data across a quarter of the axis, and this
# figure is about a waveform, not about the reclaims.
LOST_STYLE = {"color": "0.45", "linewidth": 0.9, "linestyle": "--"}
RESUME_STYLE = {"color": "0.65", "linewidth": 0.9, "linestyle": (0, (1, 2))}


def count_interruptions(outdir, resumptions):
    """How many nodes EC2 reclaimed, from the ledger, when it is on hand.

    The log cannot count interruptions, only resumptions (load_resumptions).
    Only the ledger (`make ledger-chart`, rebuilt from the bootstrap logs on
    S3) knows about a node that died before Cactus started, so the count is
    read from it when present and left off the figure when not; the lines
    themselves stand on the log alone.

    Cross-checked before it is quoted: the reclaimed nodes that did evolve
    must be exactly as many as the resumptions the log shows, one each. If
    they are not, the two files describe different runs, or one of them is
    stale, and printing a second number beside the first would be a guess.
    """
    path = f"{outdir}/ledger.tsv"
    if not os.path.exists(path):
        print(f"no ledger at {path}: counting resumptions only (make ledger-chart adds the rest)")
        return None
    total = evolved = 0
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            if cols[1] != "spot-interruption":
                continue
            total += 1
            if cols[4] != "-":  # evolution_started
                evolved += 1
    if evolved != len(resumptions):
        print(
            f"ledger has {evolved} reclaimed nodes that evolved, the log {len(resumptions)} "
            "resumptions: not quoting an interruption count"
        )
        return None
    return total


def mark_resumptions(ax, events, us):
    """Dash where a node was lost, dot where the next one resumed."""
    for ev in events:
        ax.axvline(ev.t_lost * us.time, zorder=0, **LOST_STYLE)
        ax.axvline(ev.t_resume * us.time, zorder=0, **RESUME_STYLE)


def write_tsv(path, preamble, header, rows, fmt):
    """Write one table: comment preamble, column header, then the rows.

    Tab separated with a '#' preamble, so `awk`, `numpy.loadtxt` and a
    spreadsheet import all take it unchanged. Units live in the column names
    rather than in prose, because a column is what gets copied out of here.
    """
    with open(path, "w") as f:
        for line in preamble:
            f.write(f"# {line}\n")
        f.write("\t".join(header) + "\n")
        for row in rows:
            f.write("\t".join(fmt % v if isinstance(v, float) else str(v) for v in row) + "\n")
    print(f"wrote {path}")


def dump_comparison_tsv(outdir, stem, t, re, im, rre, rim, rel, radius, us):
    """The per-sample table behind the comparison figure."""
    write_tsv(
        f"{outdir}/{stem}.tsv",
        [
            f"Psi4 (2,2) at r = {fmt_value(float(radius) * us.length)} {us.length_plain}: "
            "this run against the published reference run.",
            f"Psi4 columns are in {us.psi4_plain}; rel_diff is dimensionless.",
            "rel_diff = |Psi4_this - Psi4_ref| / max|Psi4_ref|, complex difference.",
            "Both runs store the same 15.36 Msun cadence, so no interpolation is involved.",
        ],
        [
            f"t[{us.time_plain}]",
            "re_this",
            "im_this",
            "re_ref",
            "im_ref",
            "rel_diff",
        ],
        zip(
            t * us.time,
            re * us.psi4,
            im * us.psi4,
            rre * us.psi4,
            rim * us.psi4,
            rel,
        ),
        "%.9e",
    )


def dump_resumptions_tsv(outdir, stem, events, interruptions, us):
    """Each resumption from a checkpoint, on the simulation clock."""
    if not events:
        return
    total = sum(e.t_lost - e.t_resume for e in events) * us.time
    preamble = [
        f"{len(events)} resumptions from a checkpoint, read from cactus-stdout.log:",
        "an iteration counter that steps backwards is one node lost and the next recovering.",
    ]
    if interruptions is not None:
        preamble.append(
            f"The run had {interruptions} spot interruptions (ledger.tsv); "
            f"{interruptions - len(events)} of them came before Cactus had started, "
            "leaving no row here."
        )
    preamble += [
        f"recomputed = t_lost - t_resume, work done twice. Total {total:.4g} {us.time_plain}.",
        "Iterations are included so a row can be checked against `make ledger`.",
    ]
    write_tsv(
        f"{outdir}/{stem}.tsv",
        preamble,
        [
            "it_lost",
            f"t_lost[{us.time_plain}]",
            "it_resume",
            f"t_resume[{us.time_plain}]",
            f"recomputed[{us.time_plain}]",
        ],
        [
            (
                e.it_lost,
                e.t_lost * us.time,
                e.it_resume,
                e.t_resume * us.time,
                (e.t_lost - e.t_resume) * us.time,
            )
            for e in events
        ],
        "%.6f",
    )


def align_reference(t, ref):
    """Bring the reference waveform onto this run's sample times.

    The published run stores the same 15.36 M cadence, so the times normally
    coincide and the values are used as they are. If a future reference is
    sampled differently it is interpolated onto this run's times -- never
    the other way round, since this run is the sparser of the two -- and
    the figure's caller is told, because interpolation error then sits in
    the residual panel alongside the physics.
    """
    rt, rre, rim = ref
    inside = rt <= t[-1] + 1e-6
    if inside.sum() == len(t) and np.allclose(rt[inside], t, atol=1e-6, rtol=0):
        return rre[inside], rim[inside], False
    return np.interp(t, rt, rre), np.interp(t, rt, rim), True


def plot_against_reference(t, re, im, ref, events, interruptions, radius, us, outdir, stem):
    """Overlay on the reference run, with the relative difference beneath."""
    rre, rim, interpolated = align_reference(t, ref)
    if interpolated:
        print("reference sampled differently from this run: interpolated onto its times")

    # The reference is the yardstick, so the peak that normalises the
    # residual is its own. Complex difference rather than the real part's:
    # it is invariant under the phase, so it draws as one smooth curve where
    # Re alone would cross zero every half cycle.
    peak = np.hypot(rre, rim).max()
    rel = np.hypot(re - rre, im - rim) / peak
    rel = np.where(rel > 0, rel, np.nan)  # log axis; identical samples are not a point
    imax = int(np.nanargmax(rel))

    tt = t * us.time

    # Wide rather than tall: the x axis carries a chirp, twelve resumption
    # events and a residual that climbs thirteen decades, and all three are
    # read along it. A 2.1 aspect also drops straight onto a slide.
    fig, (top, bottom) = plt.subplots(
        2,
        1,
        sharex=True,
        figsize=(12.6, 6.0),
        gridspec_kw={"height_ratios": [2.2, 1], "hspace": 0.08},
    )
    for ax in (top, bottom):
        mark_resumptions(ax, events, us)
    # Line for the reference, open circles for this run, one per stored
    # sample. Two line weights cannot express agreement here: matched, they
    # merge into one line; a pale thick one under a thin dark one turns the
    # reference into a halo, and a halo reads as an error band. A marker is a
    # discrete object, so it can only be read as a second series, and drawing
    # every sample makes the claim the strong one -- every point this run
    # stored lands on the published curve -- while showing the 15.36 M
    # cadence the panel below is measured at. (Dashes were the other
    # candidate and lost: on 114 samples they break at the corners and look
    # like gaps, and this figure already spends dashes on guide lines.)
    top.plot(
        tt,
        rre * us.psi4,
        color=VERMILLION,
        linewidth=2.0,
        zorder=1,
        label="reference run (480 ranks, 12 nodes)",
    )
    top.plot(
        tt,
        re * us.psi4,
        linestyle="none",
        marker="o",
        markersize=3.4,
        markerfacecolor="none",
        markeredgecolor=BLUE,
        markeredgewidth=1.0,
        zorder=2,
        label="this run (192 ranks, 1 spot node)",
    )
    top.ticklabel_format(axis="y", style="sci", scilimits=(0, 0))
    top.set_ylabel(psi4_ylabel(radius, us, prefix=r"\mathrm{Re}\,"))
    handles, labels = top.get_legend_handles_labels()
    if events:
        # One entry for all the pairs, since they are one repeated fact
        # rather than a dozen series; the label says which line is which.
        # Resumptions lead because they are what the lines are -- one pair
        # per backward step in the log. Interruptions follow in brackets when
        # the ledger can vouch for them: they are the larger number, and a
        # reader counting pairs against it should see why.
        recomputed = sum(e.t_lost - e.t_resume for e in events) * us.time
        head = f"{len(events)} resumptions"
        if interruptions is not None:
            head += f" ({interruptions} interruptions)"
        # Wrapped, because on one line this entry reaches past the merger
        # and sits on the waveform it is meant to annotate.
        handles.append(Line2D([], [], **LOST_STYLE))
        labels.append(
            f"{head}:\nlost (dashed), resumed (dotted)\n"
            rf"${fmt_value(recomputed)}\,{us.time_unit}$ recomputed"
        )
    top.legend(handles, labels, loc="upper left", frameon=False)

    bottom.semilogy(tt, rel, color=GREEN, linewidth=1.8)
    # Fourteen decades on a short panel. Ticks are laid from the ceiling
    # down, so the decade the maximum sits under is always labelled; the
    # floor is roundoff and needs no label of its own.
    lo = int(np.floor(np.log10(np.nanmin(rel))))
    hi = int(np.ceil(np.log10(np.nanmax(rel))))
    step = max(1, int(np.ceil((hi - lo) / 4)))
    bottom.set_ylim(10.0**lo, 10.0**hi)
    bottom.set_yticks(10.0 ** np.arange(hi, lo - 1, -step))
    bottom.text(
        0.02,
        0.88,
        rf"max {np.nanmax(rel):.1e} at $t = {fmt_value(tt[imax])}\,{us.time_unit}$",
        transform=bottom.transAxes,
        fontsize=11,
        color="0.35",
        va="top",
        # The early resumptions cluster exactly here; without a backing
        # the text reads through five overlapping bands.
        bbox={"facecolor": "white", "alpha": 0.75, "edgecolor": "none", "pad": 1.5},
    )
    bottom.set_xlabel(us.label("t", us.time_unit))
    bottom.set_ylabel(r"$|\Delta\Psi_4|\,/\,\max|\Psi_4|$")
    save(fig, outdir, stem)
    # The numbers as well as the picture: a talk quotes values, and deriving
    # them a second time by eye off a PDF is how a slide ends up disagreeing
    # with the figure beside it.
    dump_comparison_tsv(outdir, stem, t, re, im, rre, rim, rel, radius, us)
    dump_resumptions_tsv(outdir, f"psi4_resumptions{us.suffix}", events, interruptions, us)
    print(
        f"reference comparison: max relative difference {np.nanmax(rel):.2e} "
        f"at t = {t[imax]:.2f} M, floor {np.nanmin(rel):.1e}"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/data/run", help="synced run directory")
    ap.add_argument("--out", default="/out", help="output directory")
    ap.add_argument("--mode", default="l2_m2", help="spherical harmonic mode")
    ap.add_argument(
        "--radius", default=None, help="extraction radius label, e.g. 500.00 (default: outermost)"
    )
    ap.add_argument(
        "--reference-dir",
        default="/ref",
        help="directory holding the reference run's mp_psi4_*.asc; the comparison "
        "figure is skipped when the file is not there",
    )
    add_units_argument(ap)
    args = ap.parse_args()
    us = UNIT_SYSTEMS[args.units]

    with h5py.File(f"{args.data}/data/mp_psi4.h5", "r") as f:
        radii = sorted(
            {k.rsplit("_r", 1)[1] for k in f.keys() if k.startswith(args.mode + "_r")},
            key=float,
        )
        radius = args.radius or radii[-1]
        d = f[f"{args.mode}_r{radius}"][:]
    t, re, im = dedup_sorted(d[:, 0], d[:, 1], d[:, 2])

    apply_style()
    stem = f"psi4_{args.mode}_r{radius}{us.suffix}"
    plot_waveform(t, re, im, radius, us, args.out, stem)

    ref_path = f"{args.reference_dir}/mp_psi4_{args.mode}_r{radius}.asc"
    if not os.path.exists(ref_path):
        print(f"no reference waveform at {ref_path}; skipping the comparison figure")
        return
    rd = np.loadtxt(ref_path, ndmin=2)
    ref = dedup_sorted(rd[:, 0], rd[:, 1], rd[:, 2])
    resumptions = load_resumptions(args.data)
    plot_against_reference(
        t,
        re,
        im,
        ref,
        resumptions,
        count_interruptions(args.out, resumptions),
        radius,
        us,
        args.out,
        f"psi4_vs_reference_{args.mode}_r{radius}{us.suffix}",
    )


if __name__ == "__main__":
    main()
