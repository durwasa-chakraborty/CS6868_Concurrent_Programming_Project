(** Segment Queue Synchronizer — OCaml 5 Effects edition.

    This version replaces the callback-based [Waiter of ('a -> unit)] with a
    genuine first-class continuation captured via {!Light_thread}.

      * {!suspend} [sqs] — parks the current {!Light_thread} in the next
                           available cell.  Returns the value delivered by
                           the matching {!resume}.

      * {!resume} [sqs v] — dequeues the next live continuation and resumes
                            it with [v], exactly as
                            [CancellableContinuation.resume] does in Kotlin.

    The cell state machine, segment linked-list, SYNC/ASYNC resume modes, and
    SIMPLE/SMART cancellation modes are all preserved from the callback
    version ([Segment_queue_synchronizer]).  The structural changes are:

    - [Waiter of ('a -> unit)]  →  [Waiter of 'a Light_thread.t]
    - [Cancelling of ('a->unit)]→  [Cancelling of 'a Light_thread.t]
    - The [Suspend] effect and its handler are now owned by {!Light_thread}.
    - {!suspend} closes over {!park_continuation} and passes it as the
      [register] callback to [Light_thread.suspend].

    -------------------------------------------------------------------------
    File organisation
    -------------------------------------------------------------------------

    1.  Types          — all mutually-recursive core types in one block.
    2.  Segment        — cell accessors and linked-list traversal.
    3.  SQS core       — constructor, internal helpers, resume/try_resume_impl,
                         cancellation, park_continuation, suspend, run.
    4.  Debug          — pretty printer and state dump.
    5.  Primitives     — Semaphore and Mutex built on top of SQS.

    -------------------------------------------------------------------------
    Key design decisions
    -------------------------------------------------------------------------

    1.  [Waiter] carries a [Light_thread.t] (a heap pointer) so it can be
        CAS-ed into a cell atomically.

    2.  Cancellation discontinues the parked continuation with the [Cancelled]
        exception, mirroring Kotlin's [invokeOnCancellation] hook.

    3.  Because OCaml 5 continuations are *linear*, we never resume or
        discontinue a continuation more than once.  The [Resumed] sentinel
        enforces this at the cell level.

    4.  Prompt cancellation is handled by catching [Cancelled] in the
        [resume] dispatch path and calling [return_value].
*)

(* ====================================================================== *)
(*  0.  Exception                                                          *)
(* ====================================================================== *)

(** Raised when a suspended continuation is cancelled.
    OCaml's type-directed constructor disambiguation ensures that bare
    [Cancelled] in a [cell_state] match arm resolves to the type constructor,
    while [Cancelled] where an [exn] is expected resolves to this exception. *)
exception Cancelled

(* ====================================================================== *)
(*  1.  Configuration types                                                *)
(* ====================================================================== *)

type resume_mode       = Sync | Async
type cancellation_mode = Simple | Smart

(* ====================================================================== *)
(*  2.  Core types (one mutual-recursion block)                            *)
(* ====================================================================== *)

(** Alias for a parked light thread — keeps cell_state signatures readable. *)
type 'a cont = 'a Light_thread.t

(** Cell state machine.
    [Cancelled] here is the *cell* state; it is distinct from the
    [Cancelled] *exception* above — the type system disambiguates them. *)
type 'a cell_state =
  | Empty                   (** No suspend or resume has visited yet. *)
  | Waiter     of 'a cont   (** A live continuation is parked here. *)
  | Cancelling of 'a cont   (** Cancellation in progress; cont not yet
                                 discontinued. *)
  | Cancelled               (** Cell is logically dead; resume skips it. *)
  | Refuse                  (** The resume arriving here must be refused. *)
  | Resumed                 (** Continuation was successfully resumed; slot
                                 cleared to avoid retaining a live cont. *)
  | Taken                   (** Value grabbed by a concurrent suspend
                                 (elimination path). *)
  | Broken                  (** SYNC race timed out; both sides fail. *)
  | Value      of 'a        (** Resume arrived before suspend; value parked. *)
  | WrappedValue of 'a      (** As [Value] but distinguishes a value that
                                 would otherwise look like a [Waiter] in
                                 SMART/ASYNC race resolution. *)

and 'a segment = {
  id              : int;
  cells           : 'a cell_state Atomic.t array;
  next            : 'a segment option Atomic.t;
  prev            : 'a segment option Atomic.t;
  cancelled_count : int Atomic.t;
  (** Number of "pointer" references to this segment held by the SQS
      head/tail fields.  Segments with zero live cells and zero pointers
      may be physically removed. *)
  pointers        : int Atomic.t;
}

and 'a t = {
  resume_segment           : 'a segment Atomic.t;
  resume_idx               : int Atomic.t;
  suspend_segment          : 'a segment Atomic.t;
  suspend_idx              : int Atomic.t;
  resume_mode              : resume_mode;
  cancellation_mode        : cancellation_mode;
  on_cancellation          : unit -> bool;
  try_return_refused_value : 'a -> bool;
  return_value             : 'a -> unit;
}

