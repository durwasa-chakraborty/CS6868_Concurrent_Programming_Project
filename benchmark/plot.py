#!/usr/bin/env python3
"""Plot the Java vs OCaml benchmark summary.

Usage: plot.py SUMMARY_CSV OUT_DIR

Emits:
  OUT_DIR/throughput.png  — grouped bar chart at the highest common T
  OUT_DIR/scalability.png — one sub-plot per (primitive, workload), with
                            ocaml and java lines vs threads
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
            rows.append(r)
    return rows


def aggregate(rows):
    """Median throughput keyed by (implementation, primitive, workload, threads)."""
    buckets = defaultdict(list)
    for r in rows:
        key = (r["implementation"], r["primitive"], r["workload"], r["threads"])
        buckets[key].append(r["throughput_ops_s"])
    return {k: median(v) for k, v in buckets.items()}


def plot_throughput(agg, out_path):
    import matplotlib.pyplot as plt

    # Pick a headline thread count: prefer T=4 if present, else the max.
    all_t = sorted({k[3] for k in agg.keys()})
    target_t = 4 if 4 in all_t else all_t[-1]

    pairs = {}  # (primitive, workload) -> {impl: throughput}
    for (impl, prim, wl, t), th in agg.items():
        if t != target_t:
            continue
        pairs.setdefault((prim, wl), {})[impl] = th

    if not pairs:
        print("plot_throughput: no rows at T={}".format(target_t))
        return

    labels = [f"{p}\n{w}" for (p, w) in pairs]
    ocaml_vals = [pairs[k].get("ocaml", 0) for k in pairs]
    java_vals  = [pairs[k].get("java",  0) for k in pairs]

    import numpy as np
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
    print(f"wrote {out_path}")


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
    cols = 2
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(10, 3.2 * rows), squeeze=False)

    for ax, ((prim, wl), impls) in zip(axes.flat, sorted(pairs.items())):
        for impl, color in (("java", "#d46b5a"), ("ocaml", "#4a90a4")):
            series = impls.get(impl, {})
            if not series:
                continue
            xs = sorted(series.keys())
            ys = [series[t] for t in xs]
            ax.plot(xs, ys, marker="o", color=color, label=impl)
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
    fig.tight_layout(rect=[0, 0, 1, 0.97])
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
    plot_throughput(agg, os.path.join(out_dir, "throughput.png"))
    plot_scalability(agg, os.path.join(out_dir, "scalability.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
