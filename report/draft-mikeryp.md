## Junked Text
- At its core, CQS is implemented as an infinite doubly linked list of `Segments`, where each segment stores a fixed number of slots for waiting EIO Fibers (EIO Fiber discussion covered later).
    - Doubly linked list is an implementation detail enabling fast deletion of cancelled/refused segments

- Supported Operations on CQS:
    1. Resume (val):
    2. Suspend
    3. Cancel

- EIO Fiber is used as a thread-safe alternative for the Thread API in Kotlin (Covered in later section )

- Each cell stores the following values in the corresponding cases:
    1. Suspended waiter thread (on calling suspend)
    2. Resumed state return value (When resume is called before suspend)
    3. Cancelled slot value
    4. Refused slot value

- Any segment with all slots being cancelled, refused or completed are removed from the doubly linked list

Writing concurrent code with ensured correctness and performance is a notoriously tough task. CQS is an abstraction which offers a common framework for building and reasoning about these concurrent data structures and their interactions. It also offers support for cancellation of threads, and hence promises high performance in concurrent applications with high number of operation abortion 
The project covers its replication, implementation and some optimizations in OCaml. We compare it against the equivalent abstraction in Java (AbstractQueueSynchronizer) and Kotlin (Original Work)




# MAJOR TODOs
- After submission
    - correctly implement primitives - switch to SYNC resumption; more correct for a concurrent setting




# Abstract


# Background


# Implementation (Core)
The OCaml 5 implementation consists of two layers: 
1. A domain-safe fiber-suspension layer (`lib/light_thread.ml`) 
2. the Segment Queue Synchronizer core (`lib/sqs_effects.ml`), 
On top of this, there are six synchronization primitives are built in `implementations/`.

### Domain Safe Fiber: `Light_thread`

The decision to implement co-routines using Effect Handlers was directly inspired by the lectures in class implementing a similar go-routine mechanism directly in OCaml. The first design decision was how to represent a suspended fiber. 
An early prototype (commit `ecb5855`) used raw OCaml 5 effect handlers and stored suspended fibers as `Effect.Deep.continuation` values. However, upon deeper inspection, We encountered a critical issue in this approach:

**OCaml 5 continuations are domain-local**. The runtime stores a pointer into the originating domain's stack, so calling `Effect.Deep.continue k v` from a different domain is undefined behaviour. This made it impossible to have one domain call `acquire` while another calls `release`, which would've made concurrent implementations incorrect. This was a non-trivial issue for implementing the `cancel` API call for Fiber, making the port more non-trivial 

To deal with this limitation, The final implementation (commit `17adae2`) replaces this with Eio's fiber scheduler. The key type is:

```ocaml
(* lib/light_thread.ml, line 57 *)
type 'a t = ('a, exn) result -> unit
```

With this, a suspended fiber is becomes a heap-allocated and domain-safe *enqueue function*. The Eio runtime guarantees that calling this function from any domain or systhread is safe. Calling it with `Ok v` schedules the fiber to resume with value `v`. This maps back to `resume(v)`. Whereas calling it with `Error e` schedules it to resume by raising `e`, mapping it back to `cancel(exn)`

The three primitives built on top are:

```ocaml
let suspend register =
  Eio.Private.Suspend.enter "sqs_suspend" (fun _ctx enqueue -> register enqueue)

let resume   (t : 'a t) (v : 'a)  : unit = t (Ok v)
let discontinue (t : 'a t) (e : exn) : unit = t (Error e)
```

## 2. Core SQS Data Structures

### 2.1 Segment

Waiters are stored in an unbounded linked list of *segments*, each holding exactly 16 cells:

```ocaml
'a segment = {
  id              : int;
  cells           : 'a cell_state Atomic.t array;   (* 16 cells *)
  next            : 'a segment option Atomic.t;
  prev            : 'a segment option Atomic.t;
  cancelled_count : int Atomic.t;
  pointers        : int Atomic.t;
}
```

