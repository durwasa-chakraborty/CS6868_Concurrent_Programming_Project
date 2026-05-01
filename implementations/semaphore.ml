(** Counting semaphore backed by SQS. *)

open Sqs_effects

type t = {
  sqs     : unit sqs;
  permits : int Atomic.t;
}

let make n =
  (* ASYNC: [release] returns immediately after depositing the permit.
     SMART: if an acquirer cancels, [on_cancellation] returns the permit. *)
  let t_ref = ref None in
  let sqs =
    make
      ~resume_mode:Async
      ~cancellation_mode:Smart
      ~on_cancellation:(fun () ->
        let t = match !t_ref with Some t -> t | None -> assert false in
        let rec try_inc () =
          let cur = Atomic.get t.permits in
          if not (Atomic.compare_and_set t.permits cur (cur + 1))
          then try_inc ()
        in
        try_inc (); true)
      ~return_value:(fun () ->
        let t = match !t_ref with Some t -> t | None -> assert false in
        ignore (Atomic.fetch_and_add t.permits 1))
      ()
  in
  let t = { sqs; permits = Atomic.make n } in
  t_ref := Some t;
  t

(** [acquire t] decrements the permit count.  If it reaches zero (or
    below), the calling fibre suspends until [release] delivers a permit.
    Must be called from within a {!run} handler. *)
let acquire t =
  let p = Atomic.fetch_and_add t.permits (-1) in
  if p > 0 then ()
  else let (_ : unit) = suspend t.sqs in ()

(** [try_acquire t] takes a permit if one is available and returns [true],
    otherwise returns [false] without suspending.  Never wakes a waiter
    and never consumes a reservation held by a parked [acquire]. *)
let try_acquire t =
  let rec loop () =
    let cur = Atomic.get t.permits in
    if cur <= 0 then false
    else if Atomic.compare_and_set t.permits cur (cur - 1) then true
    else loop ()
  in
  loop ()

(** Current number of permits available (never negative). *)
let available_permits t = max 0 (Atomic.get t.permits)

(** [release t] increments the permit count and delivers a permit to the
    next waiting fibre, if any. *)
let release t =
  let p = Atomic.fetch_and_add t.permits 1 in
  if p < 0 then ignore (resume t.sqs ())