(** Public aliases so callers can name the type without shadowing [t]. *)
type 'a sqs                        = 'a t
type 'a segment_queue_synchronizer = 'a t

(* ====================================================================== *)
(*  3.  Segment module                                                     *)
(* ====================================================================== *)

(** Segment construction, cell-level atomic operations, and linked-list
    traversal.  Pure segment mechanics — no SQS protocol knowledge. *)
module Segment = struct

  (** Number of cells per segment.  Power of two keeps index arithmetic
      cheap: [idx / size] and [idx mod size]. *)
  let size = 16

  let make id prev_opt pointers =
    { id
    ; cells           = Array.init size (fun _ -> Atomic.make Empty)
    ; next            = Atomic.make None
    ; prev            = Atomic.make prev_opt
    ; cancelled_count = Atomic.make 0
    ; pointers        = Atomic.make pointers
    }

  (** Read cell [i]. *)
  let get seg i = Atomic.get seg.cells.(i)

  (** Unconditionally overwrite cell [i]. *)
  let set seg i v = Atomic.set seg.cells.(i) v

  (** CAS on cell [i].  Returns [true] if the swap succeeded. *)
  let cas seg i expected desired =
    Atomic.compare_and_set seg.cells.(i) expected desired

  (** Atomic exchange on cell [i].  Returns the *old* value. *)
  let xchg seg i v = Atomic.exchange seg.cells.(i) v

  (** Increment the cancelled count.  Once every cell in the segment is
      cancelled, physically unlink the segment so it can be collected. *)
  let on_slot_cleaned seg =
    let n = Atomic.fetch_and_add seg.cancelled_count 1 + 1 in
    if n = size then
      match Atomic.get seg.prev with
      | None -> ()
      | Some prev_seg ->
        let rec try_unlink () =
          match Atomic.get prev_seg.next with
          | Some cur when cur == seg ->
            let nxt = Atomic.get seg.next in
            if not (Atomic.compare_and_set prev_seg.next (Some seg) nxt)
            then try_unlink ()
          | _ -> ()
        in
        try_unlink ()

  (** Walk forward from [start] until we find or create the segment with
      [id = target_id].  Atomically advances [seg_ref] along the way.
      [make_seg id prev] allocates a new segment when needed. *)
  let find_and_advance seg_ref target_id start make_seg =
    let rec walk cur =
      if cur.id = target_id then begin
        ignore (Atomic.compare_and_set seg_ref (Atomic.get seg_ref) cur);
        cur
      end else if cur.id > target_id then begin
        (* Required segment was physically removed (all cells cancelled);
           return the first surviving segment so the caller can detect this. *)
        ignore (Atomic.compare_and_set seg_ref (Atomic.get seg_ref) cur);
        cur
      end else begin
        let nxt =
          match Atomic.get cur.next with
          | Some s -> s
          | None   ->
            let s = make_seg (cur.id + 1) (Some cur) in
            if Atomic.compare_and_set cur.next None (Some s) then s
            else (match Atomic.get cur.next with
                  | Some s -> s
                  | None   -> assert false)
        in
        walk nxt
      end
    in
    walk start

end (* Segment *)

(* ====================================================================== *)
(*  4.  Constants                                                          *)
(* ====================================================================== *)

let segment_size    = Segment.size
let max_spin_cycles = 100

(* ====================================================================== *)
(*  5.  SQS constructor                                                    *)
(* ====================================================================== *)

