# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Shared style, unit systems and data loading for the post-processing figures.

Every script here reads from the synced run directory (``make fetch-results``)
and writes into an output directory; both arrive as CLI arguments with
defaults matching the bind mounts in makefiles/post.mk (/data and /out).

The ASCII readers all deduplicate on the leading iteration/time column. A run
recovered after a spot interruption rewinds to the last checkpoint and
re-emits the iterations it had already written, appending them to the same
file -- the same reason the upstream gallery's join.sh runs its gawk filter.
"""

import numpy as np

# Okabe-Ito colorblind-safe palette, assigned in fixed order (never cycled).
BLUE = "#0072B2"
VERMILLION = "#D55E00"
GREEN = "#009E73"
ORANGE = "#E69F00"

# Coordinate merger time in M_sun, from the production run (CLAUDE.md: the
# Psi4 peak at r=500 arrives at t=1213 M, minus the extraction radius).
MERGER_TIME = 713.0

FIGSIZE = (7.0, 4.2)

# ----------------------------------------------------------------------
# Unit systems
# ----------------------------------------------------------------------
# Cactus works in geometric units with G = c = M_sun = 1, which reads as
# nothing at all outside numerical relativity. Every figure is therefore
# drawn twice: once as the simulation stores it, once in the units the
# talk's audience already thinks in.
#
# The factors come from the IAU nominal solar mass parameter GM_sun rather
# than from kuibit's unitconv. kuibit divides GM_sun by G to recover a mass
# and multiplies it back, which spends precision on the one constant that is
# actually well determined; the two agree to 2.5e-5, far below anything a
# figure can show, but the time factor below is the value plot_ledger.py and
# the abstract already quote.
GM_SUN_SI = 1.32712440018e20  # m^3 s^-2, IAU 2015 nominal
C_SI = 2.99792458e8  # m/s, exact by definition
G_SI = 6.67430e-11  # m^3 kg^-1 s^-2, CODATA 2018

M_SUN_SECONDS = GM_SUN_SI / C_SI**3  # 4.9254909 us
M_SUN_METRES = GM_SUN_SI / C_SI**2  # 1476.625 m
M_SUN_KG = GM_SUN_SI / G_SI  # 1.98841e30 kg
# Geometric density is M_sun / (GM_sun/c^2)^3 = c^6 / (G (GM_sun)^2). The
# trailing 1e-3 turns kg/m^3 into the g/cm^3 that compact-object work quotes.
M_SUN_G_PER_CM3 = C_SI**6 / (G_SI * GM_SUN_SI**2) * 1e-3  # 6.1758e17


class UnitSystem:
    """Factors and axis labels for one way of presenting the data.

    Each factor multiplies a value the simulation stored in geometric units.
    Psi4 scales by time rather than by length: G = c = 1 makes the two the
    same in the code, but Psi4 is the second time derivative of a
    dimensionless strain, so its SI dimension is s^-2 and not m^-2.

    Each quantity arrives as (factor, axis label, plain name). The plain name
    is what a data file's column header can say: axis labels are LaTeX, and a
    TSV that a spreadsheet or an awk one-liner has to read cannot carry it.
    """

    def __init__(self, name, suffix, time, length, density, mass, psi4):
        self.name = name
        self.suffix = suffix
        self.time, self.time_unit, self.time_plain = time
        self.length, self.length_unit, self.length_plain = length
        self.density, self.density_unit, self.density_plain = density
        self.mass, self.mass_unit, self.mass_plain = mass
        self.psi4, self.psi4_unit, self.psi4_plain = psi4

    def label(self, symbol, unit):
        """An axis label in math mode: symbol, then its unit in brackets."""
        return rf"${symbol}\ [{unit}]$"


GEOMETRIC = UnitSystem(
    name="geom",
    suffix="",
    time=(1.0, r"M_\odot", "Msun"),
    length=(1.0, r"M_\odot", "Msun"),
    density=(1.0, r"M_\odot^{-2}", "Msun^-2"),
    mass=(1.0, r"M_\odot", "Msun"),
    psi4=(1.0, r"M_\odot^{-2}", "Msun^-2"),
)

SI = UnitSystem(
    name="si",
    suffix="_si",
    time=(M_SUN_SECONDS * 1e3, r"\mathrm{ms}", "ms"),
    length=(M_SUN_METRES / 1e3, r"\mathrm{km}", "km"),
    density=(M_SUN_G_PER_CM3, r"\mathrm{g\,cm^{-3}}", "g/cm^3"),
    # Kilograms, not solar masses: a mass is the one quantity here that has a
    # readable non-SI unit, but mixing it into an otherwise SI figure invites
    # the reader to assume the other axes are astronomers' units too.
    mass=(M_SUN_KG / 1e30, r"10^{30}\,\mathrm{kg}", "1e30 kg"),
    psi4=(M_SUN_SECONDS**-2, r"\mathrm{s^{-2}}", "s^-2"),
)

UNIT_SYSTEMS = {u.name: u for u in (GEOMETRIC, SI)}


def fmt_value(v):
    """Round a number for an annotation, keeping about three figures.

    The same quantity is a four-digit count of solar masses and a one-digit
    count of milliseconds, so the number of decimals cannot be fixed per
    call site -- it follows the magnitude instead.
    """
    return f"{v:.0f}" if abs(v) >= 100 else f"{v:.2f}"


def value_formatter(reference):
    """Fix the decimal count for a whole series from its largest value.

    fmt_value decides per number, which is right for a lone annotation and
    wrong for a set that gets read side by side: choosing individually gives
    a three-panel figure captioned "0.00", "737", "1720".
    """
    decimals = 0 if abs(reference) >= 100 else 2
    return lambda v: f"{v:.{decimals}f}"


def add_units_argument(parser):
    """Give a script the --units flag, so all of them spell it the same way."""
    parser.add_argument(
        "--units",
        default="geom",
        choices=sorted(UNIT_SYSTEMS),
        help="geometric units as Cactus stores them, or SI for the talk",
    )


def apply_style():
    """Talk-oriented matplotlib defaults: big fonts, recessive grid."""
    import matplotlib

    matplotlib.rcParams.update(
        {
            "font.size": 13,
            "axes.labelsize": 14,
            "axes.titlesize": 14,
            "legend.fontsize": 12,
            "xtick.labelsize": 12,
            "ytick.labelsize": 12,
            "axes.grid": True,
            "grid.alpha": 0.3,
            "grid.linestyle": ":",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "savefig.dpi": 300,
            "savefig.bbox": "tight",
            # Type 3 is the matplotlib default and degrades when a slide
            # scales it up; 42 embeds TrueType. Same choice as plot_ledger.py.
            "pdf.fonttype": 42,
        }
    )


def save(fig, outdir, stem):
    """Save PNG (for slides) and PDF (for anything that scales)."""
    for ext in ("png", "pdf"):
        path = f"{outdir}/{stem}.{ext}"
        fig.savefig(path)
        print(f"wrote {path}")


def dedup_sorted(key, *cols):
    """Sort by key and drop duplicate keys, keeping the first occurrence.

    Recovery re-emits iterations it had already written; the recomputed rows
    are identical, so which duplicate survives does not matter.
    """
    order = np.argsort(key, kind="stable")
    key = key[order]
    keep = np.concatenate(([True], np.diff(key) > 0))
    out = [key[keep]]
    for c in cols:
        out.append(c[order][keep])
    return out


def load_scalar_asc(path):
    """CarpetIOScalar file: columns iteration, time, value."""
    data = np.loadtxt(path, comments="#", ndmin=2)
    it, t, v = data[:, 0], data[:, 1], data[:, 2]
    it, t, v = dedup_sorted(it, t, v)
    return t, v


def load_ah_diagnostics(path):
    """AHFinderDirect BH_diagnostics.ah*.gp.

    Returns time, centroid x, centroid y, mean coordinate radius and
    irreducible mass (columns 2, 3, 4, 8 and 27 of the file, 1-based).
    """
    data = np.loadtxt(path, comments="#", ndmin=2)
    it = data[:, 0]
    it, t, cx, cy, r, m = dedup_sorted(
        it, data[:, 1], data[:, 2], data[:, 3], data[:, 7], data[:, 26]
    )
    return t, cx, cy, r, m
