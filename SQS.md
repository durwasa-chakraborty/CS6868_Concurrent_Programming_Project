# Segment Queue Synchronizer (SQS) — OCaml 5 Effects Edition

This document describes the architecture of the Segment Queue Synchronizer,
its public API, and the precise path that an algebraic effect takes from the
moment `suspend` is called to the moment a value is delivered back to the
caller.

---

## Table of Contents

1. [What is the SQS?](#1-what-is-the-sqs)
2. [Architecture](#2-architecture)
   - [The Infinite Array](#21-the-infinite-array)
   - [Segments](#22-segments)
   - [Cell State Machine](#23-cell-state-machine)
3. [Configuration](#3-configuration)
4. [SQS Record and API](#4-sqs-record-and-api)
5. [LightThread — the Green-Thread Substrate](#5-lightthread--the-green-thread-substrate)
   - [Type and Effect Declaration](#51-type-and-effect-declaration)
   - [Primitives](#52-primitives)
   - [Handler](#53-handler)
6. [Effect Tracing Through SQS](#6-effect-tracing-through-sqs)
   - [The Suspend Path](#61-the-suspend-path)
   - [The Resume Path](#62-the-resume-path)
   - [The Cancellation Path](#63-the-cancellation-path)
7. [Built-in Synchronisation Primitives](#7-built-in-synchronisation-primitives)
   - [Semaphore](#71-semaphore)
   - [Mutex](#72-mutex)
8. [Usage Examples](#8-usage-examples)

---

## 1. What is the SQS?

The **Segment Queue Synchronizer** is a concurrent, fair (FIFO), cancellable
rendezvous primitive.  It is the foundation described in the paper
*"CQS: A Formally-Verified Framework for Fair and Abortable Mutual Exclusion"*
(Koval et al., 2023) and used inside `kotlinx.coroutines` to build semaphores,
mutexes, channels, and barriers.

The core contract:

- **`suspend sqs`** — park the current light thread until a value arrives.
- **`resume sqs v`** — deliver value `v` to the next waiting thread, or park
  `v` in the queue if nobody is waiting yet.

This OCaml port (`lib/sqs_effects.ml`) replaces Kotlin's
`CancellableContinuation` (a callback handle) with an OCaml 5 first-class
continuation captured via algebraic effects, delegating the green-thread
mechanics to `lib/light_thread.ml`.

The callback-based reference implementation lives in
`lib/segment_queue_synchronizer.ml`.

---

## 2. Architecture

### 2.1 The Infinite Array

Conceptually the SQS is an **infinite array** of cells indexed from 0.
Two monotonically increasing counters partition the array:

```
                        suspendIdx
                        │
  0   1   2   3   4   5 ▼
┌───┬───┬───┬───┬───┬───┬─ ─ ─
│ R │ R │ R │ W │ W │ E │
└───┴───┴───┴───┴───┴───┴─ ─ ─
              ▲
              resumeIdx

  R = Resumed (already matched)
  W = Waiter  (parked, waiting for a resume)
  E = Empty   (not yet claimed)
```

- **`suspend`** atomically increments `suspend_idx`, claims cell
  `suspend_idx` for a new waiter, and parks the current continuation there.
- **`resume`** atomically increments `resume_idx`, claims cell `resume_idx`,
  and either wakes a waiting continuation or parks the value for the next
  `suspend` to find.

Each cell is visited at most once by one `suspend` and one `resume`.
The ordering of their arrivals determines the cell's terminal state.

### 2.2 Segments

The infinite array is physically represented as a **linked list of fixed-size
segments**, each holding `segment_size = 16` cells.

```
┌────────────────────────────────────────────────────────┐
│  segment 0  (id=0)                                     │
│  cells[0..15]   cancelled_count   pointers   next ──►  │
│  prev = None                                           │
└────────────────────────────────────────────────────────┘
       │ next
       ▼
┌────────────────────────────────────────────────────────┐
│  segment 1  (id=1)                                     │
│  cells[0..15]   ...                                    │
└────────────────────────────────────────────────────────┘
```

The `segment` record in `sqs_effects.ml`:

```ocaml
type 'a segment = {
  id              : int;                           (* monotonically increasing *)
  cells           : 'a cell_state Atomic.t array;  (* length = segment_size   *)
  next            : 'a segment option Atomic.t;
  prev            : 'a segment option Atomic.t;
  cancelled_count : int Atomic.t;  (* how many cells reached a terminal cancel state *)
  pointers        : int Atomic.t;  (* SQS head/tail references to this segment      *)
}
```

`Segment.find_and_advance` walks forward from a cached start segment, appending
new segments on demand with a CAS.  It also opportunistically advances the
SQS's `resume_segment`/`suspend_segment` pointer so future operations start
closer to the live region.

When every cell in a segment is cancelled (`cancelled_count = segment_size`),
`Segment.on_slot_cleaned` splices the segment out of the list so it can be
garbage-collected.

### 2.3 Cell State Machine

Each cell transitions through the following states.  Arrows show valid
transitions; the state names are the constructors of `'a cell_state`.

```
                         ┌──────────────────────────────────────────────┐
                         │               EMPTY                          │
                         └──────────────────────────────────────────────┘
                           │ suspend CAS          │ resume CAS
                           ▼                      ▼
                     ┌──────────┐           ┌───────────────┐
                     │  WAITER  │           │     VALUE     │ (resume before suspend)
                     │  (cont)  │           │ or WRAPPEDVAL │
                     └──────────┘           └───────────────┘
          resume CAS  │   │  cancel          │ suspend CAS
                      │   ▼                  ▼
                      │ ┌────────────┐     ┌───────┐
                      │ │ CANCELLING │     │ TAKEN │  ← suspend claimed the value
                      │ │   (cont)   │     └───────┘
                      │ └────────────┘
                      │  on_cancellation()
                      │   │         │
                      ▼   ▼         ▼
                   ┌─────────┐  ┌────────┐
                   │ RESUMED │  │CANCEL- │
                   └─────────┘  │  LED   │
                                └────────┘
                                     │ also REFUSE
                                     ▼
                                ┌────────┐
                                │ REFUSE │  ← next resume will be rejected
                                └────────┘

  BROKEN — SYNC race: resume timed out before suspend arrived
```

| State | Meaning |
|-------|---------|
| `Empty` | Cell is unclaimed. |
| `Waiter k` | A continuation `k` is parked waiting for a value. |
| `Value v` | A resume deposited `v` before a suspend arrived. |
| `WrappedValue v` | Same as `Value`, used in SMART/ASYNC cancellation to distinguish a value from a `Waiter`. |
| `Taken` | The parked value was grabbed by a matching suspend (elimination). |
| `Resumed` | The continuation was successfully resumed; reference cleared. |
| `Cancelling k` | Cancellation started; `k` is still held here while the handler runs. |
| `Cancelled` | Cell is permanently dead; `resume` skips it (SMART mode). |
| `Refuse` | The next `resume` landing here must call `try_return_refused_value`. |
| `Broken` | SYNC race: the spin timeout fired before a matching suspend arrived. |

---

## 3. Configuration

An SQS instance is created with `make` and supports five optional parameters:

| Parameter | Type | Default | Meaning |
|-----------|------|---------|---------|
| `resume_mode` | `Sync \| Async` | `Sync` | How `resume` behaves when it arrives before a `suspend`. |
| `cancellation_mode` | `Simple \| Smart` | `Simple` | How cancelled waiters affect `resume`. |
| `on_cancellation` | `unit -> bool` | `fun () -> false` | Called when a waiter is cancelled. Returns `true` → cell → `Cancelled`; `false` → cell → `Refuse`. |
| `try_return_refused_value` | `'a -> bool` | `fun _ -> true` | Called on the value landing on a `Refuse` cell. Returns `false` → fall through to `return_value`. |
| `return_value` | `'a -> unit` | `fun _ -> ()` | Called as a last resort to dispose of an undeliverable value. |

**`resume_mode`**

- **`Sync`** — `resume` parks a `Value v` in the empty cell and *spin-waits* for a concurrent `suspend` to claim it within `max_spin_cycles` iterations.  If the timeout fires first, the cell transitions to `Broken` and `resume` returns `false`.  Used when the caller can afford to wait a short time for the rendezvous to complete.
- **`Async`** — `resume` parks `Value v` and returns immediately with `true`.  The `suspend` that arrives later will find and claim the value (elimination).  Used in semaphores and mutexes where the releaser must not block.

**`cancellation_mode`**

- **`Simple`** — when a cell is cancelled, `resume` returns `false` (or retries in an outer loop only if the caller requests it). The value is lost unless the caller explicitly retries.
- **`Smart`** — when a cell is cancelled, `resume` automatically skips it and tries the next cell, calling `on_cancellation` / `return_value` to handle the displaced value.  Used when the outer data structure must not lose values despite cancellations.

---

## 4. SQS Record and API

### The record

```ocaml
type 'a t = {
  resume_segment           : 'a segment Atomic.t;  (* cached tail for resumes  *)
  resume_idx               : int Atomic.t;          (* next cell index to resume *)
  suspend_segment          : 'a segment Atomic.t;  (* cached tail for suspends *)
  suspend_idx              : int Atomic.t;          (* next cell index to park  *)
  resume_mode              : resume_mode;
  cancellation_mode        : cancellation_mode;
  on_cancellation          : unit -> bool;
  try_return_refused_value : 'a -> bool;
  return_value             : 'a -> unit;
}
```

Both `resume_segment`/`suspend_segment` are *hints*: they are atomically
advanced toward the live tail but may lag behind.  `find_and_advance` corrects
any lag before each operation.

### Public API

```ocaml
(** Create an SQS with the given policies. *)
val make :
  ?resume_mode:resume_mode ->
  ?cancellation_mode:cancellation_mode ->
  ?on_cancellation:(unit -> bool) ->
  ?try_return_refused_value:('a -> bool) ->
  ?return_value:('a -> unit) ->
  unit -> 'a t

(** Park the current light thread and wait for a value.
    Must be called inside a [run] handler.
    Raises [Cancelled] if the waiter is discontinued. *)
val suspend : 'a t -> 'a

(** Deliver [value] to the next live waiter, or park it for a future suspend.
    Returns [true] on success, [false] if the cell was broken (SYNC) or
    cancelled (Simple mode). *)
val resume : 'a t -> 'a -> bool

(** Install the LightThread handler and run [f ()].
    Every fibre that calls [suspend] must be wrapped in [run]. *)
val run : (unit -> unit) -> unit

(** Cancel the waiter parked at cell [i] of [seg].
    Equivalent to invoking [invokeOnCancellation] in Kotlin. *)
val cancel_waiter : 'a t -> 'a segment -> int -> unit

(** Non-blocking variant: claim a slot as immediately cancelled.
    Returns [Some v] if an elimination happened, [None] otherwise. *)
val suspend_cancelled : 'a t -> 'a option
```

### Internal operations (exposed for testing)

```ocaml
(** Single attempt at delivering value; used by resume's retry loop. *)
val try_resume_impl : 'a t -> 'a -> bool -> try_resume_result

(** Atomically move a cell from Waiter → Cancelling. *)
val try_mark_cancelling : 'a segment -> int -> bool

(** Atomically replace Cancelling with a terminal marker. *)
val mark_impl : 'a segment -> int -> 'a cell_state -> 'a option
val mark_cancelled : 'a t -> 'a segment -> int -> 'a option
val mark_refuse : 'a segment -> int -> 'a option
```

---

## 5. LightThread — the Green-Thread Substrate

`lib/light_thread.ml` is a self-contained module that provides the
four primitives needed to implement cooperative green threads using
OCaml 5's algebraic effects.  It has no knowledge of the SQS protocol.

### 5.1 Type and Effect Declaration

```ocaml
(** A parked light thread waiting for a value of type 'a.
    Concretely a one-shot OCaml 5 continuation. *)
type 'a t = ('a, unit) Effect.Deep.continuation

(** The single effect this module declares.
    The payload is a *register* callback, not the SQS instance itself.
    This keeps LightThread decoupled from any particular synchroniser. *)
type _ Effect.t +=
  | Suspend : ('a t -> unit) -> 'a Effect.t
```

The `Suspend` effect carries a `register` callback of type `'a t -> unit`.
When the handler fires, it captures the continuation `k : 'a t` and calls
`register k`.  `register` is responsible for storing `k` somewhere (an SQS
cell, a queue, a promise) so that a future `resume` can wake it.

This design cleanly separates concerns:

- `LightThread` owns **how** to capture and resume continuations.
- `SQS` owns **where** to store them and **when** to wake them.

### 5.2 Primitives

```ocaml
(** Perform the Suspend effect, handing the captured continuation
    to [register] before returning control to the nearest [run]. *)
let suspend register =
  Effect.perform (Suspend register)

(** Restart a parked thread with a value. *)
let resume t v = Effect.Deep.continue t v

(** Restart a parked thread by raising an exception (cancellation). *)
let discontinue t exn = Effect.Deep.discontinue t exn
```

`Effect.Deep.continue` and `Effect.Deep.discontinue` are the OCaml 5 runtime
primitives for resuming first-class continuations.  Each continuation is
*linear*: it must be resumed or discontinued exactly once.

### 5.3 Handler

```ocaml
let run f =
  Effect.Deep.match_with f ()
    { Effect.Deep.retc = (fun () -> ())  (* f completed normally *)
    ; exnc = raise                        (* f raised an exception *)
    ; effc = fun (type a) (eff : a Effect.t) ->
        match eff with
        | Suspend register ->
          Some (fun (k : (a, _) Effect.Deep.continuation) ->
            register k)
        | _ -> None                       (* unhandled effects propagate *)
    }
```

`Effect.Deep.match_with` installs a *deep* handler.  "Deep" means the same
handler is automatically re-installed after each resumption of `k`, so
subsequent `suspend` calls from the same fibre are also caught.

When `Suspend register` is performed:
1. The runtime captures the full continuation `k` (everything from the
   `Effect.perform` call to the end of `f`).
2. The handler calls `register k`.
3. The handler callback returns `unit`; control goes to the caller of `run`.
4. Later, when `resume k v` is called, `k` restarts from step 1's capture
   point, returning `v` from `Effect.perform`.

---

## 6. Effect Tracing Through SQS

This section traces the exact call graph for each operation.

### 6.1 The Suspend Path

**Scenario:** a fibre calls `suspend sqs` while no value is waiting.

```
User fibre (inside run f)
│
├─ suspend sqs
│    └─ Light_thread.suspend (fun k -> ignore (park_continuation sqs k))
│         └─ Effect.perform (Suspend register)
│               ↑
│         ┌─────┴──────────────────────────────────────────────────────────┐
│         │  Handler in Light_thread.run                                   │
│         │                                                                │
│         │  effc (Suspend register) = Some (fun k -> register k)         │
│         │  ↓ handler callback is invoked with captured continuation k    │
│         │  register k                                                    │
│         │    = (fun k -> ignore (park_continuation sqs k)) k             │
│         │    = park_continuation sqs k                                   │
│         │        ├─ FAA sqs.suspend_idx   → idx                         │
│         │        ├─ find_and_advance ...  → seg, i                      │
│         │        └─ Segment.cas seg i Empty (Waiter k)  → true          │
│         │           k is now stored in cells[i]                          │
│         │  handler callback returns ()                                   │
│         └──────────────────────────────────────────────────────────────-┘
│              run returns () to caller of run
│
│  (fibre is parked — execution suspended here until a resume arrives)
```

**Elimination (resume arrived first):** if `Segment.cas` finds the cell is
not `Empty` (a concurrent `resume` already deposited `Value v`):

```
park_continuation sqs k
    ├─ CAS Empty → Waiter k  fails
    ├─ cell = Segment.get seg i     ← read cell ONCE (avoids TOCTOU)
    ├─ match cell with
    │    Value v | WrappedValue v →
    │        Segment.cas seg i cell Taken   ← use matched value, not fresh read
    │        Light_thread.resume k v        ← wakes fibre immediately, inline
    └─ returns true
```

The fibre is never actually parked in this case; `Light_thread.resume k v`
runs the continuation synchronously inside the handler callback.

### 6.2 The Resume Path

**Scenario:** a fibre is parked (`Waiter k` in some cell); `resume sqs v`
is called from outside.

```
resume sqs v
│
├─ try_resume_impl sqs v skip_cancelled
│    ├─ FAA sqs.resume_idx  → idx
│    ├─ find_and_advance ... → seg, i
│    ├─ Segment.get seg i   → Waiter k
│    ├─ Segment.cas seg i (Waiter k) Resumed   ← claim cell atomically
│    └─ Light_thread.resume k v
│           = Effect.Deep.continue k v
│                ↑
│         ┌──────┴──────────────────────────────────────────────────────────┐
│         │  Continuation k resumes                                         │
│         │                                                                 │
│         │  Effect.perform (Suspend register)  returns  v                 │
│         │  Light_thread.suspend register      returns  v                 │
│         │  suspend sqs                         returns  v                │
│         │                                                                 │
│         │  (fibre continues executing with v in hand)                    │
│         └─────────────────────────────────────────────────────────────────┘
│
└─ returns true
```

If the continuation itself raises `Cancelled` during dispatch (prompt
cancellation), `try_resume_impl` catches it and invokes the `on_cancellation`
/ `return_value` policies.

**Resume-before-suspend (ASYNC mode):**

```
resume sqs v
│
├─ try_resume_impl sqs v _
│    ├─ Segment.get seg i  →  Empty
│    ├─ Segment.cas seg i Empty (Value v)   ← park the value
│    └─ returns TryResumeSuccess immediately  (ASYNC: no spin)
│
│  (later, when suspend sqs arrives)
│
suspend sqs
│
├─ park_continuation sqs k
│    ├─ CAS Empty → Waiter k  fails  (cell holds Value v)
│    ├─ cell = Segment.get seg i  →  Value v
│    ├─ Segment.cas seg i (Value v) Taken
│    └─ Light_thread.resume k v      ← elimination: resume inline
└─ returns v
```

### 6.3 The Cancellation Path

**Scenario:** a parked waiter at `(seg, i)` is cancelled.

```
cancel_waiter sqs seg i
│
└─ handle_cancellation sqs seg i
     │
     ├─ try_mark_cancelling seg i
     │    └─ Segment.cas seg i (Waiter k) (Cancelling k)  → true
     │
     ├─ cont = Segment.get seg i  → Cancelling k  →  extract k
     │
     └─ (match cancellation_mode)
          │
          Simple ──────────────────────────────────────────────────┐
          │                                                         │
          │  mark_cancelled sqs seg i                              │
          │    └─ Segment.xchg seg i Cancelled  (atomic exchange)  │
          │       Segment.on_slot_cleaned seg                      │
          │  Light_thread.discontinue k Cancelled                  │
          │    = Effect.Deep.discontinue k Cancelled               │
          │                                                         │
          │  (fibre resumes, Cancelled exception raised at the     │
          │   suspension point, propagates to caller of suspend)   │
          │                                                         │
          Smart (on_cancellation returns true → CANCEL) ──────────┘
          │
          │  mark_cancelled sqs seg i
          │    └─ Segment.xchg seg i Cancelled
          │       ├─ returns None        → no pending async value
          │       └─ returns Some v      → async resume sneaked in
          │            if not (resume sqs v) then sqs.return_value v
          │
          │  Light_thread.discontinue k Cancelled
          │
          Smart (on_cancellation returns false → REFUSE)
          │
          │  mark_refuse seg i
          │    └─ Segment.xchg seg i Refuse
          │       └─ returns Some v (async) → return_refused_value sqs v
          │
          └─ Light_thread.discontinue k Cancelled
```

The `Segment.xchg` (atomic exchange) in `mark_impl` is the key primitive:
it atomically reads the old cell value *and* installs the new marker in a
single hardware instruction (`XCHG` or `LOCK XCHG` on x86), making it safe
against concurrent ASYNC resumes that may have deposited a `Value` into a
`Cancelling` cell.

---

## 7. Built-in Synchronisation Primitives

### 7.1 Semaphore

```
lib/sqs_effects.ml → module Semaphore
```

A **fair counting semaphore** where `acquire` blocks if no permits are
available and `release` wakes the next waiter in FIFO order.

```
SQS configuration:
  resume_mode       = Async   (release must not block)
  cancellation_mode = Smart   (on_cancellation puts the permit back)
```

**Permit accounting:**

```
acquire:
  p ← FAA permits −1
  if p > 0  →  permit was available; return immediately
  else      →  p ≤ 0; suspend and wait for a release

release:
  p ← FAA permits +1
  if p < 0  →  a waiter exists (permits was negative); resume it
  else      →  no waiters; the incremented counter is sufficient
```

The `permits` counter can go negative when more fibres are waiting than
permits are available.  The magnitude of a negative value equals the number
of waiters.

**Cancellation:** when an acquirer cancels, `on_cancellation` increments
`permits` so the permit that was logically reserved for the cancelled waiter
is returned to the pool.

### 7.2 Mutex

```
lib/sqs_effects.ml → module Mutex
```

A **fair mutex** using a callback-style API.  `lock callback` acquires the
lock and runs `callback` under it; `unlock` releases.

```
SQS configuration:
  resume_mode       = Async
  cancellation_mode = Smart
```

```
lock m callback:
  CAS locked false → true   →  acquired; run callback immediately
  fails            →  install run handler, suspend, then run callback

unlock m:
  resume m.sqs ()          →  true: woke a waiter (they will run callback)
                           →  false: no waiters; CAS locked → false
```

The `lock` function installs its own `Light_thread.run` handler when
contention occurs, so each contended lock operation creates an independent
fibre scope.

---

## 8. Usage Examples

### Basic rendezvous (effects version)

```ocaml
let sqs = Sqs_effects.make ~resume_mode:Async () in

(* Fibre A: suspends and waits for a value *)
Sqs_effects.run (fun () ->
  let v = Sqs_effects.suspend sqs in
  Printf.printf "got %d\n" v);

(* Fibre B: delivers the value *)
ignore (Sqs_effects.resume sqs 42)
(* Output: got 42 *)
```

### Semaphore

```ocaml
let sem = Sqs_effects.Semaphore.make 1 in

(* Critical section from fibre A *)
Sqs_effects.run (fun () ->
  Sqs_effects.Semaphore.acquire sem;
  (* ... work ... *)
  Sqs_effects.Semaphore.release sem)
```

### Mutex

```ocaml
let m = Sqs_effects.Mutex.make () in
let shared = ref 0 in

Sqs_effects.Mutex.lock m (fun () -> incr shared);
Sqs_effects.Mutex.unlock m;

Sqs_effects.Mutex.lock m (fun () -> incr shared);
Sqs_effects.Mutex.unlock m
```

### Manual cancellation

```ocaml
let sqs = Sqs_effects.make ~resume_mode:Async ~cancellation_mode:Smart () in

Sqs_effects.run (fun () ->
  match Sqs_effects.suspend sqs with
  | _                              -> Printf.printf "got value\n"
  | exception Sqs_effects.Cancelled -> Printf.printf "cancelled\n");

(* From another fibre or domain: *)
let seg = Atomic.get sqs.suspend_segment in
Sqs_effects.cancel_waiter sqs seg 0
(* Output: cancelled *)
```

---

## Source Map

| File | Purpose |
|------|---------|
| `lib/light_thread.ml` | Green-thread substrate: `Suspend` effect, `run`, `suspend`, `resume`, `discontinue` |
| `lib/sqs_effects.ml` | Full SQS implementation using `LightThread` continuations |
| `lib/segment_queue_synchronizer.ml` | Reference implementation using plain callbacks |
| `test/smoke_test.ml` | Basic sanity checks for the callback SQS |
| `test/segment_queue_synchronizer_expect_test.ml` | Expect-style unit tests for the callback SQS |
| `test/CqsLincheck.kt` | Original Kotlin linearisability tests (reference) |