- `cells`: Array storing cells in the segment
- `next`: Option storing the next segment in the infinite queue
- `prev`: Options storing the previous segment in the Infinite queue
- The `cancelled_count` tracks how many cells in the segment have been cleaned up;
- `pointers`: a lightweight reference count for the two SQS head/tail pointers (`resume_segment`, `suspend_segment`) that may still be pointing at the segment.


### 2.2 Cell State Machine
A Cell slot in a segment can take one of the following states:
 - `Empty`: No party has visited yet. This is the default state of all the cells in a segment
 - `Waiter`: Signifies that a live fiber is parked in the cell 
 - `Cancelling`: Transient state when a Fiber cancellation is in flight 
 - `Cancelled` : Waiter in the cell has been cancelled 
 - `Refuse`:  Cell refuses to satisfy the next Resume operation.
 - `Resumed`:  Continuation successfully handed off
 - `Taken`: Value grabbed by a concurrent suspend
 - `Broken`: A SYNC resume has race timed out
 - `Value`: Resume deposited value before suspend
 - `WrappedValue`: As Value, but distinguishable from Waiter

Initially, when a cell is in `Empty` state one of the 2 transitions is possible:
- `Value` when a resume occurs in the cell first
- `Waiter` when a suspend occurs in the cell before a resume operation


#### 2.2.1 CASE I: Resume comes First
 the `value` passed in the resume is stored into the CQS cell. Note that any incoming store directed to the slot would be instantly satisfied. 

There are 2 modes of resumption supported by CQS:
- **`Async`**: Deposits value in a cell and return immediately. The paired `suspend` will claim it via the **elimination path**.
- **`Sync`**: Here, the concurrent resumes and stores would be allowed into the CQS. In this scenario, the Resume would busy-wait for a bounded time. If the `resume` could not be matched with a concurrent `suspend` within this time, the cell would be considered as `BROKEN`. Conversely, if the `resume` could be matched with a concurrent `suspend`, the suspended fiber would be immediately continued with the value passed by the `resume`.

`Sync` mode exists for use cases that require the resumer to confirm the value was actually claimed before proceeding.

#### 2.2.2 CASE II: Suspend comes First
- 2 options: 
- Suspend satisfied by an existing Resume; Transitions into Resumed state
- Suspend enters an empty Cell in CQS; state transitions from Empty -> Waiting

- If suspend is waiting in a cell, 

### 2.3 SQS Record

```ocaml
(* sqs_effects.ml, lines 109–119 *)
and 'a t = {
  resume_segment           : 'a segment Atomic.t;
  resume_idx               : int Atomic.t;
  suspend_segment          : 'a segment Atomic.t;
  suspend_idx              : int Atomic.t;
  resume_mode              : resume_mode;       (* Sync | Async *)
  cancellation_mode        : cancellation_mode; (* Simple | Smart *)
  on_cancellation          : unit -> bool;
  try_return_refused_value : 'a -> bool;
  return_value             : 'a -> unit;
}
```

