#!/usr/bin/env bash
# End-to-end benchmark pipeline:
#   1. build Java + OCaml drivers (and Kotlin if WITH_KOTLIN=1)
#   2. truncate benchmark/results/summary.csv
#   3. run each driver (Java -> OCaml [-> Kotlin]) with matching CLI args
#   4. hand the CSV to plot.py to emit PNG figures under results/plots/
#
# CLI flags override the defaults below; anything after `--` is forwarded
# verbatim to all drivers (so e.g. `run_all.sh -- --only Semaphore`
# limits every side to the Semaphore benchmarks).
#
# Env knobs:
#   WITH_KOTLIN=1     also build & run benchmark/kotlin/run.sh after the
#                     Java/OCaml passes.  Kotlin only covers the Mutex,
#                     Semaphore, and BlockingQueuePool primitives — it has
#                     no suspending counterparts for BlockingStackPool,
#                     CountDownLatch, or Barrier; plot.py drops those rows
#                     from the cross-impl charts when Kotlin data is
#                     present.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT_CSV="$HERE/results/summary.csv"
PLOT_DIR="$HERE/results/plots"

THREADS="${THREADS:-1,2,4,8}"
REPEATS="${REPEATS:-3}"
WARMUP_MS="${WARMUP_MS:-1000}"
MEASURE_MS="${MEASURE_MS:-2000}"
WITH_KOTLIN="${WITH_KOTLIN:-}"

EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threads)    THREADS="$2"; shift 2;;
    --repeats)    REPEATS="$2"; shift 2;;
    --warmup-ms)  WARMUP_MS="$2"; shift 2;;
    --measure-ms) MEASURE_MS="$2"; shift 2;;
    --)           shift; EXTRA=("$@"); break;;
    *)            EXTRA+=("$1"); shift;;
  esac
done

echo "=== building benchmarks ==="
"$HERE/java/build.sh"
( cd "$ROOT" && dune build benchmark/ocaml )
if [[ "$WITH_KOTLIN" == "1" ]]; then
  "$HERE/kotlin/build.sh"
fi

mkdir -p "$HERE/results" "$PLOT_DIR"
rm -f "$OUT_CSV"

COMMON=(
  --out "$OUT_CSV"
  --threads "$THREADS"
  --repeats "$REPEATS"
  --warmup-ms "$WARMUP_MS"
  --measure-ms "$MEASURE_MS"
)

# Printing args:
echo "ARGS: \n"
echo "${COMMON[@]}" 
echo "${EXTRA[@]+${EXTRA[@]}}"

# Running Java benchmarks
echo ""
echo "=== Java (AbstractQueueSynchronizer-backed primitives) ==="
"$HERE/java/run.sh" "${COMMON[@]}" "${EXTRA[@]+${EXTRA[@]}}"

# Running OCaml benchmarks
echo ""
echo "=== OCaml (SQS-backed primitives) ==="
( cd "$ROOT" && _build/default/benchmark/ocaml/bench_runner.exe "${COMMON[@]}" "${EXTRA[@]+${EXTRA[@]}}" )

if [[ "$WITH_KOTLIN" == "1" ]]; then
  echo ""
  echo "=== Kotlin (kotlinx.coroutines primitives) ==="
  "$HERE/kotlin/run.sh" "${COMMON[@]}" "${EXTRA[@]+${EXTRA[@]}}"
fi

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
