(** A mutex backed by SQS.

    [lock callback] acquires the mutex and runs [callback] under it.
    [unlock] releases the mutex and wakes the next queued waiter, if any.

    Fast path
    =========
    When the mutex is uncontended, neither [lock] nor [unlock] touches the
    SQS:
    - [lock]   succeeds via a single CAS on [locked].
    - [unlock] writes [false] to [locked] and reads [waiters]; if no waiter
               is parked, no SQS work is done.

    Slow path
    =========
    On contention [lock] increments [waiters] and parks via [suspend].  A
    matching [unlock] reads [waiters > 0] and calls [resume], which either
    wakes a parked waiter or deposits a value to be consumed by a future
    waiter (an SQS-internal "spurious wakeup").  In either case the woken
    waiter retries the CAS — this is the standard test-and-test-and-set
    parking pattern; see also [java.util.concurrent.locks.ReentrantLock]
    (non-fair mode).

    Both [lock] and [unlock] must be called from within a {!Sqs_effects.run}
    context (i.e. inside an Eio fibre) when the mutex may be contended. *)

open Sqs_effects

type t = {
  sqs     : unit sqs;
  locked  : bool Atomic.t;
  (* Count of fibres that have entered the slow path but not yet returned.
     [unlock] uses this to decide whether to call [resume]; if [waiters = 0]
     no SQS interaction is needed. *)
  waiters : int Atomic.t;
}

let make () =
  { sqs     = make ~resume_mode:Async ~cancellation_mode:Smart ()
  ; locked  = Atomic.make false
  ; waiters = Atomic.make 0
  }

let lock m callback =
  if Atomic.compare_and_set m.locked false true then
    callback ()
  else begin
    Atomic.incr m.waiters;
    let rec attempt () =
      if Atomic.compare_and_set m.locked false true then begin
        Atomic.decr m.waiters;
        callback ()
      end else
        match suspend m.sqs with
        | ()                  -> attempt ()
        | exception Cancelled -> Atomic.decr m.waiters
    in
    attempt ()
  end

let unlock m =
  Atomic.set m.locked false;
  if Atomic.get m.waiters > 0 then
    ignore (resume m.sqs ())