let make
    ?(resume_mode              = Sync)
    ?(cancellation_mode        = Simple)
    ?(on_cancellation          = fun () -> false)
    ?(try_return_refused_value = fun _  -> true)
    ?(return_value             = fun _  -> ())
    ()
  =
  let s = Segment.make 0 None 2 in
  { resume_segment           = Atomic.make s
  ; resume_idx               = Atomic.make 0
  ; suspend_segment          = Atomic.make s
  ; suspend_idx              = Atomic.make 0
  ; resume_mode
  ; cancellation_mode
  ; on_cancellation
  ; try_return_refused_value
  ; return_value
  }

(* ====================================================================== *)
(*  6.  Internal helpers                                                   *)
(* ====================================================================== *)

let return_refused_value sqs v =
  if not (sqs.try_return_refused_value v) then sqs.return_value v

(** Atomically advance [resume_idx] to at least [target] (never decrements). *)
let adjust_resume_idx sqs target =
  let rec loop () =
    let cur = Atomic.get sqs.resume_idx in
    if cur < target then
      if not (Atomic.compare_and_set sqs.resume_idx cur target)
      then loop ()
  in
  loop ()

(** Allocate a fresh segment on behalf of [sqs] at [id] with [prev]. *)
let new_seg _sqs id prev = Segment.make id prev 0

(* ====================================================================== *)
(*  7.  suspend_cancelled                                                  *)
(* ====================================================================== *)

(** [suspend_cancelled sqs] is the non-blocking variant of [suspend]: it
    claims a slot by installing [Cancelled] directly.  Returns [Some v] if
    an elimination happened (a concurrent [resume] had already deposited [v]),
    [None] otherwise. *)
