# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Time-series figures: maximum rest-mass density, horizon masses, rest mass.

Three separate figures rather than one with two y-axes -- the quantities have
different scales, and a dual-axis chart invites misreading. Each carries the
coordinate merger time as a reference line so the three can be read side by
side in a talk.

--units si restates them in milliseconds, kg/m^3 and kilograms. The density
figure is the one that gains most: the initial maximum is 7.8e17 kg/m^3,
which places the star against nuclear saturation density (2.8e17 kg/m^3) for
anyone who has never met a solar mass to the minus two.
"""

import argparse
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from common import (
    BLUE,
    FIGSIZE,
    GREEN,
    MERGER_TIME,
    UNIT_SYSTEMS,
    VERMILLION,
    add_units_argument,
    apply_style,
    dedup_sorted,
    load_ah_diagnostics,
    load_scalar_asc,
    save,
)


def merger_line(ax, us):
    ax.axvline(MERGER_TIME * us.time, color="0.5", linewidth=1, linestyle="--")
    ax.annotate(
        "merger",
        xy=(MERGER_TIME * us.time, 1.0),
        xycoords=("data", "axes fraction"),
        xytext=(4, -12),
        textcoords="offset points",
        fontsize=11,
        color="0.35",
    )


def plot_rho_max(datadir, outdir, us):
    t, rho = load_scalar_asc(f"{datadir}/data/hydrobase-rho.maximum.asc")
    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.semilogy(t * us.time, rho * us.density, color=BLUE, linewidth=2.0)
    merger_line(ax, us)
    ax.set_xlabel(us.label("t", us.time_unit))
    ax.set_ylabel(us.label(r"\max\ \rho", us.density_unit))
    fig.tight_layout()
    save(fig, outdir, f"rho_max{us.suffix}")


def plot_ah_masses(datadir, outdir, us):
    fig, ax = plt.subplots(figsize=FIGSIZE)
    # Fixed identity -> fixed color: AH1 is the black hole tracked from t=0,
    # AH2 the post-merger horizon found once the star is swallowed.
    for n, color, label in ((1, BLUE, "AH1 (initial BH)"), (2, VERMILLION, "AH2 (remnant)")):
        path = f"{datadir}/BH/BH_diagnostics.ah{n}.gp"
        if not os.path.exists(path):
            continue
        t, _, _, _, m = load_ah_diagnostics(path)
        ax.plot(t * us.time, m * us.mass, color=color, linewidth=2.0, label=label)
    merger_line(ax, us)
    ax.set_xlabel(us.label("t", us.time_unit))
    ax.set_ylabel(us.label(r"M_\mathrm{irr}", us.mass_unit))
    ax.legend(loc="center left", frameon=False)
    fig.tight_layout()
    save(fig, outdir, f"ah_masses{us.suffix}")


def plot_rest_mass(datadir, outdir, us):
    # VolumeIntegrals-GRMHD: column 1 is time, column 8 the rest-mass
    # integral over the full grid (see the file's own header). Normalised to
    # its initial value, so the y axis is dimensionless in either unit
    # system: what remains outside the horizon after merger is the
    # accretion-disk material.
    data = np.loadtxt(f"{datadir}/volume_integration/volume_integrals-GRMHD.asc", ndmin=2)
    t, m = dedup_sorted(data[:, 0], data[:, 7])
    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.plot(t * us.time, m / m[0], color=GREEN, linewidth=2.0)
    merger_line(ax, us)
    ax.set_xlabel(us.label("t", us.time_unit))
    ax.set_ylabel(r"$M_0(t)\,/\,M_0(0)$")
    fig.tight_layout()
    save(fig, outdir, f"rest_mass{us.suffix}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/data/run", help="synced run directory")
    ap.add_argument("--out", default="/out", help="output directory")
    add_units_argument(ap)
    args = ap.parse_args()
    us = UNIT_SYSTEMS[args.units]

    apply_style()
    plot_rho_max(args.data, args.out, us)
    plot_ah_masses(args.data, args.out, us)
    plot_rest_mass(args.data, args.out, us)


if __name__ == "__main__":
    main()
