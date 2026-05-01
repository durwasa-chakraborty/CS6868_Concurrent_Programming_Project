# CS6868 Concurrent Programming Project — Segment Queue Synchronizer

A port of the **Cancellable Queue Synchronizer (CQS)** framework
(Koval et al., 2023) from Kotlin to **OCaml 5** on top of the
[Eio](https://github.com/ocaml-multicore/eio) fibre scheduler, with
six synchronization primitives (Mutex, Semaphore, Count-Down Latch,
Barrier, Blocking Queue Pool, Blocking Stack Pool), a five-layer test
suite (manual lin-harness, `qcheck-lin`, `qcheck-stm`, hand-written
multi-domain scenarios, ThreadSanitizer), and a cross-language
benchmark suite against `java.util.concurrent.AbstractQueueSynchronizer`
and `kotlinx.coroutines`.

- [Link to the Video](https://drive.google.com/file/d/1ybdBYRyyArXw9-euwXhEaEYbDQQnqNxv/view?usp=sharing)
- [Link to the Report](https://github.com/durwasa-chakraborty/CS6868_Concurrent_Programming_Project/blob/main/report/main.pdf)

## Project structure

```
.
├── lib/                          Core SQS engine
│   ├── sqs_effects.ml            Cell state machine, segments, suspend/resume
│   ├── sqs_effects.mli           Public interface (cell internals concealed)
│   └── light_thread.ml           Eio-backed domain-safe suspendable fibre
│
├── implementations/              Primitives built on top of the SQS core
│   ├── mutex.ml                  TTAS fast path + SQS slow path (barging)
│   ├── semaphore.ml              FAA + SQS (Smart cancellation)
│   ├── count_down_latch.ml       DONE_BIT signalling (Smart cancellation)
│   ├── barrier.ml                One-shot rendezvous (Simple cancellation)
│   ├── blocking_queue_pool.ml    FAA + flat array (FIFO)
│   └── blocking_stack_pool.ml    FAA + Treiber stack (LIFO)
│
├── test/                         Five-layer correctness suite
│   ├── smoke_test.ml             Single-domain smoke
│   ├── cross_domain_smoke.ml     Two-domain handoff smoke
│   ├── lin_harness.ml            Hand-rolled backtracking lin checker
│   ├── *_lin_test.ml             Per-primitive Spec modules for lin_harness
│   ├── qcheck_lin_*.ml           qcheck-lin DSL (non-blocking subset)
│   ├── qcheck_stm_*.ml           qcheck-stm sequential + concurrent
│   ├── *_manual_test.ml          Adversarial-timing scenarios
│   ├── tsan_template/            ThreadSanitizer harness scaffolding
│   └── kotlin/                   Original Kotlin Lincheck source (reference)
│
├── benchmark/                    Cross-language benchmark suite
│   ├── README.md                 Workload table and harness details
│   ├── run_all.sh                Build + run + plot pipeline
│   ├── plot.py                   matplotlib → throughput.png / scalability.png
│   ├── ocaml/                    OCaml driver (dune, bench.ml, bench_runner.ml)
│   ├── java/                     Java driver (build.sh, run.sh, src/)
│   ├── kotlin/                   Kotlin driver (build.sh, run.sh, src/, lib/)
│   └── results/                  summary.csv + plots/*.png
│
├── report/                       LaTeX report and figures
│   ├── main.tex                  Source
│   ├── main.pdf                  Compiled report
│   ├── references.bib
│   ├── figures/                  state diagram, latency/throughput plots
│   └── *_tsan.log                Per-test TSAN logs
│
├── Makefile                      Build/test/bench targets (see `make help`)
├── dune-project                  Project + opam metadata
├── CLAUDE.md                     Task list
├── SQS.md                        SQS design notes
├── CqsLincheck_Explained.md      Notes on the original Kotlin Lincheck suite
└── README.md                     (this file)
```

## Dependencies

- **OCaml 5.2+** with the opam packages declared in `dune-project`:
  `dune ≥ 3.21`, `eio ≥ 1.3`, `eio_main ≥ 1.3`, `ppx_expect`,
  `qcheck-core`, `qcheck-lin`, `qcheck-stm`.
- **JDK 17+** (tested on OpenJDK 21) on `$PATH` for the Java
  benchmark side (`javac`, `java`).
- **Kotlin 2.x compiler** (`kotlinc`) on `$PATH`, only when running
  with `WITH_KOTLIN=1`. The runtime jars (`kotlin-stdlib`,
  `kotlinx-coroutines-core-jvm`, `annotations`) are vendored under
  `benchmark/kotlin/lib/`, so no Maven/Gradle setup is needed.
- **Python 3 + matplotlib** for `benchmark/plot.py`
  (`pip install matplotlib`). If matplotlib is missing, the bench
  pipeline still emits `summary.csv` and just skips plotting.
- **OCaml 5.4.0+tsan switch** (optional) for the ThreadSanitizer
  sweep — `opam switch create 5.4.0+tsan`.

## Building

```bash
# install OCaml deps (one-time, into the active opam switch)
opam install . --deps-only --with-test

# compile the library + primitives + test executables
make build         # equivalent to: dune build
make clean         # equivalent to: dune clean
```

## Running the tests

The `Makefile` exposes one target per layer; `make test` runs them all.

```bash
make test                 # smoke + lin-harness + qcheck-lin + manual

# Layer-by-layer:
make test-smoke           # Task 2: smoke + cross-domain smoke
make test-lin-harness     # Task 3: hand-rolled lin checker (semaphore,
                          #         latch, barrier, queue/stack pool)
make test-qcheck-lin      # Task 4: qcheck-lin DSL (non-blocking subset)
make test-manual          # Task 4: per-primitive adversarial scenarios

# Individual primitives (selection):
make lin-semaphore        make manual-mutex
make lin-latch            make manual-pool
make qcheck-lin-latch     make manual-barrier
```

Run `make help` for the complete target list.

### ThreadSanitizer sweep

Activate the TSAN switch and rerun the suite:

```bash
opam switch 5.4.0+tsan
opam install . --deps-only --with-test
make test                 # binaries are auto-instrumented (-fsanitize=thread)
```

Per-test logs are preserved under `report/*_tsan.log`; the
human-readable diagnosis is in `report/TSAN_REPORT_tsan.md`.

## Running the benchmarks

The benchmark pipeline builds matched drivers for each implementation,
runs a six-workload × six-primitive × thread-count sweep, writes a
single CSV (`benchmark/results/summary.csv`), and regenerates
matplotlib plots under `benchmark/results/plots/`.

```bash
# Java + OCaml only (default — reproduces the baseline byte-for-byte)
make bench

# Also include kotlinx.coroutines
make bench WITH_KOTLIN=1

# Stages:
make bench-build               # compile drivers
make bench-build WITH_KOTLIN=1 # ditto + Kotlin
make bench-run                 # run sweep, write summary.csv
make bench-plot                # regenerate PNGs from existing summary
make bench-clean               # rm classes/ + results/
```

Custom thread counts, repeats, and primitive subsets are forwarded
straight to every driver:

```bash
bash benchmark/run_all.sh --threads 1,2,4 --repeats 5 -- --only Semaphore,Mutex
WITH_KOTLIN=1 bash benchmark/run_all.sh --threads 1,2,4 --repeats 5
```

CSV schema (one row per `(impl, primitive, workload, threads, repeat)`):

```
implementation,primitive,workload,threads,ops,duration_s,throughput_ops_s,mean_latency_ns,repeat
```

The workload table, primitive mapping, and reading-the-numbers notes
live in [`benchmark/README.md`](benchmark/README.md).

## References

- Nikita Koval, Dmitry Khalanskiy, Dan Alistarh.
  *CQS: A Formally-Verified Framework for Fair and Abortable
  Synchronization.* PLDI 2023.
- Doug Lea. *The java.util.concurrent Synchronizer Framework.* 2005.
- KC Sivaramakrishnan et al.
  *Retrofitting Effect Handlers onto OCaml.* PLDI 2021.
- [Eio](https://github.com/ocaml-multicore/eio) — effects-based direct-style
  IO library for OCaml 5.
- [`qcheck-lin` / `qcheck-stm`](https://github.com/ocaml-multicore/multicoretests)
  — property-based concurrency testing for OCaml.

## Project documents

- Report: [`report/main.pdf`](report/main.pdf)
  ([source](report/main.tex))
- Design notes: [`SQS.md`](SQS.md)
- Kotlin Lincheck reference: [`CqsLincheck_Explained.md`](CqsLincheck_Explained.md)

