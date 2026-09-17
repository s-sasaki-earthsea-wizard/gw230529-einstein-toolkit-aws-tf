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
"""

import argparse

import h5py
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from common import (
    BLUE,
    FIGSIZE,
    UNIT_SYSTEMS,
    VERMILLION,
    add_units_argument,
    apply_style,
    dedup_sorted,
    fmt_value,
    save,
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/data/run", help="synced run directory")
    ap.add_argument("--out", default="/out", help="output directory")
    ap.add_argument("--mode", default="l2_m2", help="spherical harmonic mode")
    ap.add_argument(
        "--radius", default=None, help="extraction radius label, e.g. 500.00 (default: outermost)"
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
    t = t * us.time
    re, im = re * us.psi4, im * us.psi4
    amp = np.hypot(re, im)
    tpk = t[amp.argmax()]

    apply_style()
    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.fill_between(t, -amp, amp, color=VERMILLION, alpha=0.15, linewidth=0)
    ax.plot(t, amp, color=VERMILLION, linewidth=1.2, label=r"$|\Psi_4|$")
    ax.plot(t, re, color=BLUE, linewidth=2.0, label=r"$\mathrm{Re}\,\Psi_4$")
    ax.axvline(tpk, color="0.5", linewidth=1, linestyle="--")
    # Force the exponent into the offset text. Psi4 is ~1e-6 in geometric
    # units and ~1e5 in SI, and matplotlib only volunteers an offset for the
    # first: left alone, the SI figure prints six-digit tick labels.
    ax.ticklabel_format(axis="y", style="sci", scilimits=(0, 0))
    ax.annotate(
        rf"peak $t={fmt_value(tpk)}\,{us.time_unit}$",
        xy=(tpk, amp.max()),
        xytext=(6, 0),
        textcoords="offset points",
        fontsize=11,
        color="0.35",
    )
    r_txt = rf"{fmt_value(float(radius) * us.length)}\,{us.length_unit}"
    ax.set_xlabel(us.label("t", us.time_unit))
    ax.set_ylabel(us.label(rf"\Psi_4^{{2,2}}\ \mathrm{{at}}\ r = {r_txt}", us.psi4_unit))
    ax.legend(loc="upper left", frameon=False)
    fig.tight_layout()
    save(fig, args.out, f"psi4_{args.mode}_r{radius}{us.suffix}")


if __name__ == "__main__":
    main()