let suspend_cancelled (sqs : 'a t) : 'a option =
  let cur_seg = Atomic.get sqs.suspend_segment in
  let idx     = Atomic.fetch_and_add sqs.suspend_idx 1 in
  let seg     =
    Segment.find_and_advance
      sqs.suspend_segment (idx / segment_size) cur_seg
      (new_seg sqs)
  in
  let i = idx mod segment_size in
  if Segment.cas seg i Empty Cancelled then
    None
  else begin
    let cell = Segment.get seg i in
    match cell with
    | Broken -> None
    | Value v | WrappedValue v ->
      if Segment.cas seg i cell Taken then Some v else None
    | _ -> None
  end

(* ====================================================================== *)
(*  8.  resume / try_resume_impl  (mutually recursive)                    *)
(* ====================================================================== *)

type try_resume_result = TryResumeSuccess | TryResumeCancelled | TryResumeBroken

(** [resume sqs value] dequeues the next live waiter and resumes it with
    [value].  In SMART cancellation mode, cancelled cells are skipped.
    Returns [true] on success, [false] on failure. *)
let rec resume (sqs : 'a t) (value : 'a) : bool =
  let skip_cancelled = sqs.cancellation_mode <> Simple in
  let rec loop () =
    match try_resume_impl sqs value skip_cancelled with
    | TryResumeSuccess   -> true
    | TryResumeCancelled -> if skip_cancelled then loop () else false
    | TryResumeBroken    -> false
  in
  loop ()

(** Single attempt to deliver [value] to the next cell.  [adjust] controls
    whether [resume_idx] is fast-forwarded past a physically removed segment. *)
and try_resume_impl (sqs : 'a t) (value : 'a) (adjust : bool) : try_resume_result =
  let cur_seg = Atomic.get sqs.resume_segment in
  let idx     = Atomic.fetch_and_add sqs.resume_idx 1 in
  let id      = idx / segment_size in
  let seg     =
    Segment.find_and_advance
      sqs.resume_segment id cur_seg (new_seg sqs)
  in
  (* Clear the backwards pointer so the previous segment can be collected. *)
  Atomic.set seg.prev None;
  if seg.id > id then begin
    (* The required segment was physically removed (all cells cancelled). *)
    if adjust then adjust_resume_idx sqs (seg.id * segment_size);
    TryResumeCancelled
  end else begin
    let i = idx mod segment_size in
    let rec cell_loop () =
      match Segment.get seg i with

      (* ---------------------------------------------------------------- *)
      (*  Empty — resume arrived before suspend                           *)
      (* ---------------------------------------------------------------- *)
      | Empty ->
        if not (Segment.cas seg i Empty (Value value)) then cell_loop ()
        else if sqs.resume_mode = Async then
          TryResumeSuccess
        else begin
          (* SYNC: spin-wait for a concurrent suspend to claim the value. *)
          let rec spin n =
            if n = 0 then
              if Segment.cas seg i (Value value) Broken
              then TryResumeBroken
              else TryResumeSuccess   (* suspend grabbed it at the last instant *)
            else
              match Segment.get seg i with
              | Taken -> TryResumeSuccess
              | _     -> spin (n - 1)
          in
          spin max_spin_cycles
        end

      (* ---------------------------------------------------------------- *)
      (*  Cancelled — skip (caller decides whether to retry)              *)
      (* ---------------------------------------------------------------- *)
      | Cancelled -> TryResumeCancelled

      (* ---------------------------------------------------------------- *)
      (*  Refuse — return the value to the outer data structure           *)
      (* ---------------------------------------------------------------- *)
      | Refuse ->
        return_refused_value sqs value;
        TryResumeSuccess

      (* ---------------------------------------------------------------- *)
      (*  Live waiter — attempt to resume the continuation                *)
      (* ---------------------------------------------------------------- *)
      | Waiter k ->
        (* Atomically claim the cell so [handle_cancellation] cannot
           discontinue the continuation after we decide to resume it. *)
        if not (Segment.cas seg i (Waiter k) Resumed) then cell_loop ()
        else begin
          (* Deliver the value.  [Cancelled] propagates if the continuation
             raises it during dispatch (prompt cancellation). *)
          let delivered =
            match Light_thread.resume k value with
            | ()                  -> true
            | exception Cancelled -> false
          in
          if delivered then
            TryResumeSuccess
          else begin
            match sqs.cancellation_mode with
            | Simple -> TryResumeCancelled
            | Smart  ->
              if sqs.on_cancellation () then begin
                if not (resume sqs value) then sqs.return_value value
              end else
                return_refused_value sqs value;
              TryResumeSuccess
          end
        end

      (* ---------------------------------------------------------------- *)
      (*  Cancelling — cancellation handler is in flight                  *)
      (* ---------------------------------------------------------------- *)
      | Cancelling _ as curr ->
        (match sqs.cancellation_mode with
         | Simple -> TryResumeCancelled
         | Smart  ->
           match sqs.resume_mode with
           | Sync ->
             (* Spin-wait for the cancellation handler to resolve the cell
                to [Cancelled] or [Refuse]. *)
             cell_loop ()
           | Async ->
             (* Deposit the value using [curr] as the CAS expected value —
                not a fresh read — to avoid a TOCTOU race. *)
             if Segment.cas seg i curr (Value value)
             then TryResumeSuccess
             else cell_loop ())

      (* ---------------------------------------------------------------- *)
      (*  Terminal states — should not appear at this point               *)
      (* ---------------------------------------------------------------- *)
      | Resumed | Taken | Broken | Value _ | WrappedValue _ ->
        TryResumeBroken
    in
    cell_loop ()
  end

(* ====================================================================== *)
(*  9.  Cancellation state machine                                         *)
(* ====================================================================== *)

(** Atomically move cell [i] from [Waiter k] to [Cancelling k].
    Returns [false] if the cell is already [Resumed] (the continuation was
    already handed off to [resume]; prompt cancellation applies instead). *)
let try_mark_cancelling seg i =
  let rec loop () =
    match Segment.get seg i with
    | Resumed      -> false
    | Waiter k     ->
      if Segment.cas seg i (Waiter k) (Cancelling k) then true
      else loop ()           (* CAS race: retry *)
    | Cancelling _ -> true   (* another thread already started this *)
    | _            -> false
  in
  loop ()

(** Atomically replace the cell at [i] with [marker] ([Cancelled] or
    [Refuse]) and return any value a concurrent ASYNC [resume] may have
    deposited while the cell was in [Cancelling] state. *)
let mark_impl seg i marker =
  match Segment.xchg seg i marker with
  | Cancelling _   -> None
  | Value v        -> Some v
  | WrappedValue v -> Some v
  | _              -> None   (* should not happen in a correct execution *)

let mark_cancelled sqs seg i =
  let r = mark_impl seg i Cancelled in
  Segment.on_slot_cleaned seg;
  ignore sqs; r

let mark_refuse seg i = mark_impl seg i Refuse

(** Discontinue a parked continuation with [Cancelled].
    OCaml equivalent of invoking [invokeOnCancellation] in Kotlin. *)
let discontinue_cont k =
  Light_thread.discontinue k Cancelled

(** Drive the cancellation of the waiter parked in cell [i] of [seg].
    Mirrors [SQSSegment.onCancellation] in Kotlin. *)
let handle_cancellation sqs seg i =
  if not (try_mark_cancelling seg i) then
    (* Cell is already Resumed — prompt cancellation; [resume] handles it. *)
    ()
  else begin
    let cont =
      match Segment.get seg i with
      | Cancelling k -> k
      | _            -> assert false   (* try_mark_cancelling guarantees this *)
    in
    match sqs.cancellation_mode with
    | Simple ->
      ignore (mark_cancelled sqs seg i);
      discontinue_cont cont
    | Smart ->
      if sqs.on_cancellation () then begin
        (* Cell → CANCELLED.  If an async resume sneaked a value in while
           we were in the Cancelling state, forward that resume. *)
        (match mark_cancelled sqs seg i with
         | None   -> ()
         | Some v -> if not (resume sqs v) then sqs.return_value v);
        discontinue_cont cont
      end else begin
        (* Cell → REFUSE.  The next resume that arrives here will be refused. *)
        (match mark_refuse seg i with
         | None   -> ()
         | Some v -> return_refused_value sqs v);
        discontinue_cont cont
      end
  end

(** Manually cancel the waiter at cell [i] of [seg].
    Equivalent to the [invokeOnCancellation] handler on a
    [CancellableContinuation] in Kotlin. *)
let cancel_waiter sqs seg i = handle_cancellation sqs seg i

(* ====================================================================== *)
(*  10.  park_continuation                                                 *)
(* ====================================================================== *)

(** Internal: called by {!suspend} as the [register] callback passed to
    [Light_thread.suspend].  Parks the captured continuation [k] in the next
    available SQS cell.

    If a concurrent [resume] had already deposited a value (elimination path),
    [k] is resumed immediately via [Light_thread.resume].  If the cell is
    broken (SYNC race), [k] is discontinued.

    Returns [true] if [k] was enqueued or eliminated, [false] on a broken
    SYNC race. *)
let park_continuation (sqs : 'a t) (k : 'a cont) : bool =
  let cur_seg = Atomic.get sqs.suspend_segment in
  let idx     = Atomic.fetch_and_add sqs.suspend_idx 1 in
  let seg     =
    Segment.find_and_advance
      sqs.suspend_segment (idx / segment_size) cur_seg
      (new_seg sqs)
  in
  let i = idx mod segment_size in
  if Segment.cas seg i Empty (Waiter k) then
    (* Successfully parked.  A future [resume] will call
       [Light_thread.resume k value] to wake this fibre.
       Cancellation is triggered externally via [cancel_waiter]. *)
    true
  else begin
    (* A concurrent [resume] already deposited something.
       Read the cell *once* and use that snapshot for the CAS to avoid a
       TOCTOU race between the read and the compare-and-swap. *)
    let cell = Segment.get seg i in
    match cell with
    | Broken ->
      Light_thread.discontinue k Cancelled;
      false
    | Value v | WrappedValue v ->
      (* Elimination: claim the value atomically using the matched [cell] as
         the CAS expected value — not a second [Segment.get]. *)
      if Segment.cas seg i cell Taken then begin
        Light_thread.resume k v;
        true
      end else begin
        Light_thread.discontinue k Cancelled;
        false
      end
    | _ ->
      Light_thread.discontinue k Cancelled;
      false
  end

(* ====================================================================== *)
(*  11.  suspend / run                                                     *)
(* ====================================================================== *)

(** [suspend sqs] parks the current light thread in [sqs].

    Delegates to {!Light_thread.suspend}, passing {!park_continuation} as
    the [register] callback.  The continuation is captured by
    [Light_thread.suspend] and handed to [park_continuation], which slots it
    into the SQS cell.

    Must be called from within a {!run} handler.  Returns the value delivered
    by the matching [resume], or raises [Cancelled] if the waiter is
    discontinued. *)
let suspend (sqs : 'a t) : 'a =
  Light_thread.suspend (fun k -> ignore (park_continuation sqs k))

(** [run f] executes [f ()] with the {!Light_thread} handler installed,
    making [suspend] and [resume] available inside [f].

    This is a direct re-export of {!Light_thread.run}.  See that module for
    full documentation.

    Typical usage — launching a fibre and later resuming it externally:
    {[
      let sqs = Sqs_effects.make () in
      run (fun () ->
        let v = suspend sqs in     (* parks here *)
        Printf.printf "got %d\n" v);
      ignore (resume sqs 42)       (* wakes the fibre with 42 *)
    ]} *)
let run = Light_thread.run

(* ====================================================================== *)
(*  12.  Debug                                                             *)
(* ====================================================================== *)

(** Diagnostic utilities — not required for correctness. *)
module Debug = struct

  let pp_cell_state fmt = function
    | Empty          -> Format.pp_print_string fmt "Empty"
    | Waiter _       -> Format.pp_print_string fmt "<cont>"
    | Cancelling _   -> Format.pp_print_string fmt "CANCELLING"
    | Cancelled      -> Format.pp_print_string fmt "CANCELLED"
    | Refuse         -> Format.pp_print_string fmt "REFUSE"
    | Resumed        -> Format.pp_print_string fmt "RESUMED"
    | Taken          -> Format.pp_print_string fmt "TAKEN"
    | Broken         -> Format.pp_print_string fmt "BROKEN"
    | Value _        -> Format.pp_print_string fmt "<value>"
    | WrappedValue _ -> Format.pp_print_string fmt "<wrapped-value>"

  let dump sqs =
    let si = Atomic.get sqs.suspend_idx in
    let ri = Atomic.get sqs.resume_idx  in
    Printf.printf "suspendIdx=%d resumeIdx=%d\n" si ri;
    let seg_r = ref (Atomic.get sqs.resume_segment) in
    let idx_r = ref ri in
    let limit  = max si ri in
    while !idx_r < limit do
      let seg = !seg_r in
      let i   = !idx_r mod segment_size in
      let s   =
        if !idx_r < seg.id * segment_size then "CANCELLED"
        else Format.asprintf "%a" pp_cell_state (Segment.get seg i)
      in
      Printf.printf "  [%d] %s\n" !idx_r s;
      incr idx_r;
      if !idx_r = (seg.id + 1) * segment_size then
        match Atomic.get seg.next with
        | Some nxt -> seg_r := nxt
        | None     -> idx_r := limit
    done

end (* Debug *)

(** Convenience re-exports so callers don't need to qualify [Debug.*]. *)
let pp_cell_state = Debug.pp_cell_state
let dump          = Debug.dump

(* ====================================================================== *)
(*  13.  Semaphore                                                         *)
(* ====================================================================== *)

(** A fair counting semaphore built on top of SQS.

    [acquire] suspends the caller if no permits are available.
    [release] delivers a permit to the next waiter, or increments the
    counter if none is waiting.

    Callers of [acquire] must be running inside a {!run} handler. *)
module Semaphore = struct

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

  (** [release t] increments the permit count and delivers a permit to the
      next waiting fibre, if any. *)
  let release t =
    let p = Atomic.fetch_and_add t.permits 1 in
    if p < 0 then ignore (resume t.sqs ())

end (* Semaphore *)

(* ====================================================================== *)
(*  14.  Mutex                                                             *)
(* ====================================================================== *)

(** A fair mutex backed by SQS.

    [lock callback] acquires the mutex and runs [callback] under it.
    [unlock] releases the mutex and wakes the next queued waiter, if any.

    The callback-style API avoids the need to pair every [lock] with an
    [unlock] manually, mirroring coroutine-scoped critical sections in Kotlin.
    If the mutex is contended, [lock] installs a {!run} handler internally so
    [suspend] can park the caller. *)
module Mutex = struct

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
      run (fun () ->
        match suspend m.sqs with
        | ()                  -> callback ()
        | exception Cancelled -> ())

  let unlock m =
    if not (resume m.sqs ()) then
      Atomic.set m.locked false

end (* Mutex *)
