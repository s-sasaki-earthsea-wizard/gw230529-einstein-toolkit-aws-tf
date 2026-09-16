# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Node timeline: what spot capacity actually gave this run, hour by hour.

One band per node, in start order, drawn from ``run_ledger.sh --tsv``. The
band is the node's whole life; the saturated part of it is evolution, and the
pale head is what every start costs before any physics happens -- boot, image
pull, a 174 GB restore from S3 and reading the checkpoint.

Colour is the node's outcome, and the distinction that matters operationally
is not interrupted-versus-finished but whether the work survived. A node
reclaimed after banking a checkpoint handed its iterations on; a node
reclaimed before one had its work thrown away, and the next node recomputed
the same stretch.

The local-time axis is the subject of the figure rather than a convenience.
The interruptions cluster, and they cluster against US Pacific working hours,
which is only legible if the axis says what time it was there. The band behind
the rows is Mon-Fri 08:00-17:00 in that zone -- the conventional definition,
not one fitted to this run.

Read the confound with it: this run moved from c7a to m7a at the same time it
moved from US morning to US evening, so the timeline cannot separate capacity
by hour from capacity by instance family. The family sits in each row label so
that the figure carries its own limit.
"""

import argparse
from datetime import datetime, timedelta, timezone

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from matplotlib.ticker import FuncFormatter

from common import BLUE, GREEN, VERMILLION, apply_style, save

# us-west-2 was on PDT for the whole of August 2026, so a fixed offset is
# exact here and spares the image a tz database.
PACIFIC = timezone(timedelta(hours=-7))
PACIFIC_LABEL = "PDT"

# Business hours are a claim about other people's behaviour, so they get the
# conventional definition rather than one fitted to this run's interruptions.
BUSINESS_HOURS = (8, 17)

# Nothing in the bootstrap log records the instance type. The line printed
# after the restore reports usable memory, which the ledger carries through,
# and the two families this run used are 384 and 768 GiB -- far enough apart
# that one threshold is unambiguous rather than a guess.
FAMILY_BY_MEMORY = ((500, "c7a"), (10**9, "m7a"))

GREY = "#6E6E78"
BAND_HEIGHT = 0.62
PALE = 0.30

# Every x value goes through this: mixing datetimes and date numbers in one
# axes leaves matplotlib to infer the units from whichever artist was drawn
# first, which is not a thing to rely on.
X = mdates.date2num


class Node:
    """One row of the ledger, plus what the rows around it imply."""

    def __init__(self, row):
        self.instance = row["instance"]
        self.reason = row["reason"]
        self.started = _iso(row["started"])
        self.ended = _iso(row["ended"])
        self.ev_started = _iso(row["evolution_started"])
        self.ev_ended = _iso(row["evolution_ended"])
        self.it_first = _int(row["iteration_first"])
        self.it_last = _int(row["iteration_last"])
        self.uptime_s = int(row["uptime_s"])
        self.evolution_s = int(row["evolution_s"])
        self.memory_gib = _int(row["memory_gib"])
        self.banked = False
        self.after_the_run = False

    @property
    def family(self):
        if self.memory_gib is None:
            return "?"
        for limit, name in FAMILY_BY_MEMORY:
            if self.memory_gib < limit:
                return name
        return "?"


def _iso(s):
    if s in ("-", ""):
        return None
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _int(s):
    return None if s in ("-", "") else int(s)


def _hm(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600}h {seconds % 3600 // 60:02d}m"


def _local_tick(value, _):
    """Hours, except at local midnight, where the day itself is the label."""
    moment = mdates.num2date(value, tz=PACIFIC)
    if moment.hour == 0:
        return moment.strftime("%a %b %-d\n00:00")
    return moment.strftime("%H:%M")


def load_ledger(path):
    """Read run_ledger.sh --tsv. Returns the nodes and the ledger's totals."""
    nodes, totals, header = [], {}, None
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("#totals"):
                for field in line.split("\t")[1:]:
                    key, _, value = field.partition("=")
                    totals[key] = int(value)
            elif line.startswith("#instance"):
                header = line.lstrip("#").split("\t")
            elif line.startswith("#") or not line:
                continue
            else:
                if header is None:
                    raise ValueError(f"{path}: rows before the header line")
                nodes.append(Node(dict(zip(header, line.split("\t")))))
    if not nodes:
        raise ValueError(f"{path}: no ledger rows")
    if not totals:
        raise ValueError(f"{path}: no #totals trailer -- regenerate with --tsv")
    return nodes, totals


