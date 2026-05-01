(** A count-down latch backed by SQS.

    Initialised with a count [n].  Each [count_down] decrements the counter;
    when it reaches zero every [await] caller that was suspended is resumed.
    Future [await] calls return immediately.

    Algorithm: §6.3 of the CQS paper (Listing 8).

    Two atomic counters share the synchronisation:
    - [count]   — number of remaining [count_down] calls.
    - [waiters] — number of registered [await] suspensions.
      The high bit ([done_bit]) is set atomically by the thread that drives
      [count] to zero, making further [await] suspensions unnecessary.

    Cancellation mode: SMART.  When an [await] is cancelled, [on_cancellation]
    decrements [waiters].  If [done_bit] was already set the matched [resume]
    is already in flight; the cell is marked REFUSE and the Unit permit is
    silently discarded via [return_value]. *)

open Sqs_effects

(** Sentinel bit packed into [waiters].  Signals that [count] has reached
    zero and all in-flight [resume] calls have been dispatched.
    Using [Sys.int_size - 2] keeps the value positive on both 31-bit and
    63-bit OCaml platforms. *)
let done_bit = 1 lsl (Sys.int_size - 2)

type t = {
  sqs     : unit sqs;
  count   : int Atomic.t;
  waiters : int Atomic.t;
}

let make init_count =
  let t_ref = ref None in
  let get_t () = match !t_ref with Some t -> t | None -> assert false in
  let sqs =
    make
      ~resume_mode:Async
      ~cancellation_mode:Smart
      ~on_cancellation:(fun () ->
        (* Undo the [FAA +1] that [await] performed on [waiters].
           Return true  → [done_bit] was clear; cell → CANCELLED (safe to
                          skip the matching [resume]).
           Return false → [done_bit] was already set; a [resume] is coming
                          for this cell; cell → REFUSE so it is silently
                          consumed. *)
        let old = Atomic.fetch_and_add (get_t ()).waiters (-1) in
        (old land done_bit) = 0)
      (* completeRefusedResume: the Unit permit is irrelevant once the
         latch has fired; discard it (default return_value is a no-op). *)
      ()
  in
  let t = { sqs; count = Atomic.make init_count; waiters = Atomic.make 0 } in
  t_ref := Some t;
  t

(** Atomically mark [done_bit] in [waiters] and call [resume] once per
    registered waiter.  Only the first thread to succeed at the CAS does
    the resumptions; subsequent callers return immediately. *)
let resume_waiters t =
  let rec loop () =
    let w = Atomic.get t.waiters in
    if (w land done_bit) <> 0 then ()       (* another thread beat us *)
    else if not (Atomic.compare_and_set t.waiters w (w lor done_bit))
    then loop ()
    else
      (* [w] is the number of waiters registered *before* [done_bit] was
         set.  Resume each one; SMART mode handles any cancelled cells. *)
      for _ = 1 to w do ignore (resume t.sqs ()) done
  in
  loop ()

(** Decrement the count.  Resumes all [await]-ers when it reaches zero.
    May be called from any context (no [run] handler required). *)
let count_down t =
  let r = Atomic.fetch_and_add t.count (-1) in
  if r <= 1 then resume_waiters t

(** Suspend until [count] reaches zero, or return immediately if it
    already has.  Must be called from within a {!run} handler. *)
let await t =
  if Atomic.get t.count <= 0 then ()
  else begin
    (* [fetch_and_add] returns the *old* value; add 1 to get the value
       we actually deposited, then test it for [done_bit]. *)
    let w_new = Atomic.fetch_and_add t.waiters 1 + 1 in
    if (w_new land done_bit) <> 0 then ()   (* latch already fired *)
    else let (_ : unit) = suspend t.sqs in ()
  end

(** Return the number of remaining [count_down] calls (never negative). *)
let remaining t = max 0 (Atomic.get t.count)
