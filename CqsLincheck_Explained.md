# CqsLincheck — Test Suite Analysis & OCaml Mapping

`test/CqsLincheck.kt` is the **correctness test suite for the Cancellable Queue Synchronizer (CQS/SQS)** in the Kotlin reference implementation.  It serves two purposes simultaneously:

1. **Correctness verification** — it runs the [LinCheck](https://github.com/JetBrains/lincheck) framework against every combination of resume mode (SYNC/ASYNC) and cancellation mode (SIMPLE/SMART), using both stress testing and exhaustive model checking.
2. **API richness check** — each test fixture is a complete, usable synchronisation primitive (Semaphore, CountDownLatch, Barrier, BlockingPool).  If CQS is expressive enough to build all of these cleanly, it has the right API surface.

This document maps every test to its equivalent concept in the OCaml port (`lib/sqs_effects.ml` + `lib/light_thread.ml`).

---

## 1. What is LinCheck?

LinCheck is a JVM testing framework that checks **linearizability** — the property that every concurrent execution of a data structure is equivalent to *some* sequential execution of the same operations.

It works in two modes:

| Mode | Strategy |
|------|----------|
| **Stress** | Runs many random concurrent schedules, records outcomes, checks them against a sequential specification. |
| **Model checking** | Enumerates all possible thread interleavings up to a bound, verifying each one. Also checks **obstruction freedom** when `checkObstructionFreedom()` is set. |

A typical test class in the file looks like this:

```kotlin
class AsyncSemaphore1LincheckTest
    : AsyncSemaphoreLincheckTestBase(AsyncSemaphore(1), SemaphoreUnboundedSequential1::class)
```

- `AsyncSemaphore(1)` — the implementation under test.
- `SemaphoreUnboundedSequential1` — the **sequential specification**: a simple, obviously-correct single-threaded version that LinCheck uses as the ground truth.
- Methods annotated with `@Operation` are the operations LinCheck will interleave concurrently.

---

## 2. Test Suites in Order

### 2.1 Semaphores (lines 39–231)

Three implementations with increasing sophistication, exercising the two axes of CQS configuration.

#### `AsyncSemaphore` — ASYNC + SIMPLE

```kotlin
override val resumeMode get() = ASYNC
// cancellationMode defaults to SIMPLE
```

*acquire* decrements the permit counter; suspends if it goes negative.
*release* increments and calls `resume(Unit)` in a retry loop (simple cancellation means a cancelled waiter causes the release to retry from scratch).

| LinCheck test | Permits |
|---|---|
| `AsyncSemaphore1LincheckTest` | 1 |
| `AsyncSemaphore2LincheckTest` | 2 |

**Operations exercised:** `acquire()` (suspending), `release()` (non-suspending, may throw `IllegalStateException` in the sequential spec).

#### `AsyncSemaphoreSmart` — ASYNC + SMART

```kotlin
override val resumeMode get() = ASYNC
override val cancellationMode get() = SMART
```

Adds `onCancellation()`: when an `acquire` is cancelled, the permit counter is incremented back, and the method returns `p < 0` to tell CQS whether a concurrent `release` is already on its way.  `returnValue()` calls `release()` to handle the prompt-cancellation path.

| LinCheck test | Permits |
|---|---|
| `AsyncSemaphoreSmart1LincheckTest` | 1 |
| `AsyncSemaphoreSmart2LincheckTest` | 2 |

#### `SyncSemaphoreSmart` — SYNC + SMART

```kotlin
override val resumeMode get() = SYNC
override val cancellationMode get() = SMART
```

SYNC mode adds spin-wait handshaking between `resume` and `suspend`.  This makes `tryAcquire` linearizable — a TOCTOU-safe permit grab that cannot overlap with a suspension.  `returnValue(Boolean)` simply calls `release()`.

| LinCheck test | Notes |
|---|---|
| `SyncSemaphoreSmart1LincheckTest` | `checkObstructionFreedom(false)` — SYNC inherently blocks, so OBF is disabled |
| `SyncSemaphoreSmart2LincheckTest` | same |

**Extra operation:** `tryAcquire()` — a non-suspending CAS loop on the permit counter.

---

### 2.2 CountDownLatch (lines 248–356)

A latch initialised to *count*; `countDown()` decrements it, and `await()` suspends until it reaches zero.  A `DONE_MARK` bit in the waiter counter atomically signals "the count reached zero; no more suspensions".

#### `CountDownLatch` — ASYNC + SIMPLE

Resumption works by calling `resume(Unit)` once per registered waiter when the count hits zero.  Cancelled waiters leave ghost entries that the resumption loop must iterate over — linear in *total* waiters, including cancelled ones.

#### `CountDownLatchSmart` — ASYNC + SMART

`onCancellation()` decrements the waiter counter; if `DONE_MARK` is not yet set the cancellation is self-contained.  The resumption loop now runs in *O(live waiters)* rather than *O(all waiters)*.

| LinCheck tests | Initial count |
|---|---|
| `CountDownLatch1LincheckTest`, `CountDownLatchSmart1LincheckTest` | 1 |
| `CountDownLatch2LincheckTest`, `CountDownLatchSmart2LincheckTest` | 2 |

**Operations:** `countDown()`, `await()`, `remaining()`.

---

### 2.3 Barrier (lines 402–507)

All *parties* must call `arrive()` before any of them unblocks.  The last to arrive calls `resume(Unit)` for all preceding waiters.

```kotlin
override val resumeMode get() = ASYNC
override val cancellationMode get() = SMART
```

`onCancellation()` decrements the arrived counter unless all parties have already arrived (in which case a resume is already in flight and must be refused).  Note cancellation is *not* fully atomic across parties — this is the same limitation as Java's `CyclicBarrier`.

| LinCheck tests | Parties |
|---|---|
| `Barrier1LincheckTest` | 1 |
| `Barrier2LincheckTest` | 2 |
| `Barrier3LincheckTest` | 3 |

**Operations:** `arrive()` (annotated `cancellableOnSuspension = false`).

---

### 2.4 Blocking Pools (lines 510–821)

A pool of reusable resources (`retrieve` / `put`).  Two backing structures are tested.

#### `BlockingQueuePool<T>` — ASYNC + SIMPLE

Uses a flat array with fetch-and-add indices (`insertIdx`, `retrieveIdx`).  If a `tryRetrieve` races with an empty slot it marks it `BROKEN`, forcing the corresponding `tryInsert` to also fail, and both retry.

#### `BlockingStackPool<T>` — ASYNC + SMART

Uses a concurrent linked list.  SMART cancellation allows `put` to return immediately; if the waiter it targeted was cancelled, `onCancellation` returns the permit to the counter, and `tryReturnRefusedValue` tries to re-insert into the stack without going through the full `put` loop.  `returnValue` falls back to `put`.

| LinCheck test | Pool type |
|---|---|
| `BlockingQueuePoolLincheckTest` | Queue |
| `BlockingStackPoolLincheckTest` | Stack |

**Operations:** `put()`, `retrieve()`.

---

## 3. Configuration Decisions (common to all tests)

| Setting | Value | Reason |
|---|---|---|
| `actorsBefore(0)` | 0 warm-up actors | Primitives start from a fixed initial state; no warm-up needed |
| `actorsAfter(0)` | 0 post-parallel actors | (CountDownLatch, Barrier) |
| `sequentialSpecification(...)` | Per-primitive sequential class | Ground-truth comparison |
| `checkObstructionFreedom()` | Most tests | SQS progress guarantee: each operation finishes if run in isolation |
| `checkObstructionFreedom(false)` | SYNC semaphore tests | SYNC mode spin-waits; obstruction freedom does not hold |

---

## 4. Concept-by-Concept Mapping to OCaml

The OCaml port (`lib/sqs_effects.ml` + `lib/light_thread.ml`) preserves all of the structural concepts.  The table below shows the direct equivalents.

| Kotlin CQS | OCaml SQS |
|---|---|
| `CancellableQueueSynchronizer<T>` | `'a Sqs_effects.t` (record created by `Sqs_effects.make`) |
| `override val resumeMode = ASYNC` | `~resume_mode:Async` argument to `make` |
| `override val resumeMode = SYNC` | `~resume_mode:Sync` |
| `override val cancellationMode = SIMPLE` | `~cancellation_mode:Simple` (default) |
| `override val cancellationMode = SMART` | `~cancellation_mode:Smart` |
| `suspend(cont)` — registers a `CancellableContinuation` | `suspend sqs` — calls `Light_thread.suspend (fun k -> park_continuation sqs k)` |
| `resume(value)` — returns `Boolean` | `resume sqs value` — returns `bool` |
| `suspendCancellableCoroutine { cont -> ... }` | `Light_thread.suspend (fun k -> ...)` |
| `cont.resume(v)` | `Light_thread.resume k v` |
| `cont.cancel(exn)` / `invokeOnCancellation` | `Light_thread.discontinue k Cancelled` (via `cancel_waiter sqs seg i`) |
| `override fun onCancellation(): Boolean` | `~on_cancellation:(fun () -> bool)` |
| `override fun returnValue(v)` | `~return_value:(fun v -> unit)` |
| `override fun tryReturnRefusedValue(v): Boolean` | `~try_return_refused_value:(fun v -> bool)` |
| `Waiter` cell state | `Waiter of 'a cont` where `'a cont = 'a Light_thread.t` |
| `Cancelling` cell state | `Cancelling of 'a cont` |
| `Cancelled`, `Refuse`, `Resumed`, `Taken`, `Broken` | Same names in `cell_state` |
| `Value(v)`, `WrappedValue(v)` | `Value of 'a`, `WrappedValue of 'a` |
| `promptCancellation = false` (LinCheck annotation) | No direct equivalent; cancellation in OCaml is manual via `cancel_waiter` |

### Continuation model difference

| Kotlin | OCaml |
|---|---|
| `CancellableContinuation` — heap object, can be cancelled at any time from outside | `Light_thread.t = ('a, unit) Effect.Deep.continuation` — a linear heap pointer; **must be resumed or discontinued exactly once** |
| `invokeOnCancellation { … }` registered per-continuation | `cancel_waiter sqs seg i` called explicitly by the owner of the segment reference |

Because OCaml continuations are **linear**, the CAS on the cell state (`Waiter k → Resumed` or `Waiter k → Cancelling k`) is the single ownership transfer point — whoever wins the CAS is the sole party allowed to call `Light_thread.resume` or `Light_thread.discontinue` on `k`.  This directly mirrors the Kotlin implementation's atomicity guarantee.

---

## 5. Primitives Covered by LinCheck vs. OCaml Port

| Primitive | Kotlin LinCheck | OCaml `sqs_effects.ml` |
|---|---|---|
| Semaphore (ASYNC + SIMPLE) | `AsyncSemaphore` ✓ | `Semaphore` module (ASYNC + SMART) ✓ |
| Semaphore (ASYNC + SMART) | `AsyncSemaphoreSmart` ✓ | Same module ✓ |
| Semaphore (SYNC + SMART) | `SyncSemaphoreSmart` ✓ | Not yet ported |
| Mutex | Not in LinCheck (stdlib) | `Mutex` module ✓ |
| CountDownLatch (SIMPLE) | `CountDownLatch` ✓ | Not yet ported |
| CountDownLatch (SMART) | `CountDownLatchSmart` ✓ | Not yet ported |
| Barrier | `Barrier` ✓ | Not yet ported |
| BlockingQueuePool | `BlockingQueuePool` ✓ | Not yet ported |
| BlockingStackPool | `BlockingStackPool` ✓ | Not yet ported |

---

## 6. What the LinCheck Verifies That OCaml Tests Currently Do Not

The existing OCaml tests (`test/segment_queue_synchronizer_expect_test.ml`) are **sequential unit tests** — they exercise one interleaving at a time and check exact outcomes.  LinCheck adds:

1. **Concurrent linearizability** — verifies that *all* concurrent interleavings produce outcomes consistent with some sequential execution.  None of the OCaml tests run two `Domain`s against the same SQS instance and verify the result space.

2. **Exhaustive model checking** — for small bounds LinCheck proves correctness, not just increases confidence.  The OCaml tests catch bugs in specific paths but cannot prove absence of races.

3. **Obstruction freedom** — LinCheck isolates one thread and verifies it completes in finite steps.  The OCaml implementation's progress guarantee is asserted by design (lock-free CAS loops, no blocking), but not mechanically verified.

4. **`tryAcquire` linearizability** — the SYNC mode semaphore's non-suspending fast path is non-trivial to linearise correctly.  LinCheck model-checks it.  OCaml's `Semaphore` only has `acquire` and `release`.

5. **Prompt cancellation paths** — LinCheck's `promptCancellation = false/true` annotation controls whether cancelled operations raise immediately.  The OCaml port handles prompt cancellation via the `| exception Cancelled` branch in `try_resume_impl` (line 372–387 of `sqs_effects.ml`), but this path has no dedicated concurrent test.

---

## 7. Verdict: Is the LinCheck Suitable for the OCaml SQS?

**Conceptually, yes** — every correctness property the LinCheck tests enforces maps directly onto a concept present in the OCaml SQS:

| LinCheck property | OCaml SQS mechanism |
|---|---|
| Linearizability of `acquire`/`release` | Atomic `fetch_and_add` on `permits` + CAS on cells |
| ASYNC elimination (resume before suspend) | `Value v` / `WrappedValue v` cell states + `park_continuation` fast path |
| SYNC spin handshake | `spin max_spin_cycles` loop in `try_resume_impl` |
| SMART cancellation: `onCancellation` | `~on_cancellation` callback + `handle_cancellation` |
| SMART cancellation: refused value return | `~try_return_refused_value` + `~return_value` + `Refuse` cell state |
| Obstruction freedom | Lock-free CAS loops in `resume`, `park_continuation`, `handle_cancellation` |

**Operationally, LinCheck cannot run on OCaml** — it is a JVM framework using bytecode instrumentation.  To get equivalent guarantees on the OCaml port, the right approach is to write **domain-based concurrent tests** (using `Domain.spawn`) that exercise the same operation mixes the LinCheck tests exercise, and to verify outcomes against a sequential reference implementation — exactly the pattern the `segment_queue_synchronizer_expect_test.ml` file already uses for sequential paths.