Two pairs of `(segment, idx)` fields maintain independent cursors for the resumer (front) and the suspender (back). Both indices advance monotonically with Fetch-and-Add`. This ends up being the only atomic read-modify-write primitive needed to claim a cell


















## Operations on CQS

### Suspend
- It parks the calling light weight thread in the queue untill a matching [resume] operation delivers it a value to continue with.
- In a sequential setting, a [resume] operation coming before [suspend] cannot be linearized appropriately, however in a concurrent/parallel setting, we may allow such an execution
- This implies that a [resume] operation entering a CQS may be valid as long as a concurrent [suspend] can be guaranteed to satisfy it. This is the core idea behind the ASYNC mode of CQS operations.
- However, we cannot naively allow [resume] to exist in the CQS Queue, since a sequential [suspend] can satisfy the [resume] operation enqueued.
- As a solution to this, `Sync` mode forces [resume] to busy wait for a bounded time frame, within which a concurrent [suspend] operation can match with a spinning [resume] operation 
    - If [resume] matches with a concurrent [suspend], the [suspend]ed Lightweight Thread is immediately resumed with the value passed in by the [resume] operation
    - If [resume] cannot be matched with a concurrent [suspend] 

### Resume (val): 
- It matches with a pending [suspend] in the CQS to continue the waiter with the value.
- Resumes are also allowed to enter the synchronizer queue without any 

### Cancel
For a waiter in the CQS, the [cancel] operation can be performed when thread is in the `suspended` state.


### LightWeight threads as EIO Fibers
Original work defined the queue mechanisms on top of a cancellable LightWeight thread interface, which is a language native feature in Kotlin.
This however is not the case in OCaml, which contains mainly the `Domain` type for OS thread mapping.
To replicate a similar behavior in OCaml, we have used `EIO.Fiber` as a cancellable Lightweight Thread replacement.

#### Original Idea: Implement concurrency using Effect Handlers
Drawing from class lectures, our original idea was to mimic the Kotlin Co-routines using Effect Handlers in OCaml. However, a discussion with claude revealed that the continuation object created in OCaml are themselves not thread-safe, even if the data accessed by them is. To avoid this, we decided to use EIO.Fiber as a wrapper for Cancellable Thread API. 

## Synchronization Primitives
We implemented the following synchronization primitives, effectively by following the description of them in the original paper /cite{nikita} 






























# Draft 1 - Implementation

Our implementation consists of two layers: 
1. A domain-safe suspendable fiber layer (`lib/light_thread.ml`) 
2. Core CQS (`lib/sqs_effects.ml`)

On top of this, we built six synchronization primitives in the`implementations/` folder:
- Mutex
- Semaphores
- Barriers
- CountDown Latch
- BlockingQueuePool
- BlockingStackPool

### Domain Safe Fiber: `Light_thread`

Our decision to implement Lightweight threads for mimicking coroutines by using Effect Handlers was directly inspired by the lectures in class, where we implemented a similar go-routine mechanism directly in OCaml. The first design decision was how to represent a suspended fiber. 
An early design (commit `ecb5855`) used raw OCaml 5 effect handlers and stored suspended fibers as `Effect.Deep.continuation` values. However, we encountered a critical issue in this approach.

TODO::
**OCaml 5 continuations are domain-local**: The OCaml5 runtime stores a pointer into the originating domain's stack, so calling `Effect.Deep.continue k v` from a different domain is undefined behaviour. This made it impossible to have one domain calling `acquire` while another calls `release`. This therefore became a non-trivial issue for implementing the `cancel` API call for Fiber, making the port more complicated. 

To deal with this limitation, the final design (commit `17adae2`) replaces this with Eio's fiber scheduler. The Eio runtime guarantees that calling this function from any domain is thread-safe. With this, a suspended fiber becomes a heap-allocated and domain-safe *enqueue function*.  Calling it with `Ok v` schedules the fiber to resume with value `v`. Whereas, calling it with `Error e` schedules it to resume by raising `e`, mapping it back to `cancel`

The three primitives built on top are:

```ocaml
let suspend register =
  Eio.Private.Suspend.enter "sqs_suspend" (fun _ctx enqueue -> register enqueue)