def classify(nodes):
    """Decide, for each node, whether its work survived it.

    A checkpoint was banked if the node that came next resumed from a later
    iteration than this one started at. That is the only surviving evidence:
    S3 keeps two generations per slot and the rest were pruned long ago. The
    last node is judged by its exit instead -- it finished, so it wrote one.

    Anything launched after the run finished is not part of the run. On
    2026-08-29 the stopped relaunch loop was read as an expired login and a
    node was started by hand (issue #25). It belongs in the totals, because it
    cost money and wall clock, but not in the story the colours tell.
    """
    ended = False
    for i, node in enumerate(nodes):
        if ended:
            node.after_the_run = True
            continue
        if node.reason == "finished" and node.evolution_s > 0:
            node.banked = True
            ended = True
            continue
        if node.it_first is None:
            node.banked = False
            continue
        later = next((n for n in nodes[i + 1 :] if n.it_first is not None), None)
        node.banked = later is not None and later.it_first > node.it_first


def colour_of(node):
    if node.after_the_run:
        return GREY
    if node.reason == "finished":
        return GREEN
    return BLUE if node.banked else VERMILLION


def local_midnights(lo, hi):
    """Every local midnight from the one before lo up to hi."""
    day = lo.astimezone(PACIFIC).replace(hour=0, minute=0, second=0, microsecond=0)
    out = []
    while day < hi:
        out.append(day)
        day += timedelta(days=1)
    return out


def draw(nodes, totals, outdir):
    apply_style()
    # A timeline carries far more labels than a line chart of the same size,
    # so it wants smaller type than the other figures in this directory.
    matplotlib.rcParams.update(
        {
            "font.size": 11,
            "axes.labelsize": 11,
            "xtick.labelsize": 10,
            "ytick.labelsize": 10,
            "legend.fontsize": 10,
        }
    )

    lo = min(n.started for n in nodes)
    hi = max(n.ended for n in nodes)
    fig, ax = plt.subplots(figsize=(10.0, 5.8))

    # Working hours first, so every mark sits on top of them.
    for day in local_midnights(lo - timedelta(days=1), hi):
        if day.weekday() >= 5:
            continue
        ax.axvspan(
            X(day + timedelta(hours=BUSINESS_HOURS[0])),
            X(day + timedelta(hours=BUSINESS_HOURS[1])),
            color="0.55",
            alpha=0.13,
            linewidth=0,
            zorder=0,
        )
    for day in local_midnights(lo, hi):
        ax.axvline(X(day), color="0.6", linewidth=0.9, linestyle=(0, (2, 4)), zorder=1)

    drawn = []
    for row, node in enumerate(nodes):
        colour = colour_of(node)
        # The node's whole life, pale. This is what was paid for.
        ax.barh(
            row,
            X(node.ended) - X(node.started),
            left=X(node.started),
            height=BAND_HEIGHT,
            color=colour,
            alpha=PALE,
            linewidth=0,
            zorder=3,
        )
        if node.ev_started and node.ev_ended:
            ax.barh(
                row,
                X(node.ev_ended) - X(node.ev_started),
                left=X(node.ev_started),
                height=BAND_HEIGHT,
                color=colour,
                linewidth=0,
                zorder=4,
            )
        drawn.append((node, node.started, node.ended))

    finisher = next(
        (n for n in nodes if n.reason == "finished" and not n.after_the_run), None
    )
    if finisher is not None:
        ax.annotate(
            "finished · t = 1750 M",
            xy=(X(finisher.ended), nodes.index(finisher)),
            xytext=(9, 0),
            textcoords="offset points",
            va="center",
            fontsize=10,
            color=GREEN,
        )
    for node in nodes:
        if node.after_the_run:
            ax.annotate(
                "hand-launched after the run finished (#25)",
                xy=(X(node.ended), nodes.index(node)),
                xytext=(9, 0),
                textcoords="offset points",
                va="center",
                fontsize=9,
                color="0.45",
            )

    # The longest gap: capacity that nobody was awake to wait for.
    worst, at = timedelta(0), None
    for before, after in zip(nodes, nodes[1:]):
        gap = after.started - before.ended
        if gap > worst:
            worst, at = gap, (before.ended, after.started, nodes.index(after))
    if at is not None:
        ax.annotate(
            f"{_hm(worst.total_seconds())} idle",
            xy=(X(at[0] + (at[1] - at[0]) / 2), at[2] - 0.5),
            ha="center",
            va="center",
            fontsize=9.5,
            color="0.4",
            bbox=dict(facecolor="white", edgecolor="none", alpha=0.7, pad=1.5),
        )

    ax.set_ylim(len(nodes) - 0.4, -0.7)
    ax.set_yticks(range(len(nodes)))
    ax.set_yticklabels(
        [f"{i + 1:>2}  {n.family}" for i, n in enumerate(nodes)], family="monospace"
    )
    ax.set_ylabel("node, in start order")
    ax.tick_params(axis="y", length=0)
    ax.grid(False)

    pad = (hi - lo) * 0.015
    ax.set_xlim(X(lo - pad), X(hi + pad))
    ax.xaxis.set_major_locator(mdates.HourLocator(byhour=(0, 6, 12, 18), tz=PACIFIC))
    ax.xaxis.set_major_formatter(FuncFormatter(_local_tick))
    ax.set_xlabel(f"local time at the region, us-west-2 ({PACIFIC_LABEL}, UTC−7)")

    top = ax.secondary_xaxis("top")
    top.xaxis.set_major_locator(
        mdates.HourLocator(byhour=(0, 6, 12, 18), tz=timezone.utc)
    )
    top.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=timezone.utc))
    top.set_xlabel("UTC", fontsize=10, color="0.35", labelpad=5)
    top.tick_params(labelsize=9.5, colors="0.35")

    handles = [
        Patch(facecolor=VERMILLION, label="reclaimed with nothing banked"),
        Patch(facecolor=BLUE, label="reclaimed after banking a checkpoint"),
        Patch(facecolor=GREEN, label="ran to completion"),
        Patch(
            facecolor="0.55",
            alpha=0.3,
            label="US Pacific working hours (Mon–Fri "
            f"{BUSINESS_HOURS[0]:02d}–{BUSINESS_HOURS[1]:02d})",
        ),
    ]
    fig.legend(
        handles=handles,
        loc="upper left",
        bbox_to_anchor=(0.105, 0.175),
        ncol=2,
        frameon=False,
        handlelength=1.6,
        borderaxespad=0,
    )
    # The saturated/pale split is one sentence and needs no swatch: a grey one
    # would misstate it, since every band is pale in its own colour.
    fig.text(
        0.105,
        0.035,
        "Each band is the node's whole life; the pale head is start-up — boot, "
        "image pull, a 174 GB restore from S3, the checkpoint read.",
        fontsize=9.5,
        color="0.4",
    )

    duty = 100 * totals["uptime_s"] / totals["span_s"]
    compute = 100 * totals["evolution_s"] / totals["uptime_s"]
    effective = 100 * totals["evolution_s"] / totals["span_s"]
    served = sum(1 for n in nodes if not n.after_the_run)
    ax.set_title(
        f"{served} spot nodes served the run, across {_hm(totals['span_s'])} of wall clock\n"
        f"nodes up {duty:.1f}% of it  ·  evolving {compute:.1f}% of their uptime  "
        f"·  {effective:.1f}% effective",
        fontsize=11.5,
        pad=22,
    )

    # Room for two rows of legend and the caption under the x label.
    fig.subplots_adjust(left=0.115, right=0.80, top=0.845, bottom=0.30)
    save(fig, outdir, "node_timeline")
    return drawn


