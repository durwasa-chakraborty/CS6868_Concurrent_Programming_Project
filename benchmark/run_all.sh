#!/usr/bin/env bash
# End-to-end benchmark pipeline:
#   1. build Java + OCaml drivers
#   2. truncate benchmark/results/summary.csv
#   3. run each driver (Java first, then OCaml) with matching CLI args
#   4. hand the CSV to plot.py to emit PNG figures under results/plots/
#
# CLI flags override the defaults below; anything after `--` is forwarded
# verbatim to both drivers (so e.g. `run_all.sh -- --only Semaphore`
# limits both sides to the Semaphore benchmarks).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT_CSV="$HERE/results/summary.csv"
PLOT_DIR="$HERE/results/plots"

THREADS="${THREADS:-1,2,4,8}"
REPEATS="${REPEATS:-3}"
WARMUP_MS="${WARMUP_MS:-1000}"
MEASURE_MS="${MEASURE_MS:-2000}"
# Fixed-N mode: each thread performs exactly OPS body invocations on the
# Semaphore/Mutex bodies (Pool/Latch/Barrier already use cycles*pairs).
# Set OPS=0 to fall back to the time-based MEASURE_MS window.
OPS="${OPS:-2000000}"

EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threads)    THREADS="$2"; shift 2;;
    --repeats)    REPEATS="$2"; shift 2;;
    --warmup-ms)  WARMUP_MS="$2"; shift 2;;
    --measure-ms) MEASURE_MS="$2"; shift 2;;
    --ops)        OPS="$2"; shift 2;;
    --)           shift; EXTRA=("$@"); break;;
    *)            EXTRA+=("$1"); shift;;
  esac
done

echo "=== building benchmarks ==="
"$HERE/java/build.sh"
"$HERE/kotlin/build.sh"
( cd "$ROOT" && dune build benchmark/ocaml )

mkdir -p "$HERE/results" "$PLOT_DIR"
rm -f "$OUT_CSV"

COMMON=(
  --out "$OUT_CSV"
  --threads "$THREADS"
  --repeats "$REPEATS"
  --warmup-ms "$WARMUP_MS"
  --measure-ms "$MEASURE_MS"
  --ops "$OPS"
)

# Printing args:
echo "ARGS: \n"
echo "${COMMON[@]}" 
echo "${EXTRA[@]+${EXTRA[@]}}"

# Running Java benchmarks
echo ""
echo "=== Java (AbstractQueueSynchronizer-backed primitives) ==="
"$HERE/java/run.sh" "${COMMON[@]}" "${EXTRA[@]+${EXTRA[@]}}"

# Running Java benchmarks
echo ""
echo "=== Kotlin (kotlinx.coroutines suspending primitives) ==="
"$HERE/kotlin/run.sh" "${COMMON[@]}" "${EXTRA[@]+${EXTRA[@]}}"

echo ""
echo "=== OCaml (SQS-backed primitives) ==="
( cd "$ROOT" && _build/default/benchmark/ocaml/bench_runner.exe "${COMMON[@]}" "${EXTRA[@]+${EXTRA[@]}}" )

echo ""
echo "=== summary written to $OUT_CSV ==="
wc -l "$OUT_CSV"

if command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== plotting ==="
  if python3 -c "import matplotlib" >/dev/null 2>&1; then
    python3 "$HERE/plot.py" "$OUT_CSV" "$PLOT_DIR"
  else
    echo "matplotlib not installed — skipping plots (pip install matplotlib)"
  fi
fi
