(** A blocking resource pool backed by a FIFO (infinite-array) queue.

    [put] deposits an element; [retrieve] takes one, suspending if the pool
    is empty.  Waiting [retrieve] calls are served in FIFO order.

    Algorithm: §7 of the CQS paper (Listings 16–17, queue variant).

    The backing store is a flat array of atomic slots indexed by two
    monotonically increasing counters ([insert_idx] / [retrieve_idx]).
    When a [retrieve] arrives at an empty slot before the matching [put], it
    marks the slot [Slot_broken] so the paired [put] detects the race and
    retries the whole operation.

    Cancellation mode: SIMPLE (default).  A cancelled [retrieve] causes the
    matching [put] to receive [false] from [resume] and retry. *)

open Sqs_effects

(** Three-state cell in the backing array.
    - [Slot_empty]    — slot allocated but not yet written by [put].
    - [Slot_value v]  — [put] has deposited [v]; [retrieve] may claim it.
    - [Slot_broken]   — [retrieve] arrived first and marked the slot;
                        the paired [put] must retry. *)
type 'a slot = Slot_empty | Slot_value of 'a | Slot_broken

type 'a t = {
  sqs         : 'a sqs;
  available   : int Atomic.t;
  slots       : 'a slot Atomic.t array;
  insert_idx  : int Atomic.t;
  retrieve_idx: int Atomic.t;
}

(** Upper bound on simultaneously resident elements.  The paper uses an
    unbounded array; a large constant suffices for practical use. *)
let slot_count = 1024

(** Try to deposit [element] in the next free slot.
    Returns [false] if the slot was already broken by a racing [retrieve]. *)
let try_insert t element =
  let i = Atomic.fetch_and_add t.insert_idx 1 in
  Atomic.compare_and_set t.slots.(i) Slot_empty (Slot_value element)

(** Try to take the oldest element from the backing array.
    Atomically exchanges the slot with [Slot_broken] — if the old value
    was [Slot_value v] we return [Some v]; otherwise the slot was empty
    (now broken for the paired [put]) and we return [None]. *)
let try_retrieve t =
  let i = Atomic.fetch_and_add t.retrieve_idx 1 in
  match Atomic.exchange t.slots.(i) Slot_broken with
  | Slot_value v              -> Some v
  | Slot_empty | Slot_broken  -> None

(** Deposit [element] into the pool.
    If a [retrieve] is waiting, resume it directly; otherwise insert into
    the backing array.  Retries on cancellation (SIMPLE mode) or slot race.
    May be called from any context. *)
let rec put t element =
  let s = Atomic.fetch_and_add t.available 1 in
  if s < 0 then begin
    (* There is a suspended [retrieve] — wake it. *)
    if not (resume t.sqs element) then put t element
  end else begin
    (* No waiters — try to deposit in the array. *)
    if not (try_insert t element) then put t element
  end

let make () =
  { sqs          = make ~resume_mode:Async ()   (* SIMPLE cancellation *)
  ; available    = Atomic.make 0
  ; slots        = Array.init slot_count (fun _ -> Atomic.make Slot_empty)
  ; insert_idx   = Atomic.make 0
  ; retrieve_idx = Atomic.make 0
  }

(** Take one element from the pool, suspending if it is empty.
    Must be called from within a {!run} handler. *)
let retrieve t =
  let rec loop () =
    let s = Atomic.fetch_and_add t.available (-1) in
    if s > 0 then begin
      match try_retrieve t with
      | Some v -> v
      | None   -> loop ()
    end else
      suspend t.sqs
  in
  loop ()
