#!/usr/bin/env python3
"""Plot the Java vs OCaml (vs Kotlin) benchmark summary.

Usage: plot.py SUMMARY_CSV OUT_DIR

Emits:
  OUT_DIR/throughput_T{N}.png — grouped bar chart, one per thread count
                                that appears in the CSV
  OUT_DIR/throughput.png      — alias for the highest thread count
                                (kept for back-compat with run_all.sh)
  OUT_DIR/scalability.png     — one sub-plot per (primitive, workload),
                                with one line per implementation vs threads

When the CSV contains Kotlin rows, the BlockingStackPool, CountDownLatch(1),
and Barrier primitives are dropped before plotting: kotlinx.coroutines does
not ship suspending counterparts for these, so the cross-impl bars/lines
would be missing the Kotlin column and skew the comparison.
"""
from __future__ import annotations

import csv
import os
import sys
from collections import defaultdict
from statistics import median


# Implementations the plot knows how to render, in legend order.
# Anything else in the CSV is silently ignored.
IMPL_STYLE = [
    ("java",   "java (AQS)",          "#d46b5a"),
    ("kotlin", "kotlin (coroutines)", "#9d72b8"),
    ("ocaml",  "ocaml (SQS)",         "#4a90a4"),
]

# Primitives without a kotlinx.coroutines counterpart — dropped only when
# Kotlin rows are present, so Java-only / OCaml-only runs still show them.
KOTLIN_GAP_PRIMITIVES = {"BlockingStackPool", "CountDownLatch(1)", "Barrier"}


def read_rows(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            r["threads"] = int(r["threads"])
            r["throughput_ops_s"] = float(r["throughput_ops_s"])
            rows.append(r)
    return rows


def filter_for_kotlin(rows):
    """If any Kotlin rows are present, drop primitives Kotlin can't model
    so the cross-impl charts compare apples to apples."""
    has_kotlin = any(r["implementation"] == "kotlin" for r in rows)
    if not has_kotlin:
        return rows
    return [r for r in rows if r["primitive"] not in KOTLIN_GAP_PRIMITIVES]


def aggregate(rows):
    """Median throughput keyed by (implementation, primitive, workload, threads)."""
    buckets = defaultdict(list)
    for r in rows:
        key = (r["implementation"], r["primitive"], r["workload"], r["threads"])
        buckets[key].append(r["throughput_ops_s"])
    return {k: median(v) for k, v in buckets.items()}


def _impls_present(agg):
    """IMPL_STYLE entries that actually appear in the aggregated data,
    in canonical legend order."""
    seen = {k[0] for k in agg.keys()}
    return [t for t in IMPL_STYLE if t[0] in seen]


def plot_throughput_at(agg, target_t, out_path):
    import matplotlib.pyplot as plt
    import numpy as np

    pairs = {}  # (primitive, workload) -> {impl: throughput}
    for (impl, prim, wl, t), th in agg.items():
        if t != target_t:
            continue
        pairs.setdefault((prim, wl), {})[impl] = th

    if not pairs:
        print(f"plot_throughput: no rows at T={target_t}")
        return

    impls = _impls_present(agg)
    if not impls:
        print(f"plot_throughput: no known impls at T={target_t}")
        return

    keys = sorted(pairs.keys())
    labels = [f"{p}\n{w}" for (p, w) in keys]

    x = np.arange(len(labels))
    n_impl = len(impls)
    group_width = 0.8
    width = group_width / n_impl

    fig, ax = plt.subplots(figsize=(max(8, 1.1 * len(labels)), 5))
    for j, (impl_id, impl_lbl, color) in enumerate(impls):
        vals = [pairs[k].get(impl_id, 0) for k in keys]
        offset = (j - (n_impl - 1) / 2) * width
        ax.bar(x + offset, vals, width, label=impl_lbl, color=color)
    ax.set_yscale("log")
    ax.set_ylabel("throughput (ops/s)  [log]")
    title_impls = " vs ".join(lbl for _, lbl, _ in impls)
    ax.set_title(f"Throughput at T={target_t} — {title_impls}")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=20, ha="right", fontsize=8)
    ax.legend()
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    print(f"wrote {out_path}")


def plot_throughput(agg, out_dir):
    """Emit one bar chart per thread count, plus a stable throughput.png
       alias pointing at the highest T (for back-compat with run_all.sh)."""
    all_t = sorted({k[3] for k in agg.keys()})
    if not all_t:
        print("plot_throughput: no data")
        return
    for t in all_t:
        plot_throughput_at(agg, t, os.path.join(out_dir, f"throughput_T{t}.png"))
    plot_throughput_at(agg, all_t[-1], os.path.join(out_dir, "throughput.png"))


def plot_scalability(agg, out_path):
    import matplotlib.pyplot as plt

    pairs = defaultdict(lambda: defaultdict(dict))
    # pairs[(primitive, workload)][impl][threads] = throughput
    for (impl, prim, wl, t), th in agg.items():
        pairs[(prim, wl)][impl][t] = th

    n = len(pairs)
    if n == 0:
        print("plot_scalability: no data")
        return
    impls = _impls_present(agg)

    cols = 2
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(10, 3.2 * rows), squeeze=False)

    for ax, ((prim, wl), per_impl) in zip(axes.flat, sorted(pairs.items())):
        for impl_id, impl_lbl, color in impls:
            series = per_impl.get(impl_id, {})
            if not series:
                continue
            xs = sorted(series.keys())
            ys = [series[t] for t in xs]
            ax.plot(xs, ys, marker="o", color=color, label=impl_lbl)
        ax.set_title(f"{prim} — {wl}", fontsize=9)
        ax.set_xlabel("threads")
        ax.set_ylabel("ops/s")
        ax.set_yscale("log")
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8)
    # Hide any unused sub-plots.
    for ax in axes.flat[len(pairs):]:
        ax.axis("off")
    fig.suptitle("Scalability: throughput vs thread count")
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(out_path, dpi=120)
    print(f"wrote {out_path}")


def main(argv):
    if len(argv) != 3:
        print("usage: plot.py SUMMARY_CSV OUT_DIR", file=sys.stderr)
        return 2
    csv_path, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    rows = read_rows(csv_path)
    if not rows:
        print("no rows in CSV", file=sys.stderr)
        return 1
    rows = filter_for_kotlin(rows)
    agg = aggregate(rows)
    plot_throughput(agg, out_dir)
    plot_scalability(agg, os.path.join(out_dir, "scalability.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
