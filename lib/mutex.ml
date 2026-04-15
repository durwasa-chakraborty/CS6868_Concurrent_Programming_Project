(** A fair mutex backed by SQS.

    [lock callback] acquires the mutex and runs [callback] under it.
    [unlock] releases the mutex and wakes the next queued waiter, if any.

    The callback-style API avoids the need to pair every [lock] with an
    [unlock] manually, mirroring coroutine-scoped critical sections in Kotlin.
    Both [lock] and [unlock] must be called from within a {!run} context
    (i.e. inside an Eio fibre) when the mutex may be contended. *)

open Sqs_effects

type t = {
  sqs    : unit sqs;
  locked : bool Atomic.t;
}

let make () =
  { sqs    = make ~resume_mode:Async ~cancellation_mode:Smart ()
  ; locked = Atomic.make false
  }

let lock m callback =
  if Atomic.compare_and_set m.locked false true then
    callback ()   (* acquired immediately — no suspension needed *)
  else
    (* Already inside an Eio fibre; suspend directly without wrapping in
       a new [run] context (Eio_main.run must not be nested). *)
    match suspend m.sqs with
    | ()                  -> callback ()
    | exception Cancelled -> ()

let unlock m =
  if not (resume m.sqs ()) then
    Atomic.set m.locked false
