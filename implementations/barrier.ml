(** A cyclic barrier for a fixed number of parties, backed by SQS.

    All [parties] fibres must call [arrive] before any of them unblocks.
    The last to arrive resumes all waiting fibres.

    Algorithm: §6.2 of the CQS paper (Listing 7), extended with SMART
    cancellation as in the Kotlin reference implementation.

    Cancellation: the [on_cancellation] handler decrements [arrived] in a
    CAS loop.  If all parties have already arrived (a set of [resume] calls
    is in flight), it returns false so the cell is marked REFUSE and the
    Unit permit is discarded — exactly the same semantics as the Kotlin
    [Barrier.onCancellation]. *)

open Sqs_effects

type t = {
  sqs     : unit sqs;
  parties : int;
  arrived : int Atomic.t;
}

let make parties =
  let t_ref = ref None in
  let get_t () = match !t_ref with Some t -> t | None -> assert false in
  let sqs =
    make
      ~resume_mode:Async
      ~cancellation_mode:Smart
      ~on_cancellation:(fun () ->
        (* Undo the arrival: CAS-decrement [arrived].
           If all parties have already arrived the [resume] batch is
           already dispatched; return false → cell → REFUSE. *)
        let rec loop () =
          let cur = Atomic.get (get_t ()).arrived in
          if cur = (get_t ()).parties then false
          else if Atomic.compare_and_set (get_t ()).arrived cur (cur - 1)
          then true
          else loop ()
        in
        loop ())
      ()
  in
  let t = { sqs; parties; arrived = Atomic.make 0 } in
  t_ref := Some t;
  t

(** Register this fibre as having reached the barrier point.

    Returns [true] on success.  Returns [false] if more fibres than
    [parties] attempt to arrive (excess arrivals are ignored).

    All fibres except the last suspend; the last one resumes all others.
    Must be called from within a {!run} handler for all but the last party
    (the last party only calls [resume], which never suspends). *)
let arrive t =
  (* Fast-path guard: bail out without incrementing if already full. *)
  if Atomic.get t.arrived >= t.parties then false
  else begin
    let a = Atomic.fetch_and_add t.arrived 1 + 1 in
    if a < t.parties then begin
      (* Not the last party — park until the last one wakes us. *)
      let (_ : unit) = suspend t.sqs in
      true
    end else if a = t.parties then begin
      (* Last party — wake all predecessors. *)
      for _ = 1 to t.parties - 1 do ignore (resume t.sqs ()) done;
      true
    end else
      false   (* excess arrival due to race after the fast-path check *)
  end