let resume   (t : 'a t) (v : 'a)  : unit = t (Ok v)
let discontinue (t : 'a t) (e : exn) : unit = t (Error e)
```

## 2. Core SQS Data Structures

### 2.1 Segment

Waiters are stored in an unbounded linked list of *segments*, each holding exactly 16 cells:

```ocaml
'a segment = {
  id              : int;
  cells           : 'a cell_state Atomic.t array;   (* 16 cells *)
  next            : 'a segment option Atomic.t;
  prev            : 'a segment option Atomic.t;
  cancelled_count : int Atomic.t;
  pointers        : int Atomic.t;
}
```

- `cells`: Array storing cells in the segment
- `next`: Option storing the next segment in the infinite queue
- `prev`: Options storing the previous segment in the Infinite queue
- The `cancelled_count` tracks how many cells in the segment have been cleaned up;
- `pointers`: a lightweight reference count for the two SQS head/tail pointers (`resume_segment`, `suspend_segment`) that may still be pointing at the segment.


### 2.2 Cell State Machine
A Cell slot in a segment can take one of the following states:
 - `Empty`: No party has visited yet. This is the default state of all the cells in a segment
 - `Waiter`: Signifies that a live fiber is parked in the cell 
 - `Cancelling`: Transient state when a Fiber cancellation is in flight 
 - `Cancelled` : Waiter in the cell has been canceled 
 - `Refuse`:  Cell refuses to satisfy the next Resume operation.
 - `Resumed`:  Continuation successfully handed off
 - `Taken`: Value grabbed by a concurrent suspend
 - `Broken`: A SYNC resume has timed out
 - `Value`: Resume deposited value before suspend
 - `WrappedValue`: As Value, but distinguishable from Waiter

[State Diagram png]


Initially, when a cell is in `Empty` state, one of the following 2 transitions is possible:
- `Value` when a resume occurs in the cell first
- `Waiter` when a suspend occurs in the cell before a resume operation

#### 2.2.1 CASE I: Resume comes first,
 the `value` passed in the resume is stored in the CQS cell. Note that any incoming store directed to the slot would be instantly satisfied. 

There are **2 modes of resumption** supported by CQS:
- **`Async`**: Deposits value in a cell and return immediately. The paired `suspend` will claim it via the **elimination path**.
- **`Sync`**: Here, the concurrent resumes and stores would be allowed into the CQS. In this scenario, the Resume would busy-wait for a bounded time. If the `resume` could not be matched with a concurrent `suspend` within this time, the cell would be considered as `BROKEN`. Conversely, if the `resume` could be matched with a concurrent `suspend`, the suspended fiber would be immediately continued with the value passed by the `resume`.

All six primitives use `Async` mode because none of them need a synchronous handshake: a `release` or `count_down` can return as soon as the value is enqueued. `Sync` mode exists for use cases that require the resumer to confirm the value was actually claimed before proceeding.

#### 2.2.2 CASE II: Suspend comes First

A suspend action can either be satisfied by an existing resume, which leads to a transition from an Empty state to a Waiting state and then to a Resumed state, or it can enter an empty Cell in CQS and transition from Empty to Waiting. 
If a suspend action is in a waiting state within a cell, there are two possible outcomes. The first is a **Resumption Path**, where a matching resume is received that corresponds with the waiter, allowing the process to transition from Waiting to Resumed with a value passed in by the `resume` operation. The second is the Cancellation Path, which occurs when a cancel request is invoked on a thread that is parked in the CQS. This results in the thread transitioning to either a Cancelled or Refused state, based on the cancellation mode used.


### Cancellation Procedure and Modes

Cancellation uses a two-phase protocol to prevent races with concurrent `resume` calls.
Phase 1 marks `Cancelling` (`try_mark_cancelling`, lines 422–434): CAS the cell from `Waiter` to `Cancelling` state. If the cell is already `Resumed`, the cancellation loses the race and returns false. The resume is already committed and the fiber will receive the value normally.
Phase 2 (`handle_cancellation`, lines 460–489): installs the `Cancelling` state in the cell. Here, the behavior depends on `cancellation_mode`:

There are 2 modes of cancellation supported in CQS: **Simple** and **Smart** Cancellation modes. 

In the **Simple** mode, when a cell's state is marked as Cancelled, the waiter is discontinued. Due to this, the next resume operation will skip this cell and fail, as it does not retry cancelled cells. It may also result in the segment getting unlinked if all slots are marked as Cancelled.
On the other hand, the **Smart** mode interacts with the primitive by invoking an `on_cancellation()` handler. If this handler returns true, the cell is marked as Cancelled, and there is a check to see if any values were inserted in the cell while the cell was in `Cancelling` state. If a value was found, it would be forwarded with another resume call to ensure no permits are lost. However, if `on_cancellation()` returns false, the cell is marked as Refuse. In this case, the next resume arriving at this cell will reroute the value back into the data structure before discontinuing the continuation, utilizing the `try_return_refused_value` function.

The `Cancelling` transient state serializes against `Async` resumers: a resumer that finds `Cancelling` must CAS against the live `Cancelling k` pointer (not reconstruct it) and may deposit a value into it. The cancellation handler reads this back via `Atomic.exchange` in `mark_impl` function.


### 2.3 SQS Record

```ocaml
(* sqs_effects.ml, lines 109–119 *)
and 'a t = {
  resume_segment           : 'a segment Atomic.t;
  resume_idx               : int Atomic.t;
  suspend_segment          : 'a segment Atomic.t;
  suspend_idx              : int Atomic.t;
  resume_mode              : resume_mode;       (* Sync | Async *)
  cancellation_mode        : cancellation_mode; (* Simple | Smart *)
  on_cancellation          : unit -> bool;
  try_return_refused_value : 'a -> bool;
  return_value             : 'a -> unit;
}
```

Two pairs of `(segment, idx)` fields maintain independent cursors for the resumer (front) and the suspender (back). Both indices advance monotonically with Fetch-and-Add`. This ends up being the only atomic read-modify-write primitive needed to claim a cell.


