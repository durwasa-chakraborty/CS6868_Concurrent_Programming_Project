# CS6868 Concurrent Programming Project — Segment Queue Synchronizer
# Makefile

.PHONY: all build clean help \
        test test-smoke test-lin-harness test-qcheck-lin test-manual \
        smoke cross-domain-smoke \
        lin-semaphore lin-latch lin-barrier lin-pool \
        qcheck-lin-semaphore qcheck-lin-latch \
        manual-semaphore manual-latch manual-barrier manual-pool manual-mutex

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

all: build

build:
	dune build

clean:
	dune clean

# -----------------------------------------------------------------------------
# Top-level aggregates
# -----------------------------------------------------------------------------

# [test] runs every registered (test ...) stanza via dune.  This covers the
# Task 3 Lin_harness tests, the Task 4 qcheck-lin tests, and the Task 4
# manual tests.  The smoke tests (Task 2) are (executable)s, not (test)s,
# so they are invoked separately under [test-smoke].
test: test-smoke test-lin-harness test-qcheck-lin test-manual

test-smoke: smoke cross-domain-smoke

test-lin-harness: lin-semaphore lin-latch lin-barrier lin-pool

test-qcheck-lin: qcheck-lin-semaphore qcheck-lin-latch

test-manual: manual-semaphore manual-latch manual-barrier manual-pool manual-mutex

# -----------------------------------------------------------------------------
# Task 2 — smoke tests
# -----------------------------------------------------------------------------

smoke:
	@echo "=== Task 2: smoke_test ==="
	dune exec test/smoke_test.exe

cross-domain-smoke:
	@echo "=== Task 2: cross_domain_smoke ==="
	dune exec test/cross_domain_smoke.exe

# -----------------------------------------------------------------------------
# Task 3 — hand-rolled linearisability tests (Lin_harness-based)
# -----------------------------------------------------------------------------

lin-semaphore:
	@echo "=== Task 3: Semaphore lincheck ==="
	dune exec test/semaphore_lin_test.exe

lin-latch:
	@echo "=== Task 3: Count_down_latch lincheck ==="
	dune exec test/count_down_latch_lin_test.exe

lin-barrier:
	@echo "=== Task 3: Barrier lincheck ==="
	dune exec test/barrier_lin_test.exe

lin-pool:
	@echo "=== Task 3: Blocking_pool lincheck (queue + stack) ==="
	dune exec test/blocking_pool_lin_test.exe

# -----------------------------------------------------------------------------
# Task 4 — qcheck-lin DSL linearisability tests (non-blocking subset)
# -----------------------------------------------------------------------------

qcheck-lin-semaphore:
	@echo "=== Task 4: qcheck-lin Semaphore ==="
	dune exec test/qcheck_lin_semaphore.exe

qcheck-lin-latch:
	@echo "=== Task 4: qcheck-lin Count_down_latch ==="
	dune exec test/qcheck_lin_count_down_latch.exe

# -----------------------------------------------------------------------------
# Task 4 — manual concurrent scenario tests
# -----------------------------------------------------------------------------

manual-semaphore:
	@echo "=== Task 4: manual Semaphore scenarios ==="
	dune exec test/semaphore_manual_test.exe

manual-latch:
	@echo "=== Task 4: manual Count_down_latch scenarios ==="
	dune exec test/count_down_latch_manual_test.exe

manual-barrier:
	@echo "=== Task 4: manual Barrier scenarios ==="
	dune exec test/barrier_manual_test.exe

manual-pool:
	@echo "=== Task 4: manual blocking-pool scenarios (queue + stack) ==="
	dune exec test/blocking_pool_manual_test.exe

manual-mutex:
	@echo "=== Task 4: manual Mutex scenarios ==="
	dune exec test/mutex_manual_test.exe

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help:
	@echo "Build:"
	@echo "  make build                 Compile the project"
	@echo "  make clean                 Remove build artifacts"
	@echo ""
	@echo "Aggregate targets:"
	@echo "  make test                  Run every test (smoke + lincheck + manual)"
	@echo "  make test-smoke            Task 2 smoke tests"
	@echo "  make test-lin-harness      Task 3 Lin_harness lincheck tests"
	@echo "  make test-qcheck-lin       Task 4 qcheck-lin DSL tests"
	@echo "  make test-manual           Task 4 manual scenario tests"
	@echo ""
	@echo "Individual tests — Task 2 (smoke):"
	@echo "  make smoke                 sqs_effects basic smoke"
	@echo "  make cross-domain-smoke    Semaphore across two domains"
	@echo ""
	@echo "Individual tests — Task 3 (Lin_harness):"
	@echo "  make lin-semaphore         Semaphore(1) / Semaphore(2)"
	@echo "  make lin-latch             Count_down_latch(1) / (2)"
	@echo "  make lin-barrier           Barrier(1) / (2) / (3)"
	@echo "  make lin-pool              BlockingQueuePool / BlockingStackPool"
	@echo ""
	@echo "Individual tests — Task 4 (qcheck-lin DSL):"
	@echo "  make qcheck-lin-semaphore  try_acquire / release / available_permits"
	@echo "  make qcheck-lin-latch      count_down / remaining"
	@echo ""
	@echo "Individual tests — Task 4 (manual scenarios):"
	@echo "  make manual-semaphore      mutual excl, cross-domain wakeup, stress"
	@echo "  make manual-latch          await before/after fire, multiple awaiters"
	@echo "  make manual-barrier        rendezvous, excess arrivals"
	@echo "  make manual-pool           FIFO/LIFO order, no lost items, stress"
	@echo "  make manual-mutex          mutual excl, cross-domain wakeup"
