#!/usr/bin/env python3
"""Plot the Java vs OCaml benchmark summary.

Usage: plot.py SUMMARY_CSV OUT_DIR

Emits:
<<<<<<< HEAD
  OUT_DIR/throughput_T{N}.png — grouped bar chart, one per thread count
                                that appears in the CSV
  OUT_DIR/throughput.png      — alias for the highest thread count
                                (kept for back-compat with run_all.sh)
  OUT_DIR/scalability.png     — one sub-plot per (primitive, workload),
                                with ocaml and java lines vs threads
=======
  OUT_DIR/throughput.png  — grouped bar chart, one sub-plot per thread
                            count, showing every (primitive, workload)
  OUT_DIR/latency.png     — same layout, mean ns/op (apples-to-apples
                            since fixed-N ensures equal work)
  OUT_DIR/scalability.png — one sub-plot per (primitive, workload), with
                            ocaml and java lines vs threads
>>>>>>> 25b56ea (REFACTOR: Added benchmark for kotlin)
"""
from __future__ import annotations

import csv
import os
import sys
from collections import defaultdict
from statistics import median


def read_rows(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            r["threads"] = int(r["threads"])
            r["throughput_ops_s"] = float(r["throughput_ops_s"])
            r["mean_latency_ns"]  = float(r["mean_latency_ns"])
            rows.append(r)
    return rows


def aggregate(rows):
    """Median throughput & latency keyed by (impl, primitive, workload, threads)."""
    buckets = defaultdict(lambda: {"th": [], "ns": []})
    for r in rows:
        key = (r["implementation"], r["primitive"], r["workload"], r["threads"])
        buckets[key]["th"].append(r["throughput_ops_s"])
        buckets[key]["ns"].append(r["mean_latency_ns"])
    return {
        k: {"th": median(v["th"]), "ns": median(v["ns"])}
        for k, v in buckets.items()
    }


IMPL_STYLE = [
    ("java",   "java (AQS)",          "#d46b5a"),
    ("kotlin", "kotlin (coroutines)", "#9d72b8"),
    ("ocaml",  "ocaml (SQS)",         "#4a90a4"),
]


def _per_t_grid(agg, metric, out_path, title, ylabel, log_y=True):
    """One sub-plot per thread count, grouped bars per (primitive, workload)
    showing every implementation present in the CSV.  Captures every
    (impl, prim, wl, T) data point."""
    import matplotlib.pyplot as plt
    import numpy as np

    impls  = [i for (i, _, _) in IMPL_STYLE if any(k[0] == i for k in agg.keys())]
    styles = {i: (lbl, c) for (i, lbl, c) in IMPL_STYLE}
    all_t  = sorted({k[3] for k in agg.keys()})
    all_pw = sorted({(k[1], k[2]) for k in agg.keys()})
    if not all_t or not all_pw or not impls:
        print(f"_per_t_grid({metric}): no data")
        return

    cols = 2 if len(all_t) >= 2 else 1
    rows = (len(all_t) + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=(max(9, 1.6 * len(all_pw)), 3.5 * rows),
                             squeeze=False)

    n_impl = len(impls)
    group_width = 0.8
    bar_width   = group_width / n_impl
    x = np.arange(len(all_pw))
    labels = [f"{p}\n{w}" for (p, w) in all_pw]

    for ax, t in zip(axes.flat, all_t):
        for j, impl in enumerate(impls):
            vals = [agg.get((impl, p, w, t), {}).get(metric, 0) for (p, w) in all_pw]
            offset = (j - (n_impl - 1) / 2) * bar_width
            lbl, color = styles[impl]
            ax.bar(x + offset, vals, bar_width, label=lbl, color=color)
        if log_y:
            ax.set_yscale("log")
        ax.set_ylabel(ylabel, fontsize=9)
        ax.set_title(f"T = {t}", fontsize=10)
        ax.set_xticks(x)
        ax.set_xticklabels(labels, rotation=25, ha="right", fontsize=7)
        ax.grid(True, axis="y", alpha=0.3)
        ax.legend(fontsize=8)

    for ax in axes.flat[len(all_t):]:
        ax.axis("off")

    fig.suptitle(title)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(out_path, dpi=120)
    print(f"wrote {out_path}")


<<<<<<< HEAD
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

    # Stable ordering so the bars line up across the per-T charts.
    keys = sorted(pairs.keys())
    labels = [f"{p}\n{w}" for (p, w) in keys]
    ocaml_vals = [pairs[k].get("ocaml", 0) for k in keys]
    java_vals  = [pairs[k].get("java",  0) for k in keys]

    x = np.arange(len(labels))
    width = 0.38

    fig, ax = plt.subplots(figsize=(max(8, 1.1 * len(labels)), 5))
    ax.bar(x - width/2, java_vals,  width, label="java (AQS)",  color="#d46b5a")
    ax.bar(x + width/2, ocaml_vals, width, label="ocaml (SQS)", color="#4a90a4")
    ax.set_yscale("log")
    ax.set_ylabel("throughput (ops/s)  [log]")
    ax.set_title(f"Throughput at T={target_t} — Java AQS vs OCaml SQS")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=20, ha="right", fontsize=8)
    ax.legend()
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    print(f"wrote {out_path}")
=======
def plot_throughput(agg, out_path):
    _per_t_grid(agg, "th", out_path,
                "Throughput — Java AQS / Kotlin coroutines / OCaml SQS "
                "(all thread counts)",
                "throughput (ops/s)  [log]", log_y=True)


def plot_latency(agg, out_path):
    _per_t_grid(agg, "ns", out_path,
                "Mean latency — Java AQS / Kotlin coroutines / OCaml SQS "
                "(all thread counts)",
                "ns / op  [log]", log_y=True)
>>>>>>> 25b56ea (REFACTOR: Added benchmark for kotlin)


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
    for (impl, prim, wl, t), v in agg.items():
        pairs[(prim, wl)][impl][t] = v["th"]

    n = len(pairs)
    if n == 0:
        print("plot_scalability: no data")
        return
    cols = 2
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(10, 3.2 * rows), squeeze=False)

    for ax, ((prim, wl), impls) in zip(axes.flat, sorted(pairs.items())):
        for impl, lbl, color in IMPL_STYLE:
            series = impls.get(impl, {})
            if not series:
                continue
            xs = sorted(series.keys())
            ys = [series[t] for t in xs]
            ax.plot(xs, ys, marker="o", color=color, label=lbl)
        ax.set_title(f"{prim} — {wl}", fontsize=9)
        ax.set_xlabel("threads")
        ax.set_ylabel("ops/s")
        ax.set_yscale("log")
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8)
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
    agg = aggregate(rows)
<<<<<<< HEAD
    plot_throughput(agg, out_dir)
=======
    plot_throughput(agg, os.path.join(out_dir, "throughput.png"))
    plot_latency(agg,    os.path.join(out_dir, "latency.png"))
>>>>>>> 25b56ea (REFACTOR: Added benchmark for kotlin)
    plot_scalability(agg, os.path.join(out_dir, "scalability.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