def verify(drawn, nodes, totals):
    """Measure every band that was drawn back against the row it came from.

    An earlier version of this chart collapsed two bands to two pixels because
    a string replace silently missed a date rollover, and nobody noticed until
    the figure was read closely. The discipline the upload script applies to
    its parfile edits applies to a plot too: a mark that does not match its
    number is a bug, so check it rather than look at it.
    """
    for node, x0, x1 in drawn:
        drawn_s = round((x1 - x0).total_seconds())
        if drawn_s != node.uptime_s:
            raise AssertionError(
                f"{node.instance}: band is {drawn_s}s, ledger says {node.uptime_s}s"
            )
    span = round(
        (max(n.ended for n in nodes) - min(n.started for n in nodes)).total_seconds()
    )
    for name, got, want in (
        ("span", span, totals["span_s"]),
        ("uptime", sum(n.uptime_s for n in nodes), totals["uptime_s"]),
        ("evolution", sum(n.evolution_s for n in nodes), totals["evolution_s"]),
        ("nodes", len(nodes), totals["nodes"]),
    ):
        if got != want:
            raise AssertionError(f"{name}: chart has {got}, ledger says {want}")
    print(f"verified {len(drawn)} bands against the ledger")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--ledger", default="/out/ledger.tsv", help="output of run_ledger.sh --tsv"
    )
    ap.add_argument("--out", default="/out", help="output directory")
    args = ap.parse_args()

    nodes, totals = load_ledger(args.ledger)
    classify(nodes)
    drawn = draw(nodes, totals, args.out)
    verify(drawn, nodes, totals)

    served = [n for n in nodes if not n.after_the_run]
    thrown = [n for n in served if not n.banked]
    print(
        f"{len(served)} nodes served the run, {len(thrown)} of them banked nothing "
        f"({_hm(sum(n.uptime_s for n in thrown))} of paid time)"
    )


if __name__ == "__main__":
    main()