## 3. Key Atomic Operations

Following 3 atomic operations from OCaml 5's `Atomic` module were used in our implementation:

| Operation | Used for |
|---|---|
| `Atomic.fetch_and_add idx 1` | Claiming the next cell index (suspend and resume cursors) |
| `Atomic.compare_and_set cell expected desired` | All cell state transitions; segment linking; done-bit installation |
| `Atomic.exchange cell new_state` | Cancellation finalization (`mark_impl`) |

`fetch_and_add` on the index is the only operation that must succeed unconditionally, ensuring that every caller receives a unique index. All subsequent cell operations are based on CAS and will be retried in case of conflicts. 
Additionally,`Atomic.exchange` is employed during cancellation finalization because the old state of the cell needs to be atomically replaced while its value is being inspected simultaneously. Using a CAS loop in this context could create a window where a concurrent `resume` might insert a value between the read and the swap.

Every shared variable used in the CQS implementation is either an `Atomic.t` or an immutable. Correctness relies entirely on the CAS/FAA-based state machines described above, matching the lock-free design of the original CQS paper.

### The Physical-Equality Invariant

A critical invariant is implied in every CAS in our implementation: **always CAS against a heap pointer read in the same critical region, never against a freshly reconstructed value of the same shape.** This was inferred from the demo given during course lectures.
OCaml's `Atomic.compare_and_set` needs a *physical equality* (`==`), not structural equality (`=`) for a successful CAS. A freshly allocated `Waiter k` is a different heap object from the `Waiter k` stored in the cell, so the CAS would silently fail even though the logical values are equal. 

This pattern appears in the following places in the codebase:

```ocaml
(* try_resume_impl: CAS against [curr], not [Waiter k] *)
| Waiter k as curr ->
    if not (Segment.cas seg i curr Resumed) then cell_loop ()

(* try_mark_cancelling: CAS against [curr], not [Cancelling k] *)
| Waiter k as curr ->
    if Segment.cas seg i curr (Cancelling k) then true

(* park_continuation: CAS against [cell], not [Value v] *)
| Value v | WrappedValue v ->
    if Segment.cas seg i cell Taken then ...
```

In each case, the matched `as curr` or `let cell = Segment.get seg i` binding captures the live heap pointer before the CAS. Missing this caveat would lead to silent spurious CAS failures that manifest as liveness bugs, not crashes.