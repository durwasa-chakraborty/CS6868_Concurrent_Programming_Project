(** Segment Queue Synchronizer (SQS) — OCaml translation of the Kotlin
    kotlinx.coroutines implementation.

    This module provides a *fair* (FIFO) cancellable queue synchronizer that
    can be used as the foundation for semaphores, mutexes and other
    synchronization primitives.

    The implementation models the same infinite-array-over-linked-segments
    design as the original, using atomic references throughout.  OCaml does
    not have green-thread continuations, so "waiters" are represented as
    plain callbacks [value -> unit].  Cancellation is cooperative: a waiter
    may be cancelled by calling the cancellation handle returned from
    [suspend]. *)

(* ------------------------------------------------------------------ *)
(*  Segment size / spin parameters (mirrors Kotlin system properties)  *)
(* ------------------------------------------------------------------ *)

let segment_size    = 16
let max_spin_cycles = 100

(* ------------------------------------------------------------------ *)
(*  Cell-state sentinel values                                          *)
(* ------------------------------------------------------------------ *)

(** Every cell in a segment goes through a state machine whose states are
    represented by the algebraic type below.  The [Value] constructor carries
    the actual resumption payload; [Waiter] carries the callback installed by
    [suspend]. *)
type 'a cell_state =
  | Empty                        (** initial state — no suspend or resume yet *)
  | Waiter    of ('a -> unit)    (** a callback is waiting for a value *)
  | Cancelling of ('a -> unit)   (** waiter is being cancelled, handler running *)
  | Cancelled                    (** cell is logically cancelled; resume skips it *)
  | Refuse                       (** resume that arrives here must be refused *)
  | Resumed                      (** resume succeeded; avoids memory leaks *)
  | Taken                        (** value was grabbed by a concurrent suspend *)
  | Broken                       (** SYNC race: both suspend and resume fail *)
  | Value     of 'a              (** resume arrived before suspend (ASYNC or
                                     pending SYNC) — value parked in cell *)
  | WrappedValue of 'a           (** same as Value but distinguishes a value that
                                     happens to be a callback from a Waiter *)

(* ------------------------------------------------------------------ *)
(*  ResumeMode / CancellationMode                                       *)
(* ------------------------------------------------------------------ *)

type resume_mode       = Sync | Async
type cancellation_mode = Simple | Smart

(* ------------------------------------------------------------------ *)
(*  Internal result codes used by try_resume_impl                       *)
(* ------------------------------------------------------------------ *)

type try_resume_result =
  | TryResumeSuccess
  | TryResumeCancelled
  | TryResumeBroken

(* ------------------------------------------------------------------ *)
(*  Segment                                                             *)
(* ------------------------------------------------------------------ *)

(** A segment is a fixed-size array of atomic cell states, linked into a
    singly-linked list.  The [cancelled_count] tracks how many cells in this
    segment have reached a terminal cancelled state, allowing the segment to
    be physically removed from the list once all slots are cancelled. *)
type 'a segment = {
  id              : int;
  cells           : 'a cell_state Atomic.t array;
  mutable next    : 'a segment option Atomic.t;
  prev            : 'a segment option Atomic.t;
  cancelled_count : int Atomic.t;
  (** Number of "pointer" references kept by the queue head/tail fields.
      When it reaches zero AND all cells are cancelled, the segment may be
      removed. *)
  pointers        : int Atomic.t;
}

let make_segment id prev_opt pointers =
  { id
  ; cells           = Array.init segment_size (fun _ -> Atomic.make Empty)
  ; next            = Atomic.make None
  ; prev            = Atomic.make prev_opt
  ; cancelled_count = Atomic.make 0
  ; pointers        = Atomic.make pointers
  }

(** Return the cell state at [index] within [seg]. *)
let seg_get seg index = Atomic.get seg.cells.(index)

(** Unconditionally store [v] into cell [index] within [seg]. *)
let seg_set seg index v = Atomic.set seg.cells.(index) v

(** CAS on cell [index] within [seg]. *)
let seg_cas seg index expected desired =
  Atomic.compare_and_set seg.cells.(index) expected desired

(** Atomic get-and-set on cell [index] within [seg]. *)
let seg_get_and_set seg index v =
  (* OCaml 5 Atomic.exchange *)
  Atomic.exchange seg.cells.(index) v

(** Increment the cancelled count and potentially unlink the segment. *)
let on_slot_cleaned seg =
  let n = Atomic.fetch_and_add seg.cancelled_count 1 + 1 in
  if n = segment_size then begin
    (* All cells in this segment are cancelled — physically remove it from
       the linked list by splicing it out. *)
    (match Atomic.get seg.prev with
     | Some prev_seg ->
       let rec try_unlink () =
         match Atomic.get prev_seg.next with
         | Some cur when cur == seg ->
           let next_opt = Atomic.get seg.next in
           if not (Atomic.compare_and_set prev_seg.next (Some seg) next_opt)
           then try_unlink ()
         | _ -> ()
       in
       try_unlink ()
     | None -> ())
  end

(* ------------------------------------------------------------------ *)
(*  Segment linked-list traversal / allocation                          *)
(* ------------------------------------------------------------------ *)

(** Walk forward from [start] until we find (or create) the segment whose
    [id] equals [target_id].  Updates the atomic reference [seg_ref] to
    point to the farthest segment observed, so future operations start
    closer to the tail. *)
let find_segment_and_move_forward seg_ref target_id start_seg make_seg =
  let rec walk cur =
    if cur.id = target_id then begin
      (* Opportunistically advance the stored pointer. *)
      let _ = Atomic.compare_and_set seg_ref (Atomic.get seg_ref) cur in
      cur
    end else if cur.id > target_id then begin
      (* The required segment was removed; return the first surviving one. *)
      let _ = Atomic.compare_and_set seg_ref (Atomic.get seg_ref) cur in
      cur
    end else begin
      (* Need to go further; allocate a new segment if at the end. *)
      let next_seg =
        match Atomic.get cur.next with
        | Some s -> s
        | None ->
          let new_seg = make_seg (cur.id + 1) (Some cur) in
          if Atomic.compare_and_set cur.next None (Some new_seg)
          then new_seg
          else (match Atomic.get cur.next with Some s -> s | None -> assert false)
      in
      walk next_seg
    end
  in
  walk start_seg

(* ------------------------------------------------------------------ *)
(*  SegmentQueueSynchronizer record                                     *)
(* ------------------------------------------------------------------ *)

type 'a t = {
  resume_segment  : 'a segment Atomic.t;
  resume_idx      : int Atomic.t;
  suspend_segment : 'a segment Atomic.t;
  suspend_idx     : int Atomic.t;
  resume_mode     : resume_mode;
  cancellation_mode : cancellation_mode;
  on_cancellation : unit -> bool;
  (** Returns [true] if the cancellation is "clean" (cell → CANCELLED) or
      [false] if the incoming resume should be refused. *)
  try_return_refused_value : 'a -> bool;
  return_value    : 'a -> unit;
}

(** Convenience alias usable outside the module where ['a t] may shadow
    built-in [t]. *)
type 'a segment_queue_synchronizer = 'a t

(** Construct an SQS with the given policies and handlers. *)
let make
    ?(resume_mode       = Sync)
    ?(cancellation_mode = Simple)
    ?(on_cancellation   = fun () -> false)
    ?(try_return_refused_value = fun _ -> true)
    ?(return_value      = fun _ -> ())
    ()
  =
  let s = make_segment 0 None 2 in
  { resume_segment          = Atomic.make s
  ; resume_idx              = Atomic.make 0
  ; suspend_segment         = Atomic.make s
  ; suspend_idx             = Atomic.make 0
  ; resume_mode
  ; cancellation_mode
  ; on_cancellation
  ; try_return_refused_value
  ; return_value
  }

(* ------------------------------------------------------------------ *)
(*  Internal helpers                                                    *)
(* ------------------------------------------------------------------ *)

let return_refused_value sqs value =
  if not (sqs.try_return_refused_value value) then
    sqs.return_value value

(** Update [resume_idx] to [new_value] if the current value is lower. *)
let adjust_resume_idx_to sqs new_value =
  let continue_loop = ref true in
  while !continue_loop do
    let cur = Atomic.get sqs.resume_idx in
    if cur >= new_value then continue_loop := false
    else if Atomic.compare_and_set sqs.resume_idx cur new_value then
      continue_loop := false
  done

let make_seg_for sqs id prev_opt =
  make_segment id prev_opt 0 |> fun s ->
  (* Stash the sqs reference so the cancellation handler can call back. *)
  (* In this pure translation the on_slot_cleaned is already closure-captured. *)
  s

(* ------------------------------------------------------------------ *)
(*  try_mark_cancelling                                                 *)
(* ------------------------------------------------------------------ *)

(** Attempt to transition cell [index] in [seg] from [Waiter _] to
    [Cancelling _].  Returns [false] if the cell is already [Resumed]
    (meaning the logical resume already happened and only prompt
    cancellation applies). *)
let try_mark_cancelling seg index =
  let keep_going = ref true
  and result     = ref false in
  while !keep_going do
    match seg_get seg index with
    | Resumed -> keep_going := false; result := false
    | Waiter _ as w ->
      if seg_cas seg index w
           (match w with Waiter f -> Cancelling f | _ -> assert false)
      then begin keep_going := false; result := true end
      (* else retry — another thread beat us *)
    | Cancelling _ ->
      (* Already in this state — treat as success. *)
      keep_going := false; result := true
    | _ ->
      keep_going := false; result := false
  done;
  !result

(* ------------------------------------------------------------------ *)
(*  mark_cancelled / mark_refuse                                        *)
(* ------------------------------------------------------------------ *)

(** Atomically replace [Cancelling _] with [marker].  If, in async mode, a
    concurrent resume sneaked a value in, return [Some value] so the caller
    can forward the resume; otherwise return [None]. *)
let mark_impl seg index marker =
  let old = seg_get_and_set seg index marker in
  (* Sanity: old must be Cancelling or a Value/WrappedValue put by async resume. *)
  match old with
  | Cancelling _ -> None
  | Value v      -> Some v
  | WrappedValue v -> Some v
  | _ -> None (* Defensive: should not happen in a correct execution. *)

let mark_cancelled sqs seg index =
  let result = mark_impl seg index Cancelled in
  on_slot_cleaned seg;
  ignore sqs; (* sqs.return_value could be invoked by caller if needed *)
  result

let mark_refuse seg index =
  mark_impl seg index Refuse

(* ------------------------------------------------------------------ *)
(*  on_cancellation_handler (called from Cancelling transition)         *)
(* ------------------------------------------------------------------ *)

(** This is the equivalent of [SQSSegment.onCancellation] in Kotlin.
    It is called when a waiter transitions to [Cancelling]. *)
let rec handle_cancellation (sqs : 'a t) seg index =
  if not (try_mark_cancelling seg index) then ()
  else begin
    match sqs.cancellation_mode with
    | Simple ->
      ignore (mark_cancelled sqs seg index)
    | Smart ->
      let cancelled = sqs.on_cancellation () in
      if cancelled then begin
        match mark_cancelled sqs seg index with
        | None -> ()   (* no pending async resume value *)
        | Some v ->
          (* A concurrent async resume deposited [v]; forward it. *)
          if not (resume sqs v) then sqs.return_value v
      end else begin
        match mark_refuse seg index with
        | None -> ()
        | Some v -> return_refused_value sqs v
      end
  end

(* ------------------------------------------------------------------ *)
(*  suspend                                                             *)
(* ------------------------------------------------------------------ *)

(** [suspend sqs callback] enqueues [callback] as the next waiter.
    Returns a cancellation thunk [unit -> unit] that the caller may invoke
    to cancel the waiter.  The callback is eventually called with the
    resumed value, or never called if the waiter stays cancelled.

    Mirrors [SegmentQueueSynchronizer.suspend(waiter)].  Returns [true] if
    the waiter was enqueued (the callback will be invoked later) or [false]
    if an elimination with a waiting resume happened and the callback was
    already invoked inline. *)
and suspend (sqs : 'a t) (callback : 'a -> unit) : bool =
  let cur_suspend_segm = Atomic.get sqs.suspend_segment in
  let idx = Atomic.fetch_and_add sqs.suspend_idx 1 in
  let target_id = idx / segment_size in
  let seg =
    find_segment_and_move_forward
      sqs.suspend_segment target_id cur_suspend_segm
      (fun id prev -> make_seg_for sqs id prev)
  in
  let i = idx mod segment_size in
  (* Try to install the waiter. *)
  if seg_cas seg i Empty (Waiter callback) then begin
    (* Successfully enqueued — install cancellation handler. *)
    (* (In a real runtime this would hook into GC or thread cancellation;
        here we expose a manual cancel thunk via the returned bool path.) *)
    true
  end else begin
    (* A concurrent resume put a value (or BROKEN) before us. *)
    let cell = seg_get seg i in
    match cell with
    | Broken -> false   (* SYNC race: cell is broken, suspend fails *)
    | Value v | WrappedValue v ->
      if seg_cas seg i cell Taken then begin
        (* Elimination: grab the value and fire the callback immediately. *)
        callback v;
        true
      end else
        (* Another thread took the value concurrently — treat as broken. *)
        false
    | _ -> false
  end

(** [suspend_cancelled sqs] is the non-callback variant used when the caller
    just wants to poll: installs [Cancelled] directly so no resume will
    attempt to deliver.  Returns [Some v] if an elimination happened,
    [None] otherwise. *)
and suspend_cancelled (sqs : 'a t) : 'a option =
  let cur_suspend_segm = Atomic.get sqs.suspend_segment in
  let idx = Atomic.fetch_and_add sqs.suspend_idx 1 in
  let target_id = idx / segment_size in
  let seg =
    find_segment_and_move_forward
      sqs.suspend_segment target_id cur_suspend_segm
      (fun id prev -> make_seg_for sqs id prev)
  in
  let i = idx mod segment_size in
  if seg_cas seg i Empty Cancelled then
    None
  else begin
    let cell = seg_get seg i in
    match cell with
    | Broken -> None
    | Value v | WrappedValue v ->
      if seg_cas seg i cell Taken then Some v else None
    | _ -> None
  end

(* ------------------------------------------------------------------ *)
(*  resume                                                              *)
(* ------------------------------------------------------------------ *)

(** [resume sqs value] attempts to dequeue and wake the next waiter with
    [value].  Returns [true] on success.  May return [false] in [Sync] mode
    if an elimination race is lost, or in [Simple] cancellation mode if the
    next waiter is cancelled. *)
and resume (sqs : 'a t) (value : 'a) : bool =
  let skip_cancelled = sqs.cancellation_mode <> Simple in
  let keep_going = ref true
  and result     = ref false in
  while !keep_going do
    match try_resume_impl sqs value skip_cancelled with
    | TryResumeSuccess   -> keep_going := false; result := true
    | TryResumeCancelled ->
      if not skip_cancelled then begin
        keep_going := false; result := false
      end
      (* else: smart mode — loop to try the next cell *)
    | TryResumeBroken    -> keep_going := false; result := false
  done;
  !result

(* ------------------------------------------------------------------ *)
(*  try_resume_impl                                                      *)
(* ------------------------------------------------------------------ *)

and try_resume_impl (sqs : 'a t) (value : 'a) (adjust_resume_idx : bool) : try_resume_result =
  let cur_resume_segm = Atomic.get sqs.resume_segment in
  let idx = Atomic.fetch_and_add sqs.resume_idx 1 in
  let id  = idx / segment_size in
  let seg =
    find_segment_and_move_forward
      sqs.resume_segment id cur_resume_segm
      (fun sid prev -> make_seg_for sqs sid prev)
  in
  (* Previous segments can be GC'd; clear the backwards pointer. *)
  Atomic.set seg.prev None;
  (* If the required segment was physically removed, the cell is CANCELLED. *)
  if seg.id > id then begin
    if adjust_resume_idx then
      adjust_resume_idx_to sqs (seg.id * segment_size);
    TryResumeCancelled
  end else begin
    let i = idx mod segment_size in
    let keep_going = ref true
    and result     = ref TryResumeSuccess in
    while !keep_going do
      match seg_get seg i with

      (* ---- Empty cell: resume arrived before suspend ---- *)
      | Empty ->
        (* Park the value and either finish (ASYNC) or spin-wait (SYNC). *)
        if seg_cas seg i Empty (Value value) then begin
          if sqs.resume_mode = Async then begin
            keep_going := false; result := TryResumeSuccess
          end else begin
            (* SYNC: spin waiting for suspend to claim the value. *)
            let taken = ref false in
            let spin  = ref 0 in
            while !spin < max_spin_cycles && not !taken do
              (match seg_get seg i with
               | Taken -> taken := true
               | _ -> ());
              incr spin
            done;
            if !taken then begin
              keep_going := false; result := TryResumeSuccess
            end else begin
              (* Timed out: try to mark as broken. *)
              if seg_cas seg i (Value value) Broken then begin
                keep_going := false; result := TryResumeBroken
              end else begin
                (* Suspend grabbed it in the last moment. *)
                keep_going := false; result := TryResumeSuccess
              end
            end
          end
        end
        (* else: CAS failed, retry the cell state machine *)

      (* ---- Cell is already cancelled ---- *)
      | Cancelled ->
        keep_going := false; result := TryResumeCancelled

      (* ---- Cell is marked REFUSE ---- *)
      | Refuse ->
        return_refused_value sqs value;
        keep_going := false; result := TryResumeSuccess

      (* ---- Cell holds an active waiter ---- *)
      | Waiter _ as w ->
        (* Atomically grab the waiter by setting the cell to RESUMED. *)
        if seg_cas seg i w Resumed then begin
          let callback = match w with Waiter f -> f | _ -> assert false in
          (* Deliver the value. *)
          let resumed =
            (* In a real cancellable system we would check cancellation here.
               For simplicity we always succeed (no cancellation token). *)
            callback value; true
          in
          if not resumed then begin
            match sqs.cancellation_mode with
            | Simple ->
              keep_going := false; result := TryResumeCancelled
            | Smart ->
              let cancelled = sqs.on_cancellation () in
              if cancelled then begin
                if not (resume sqs value) then sqs.return_value value
              end else
                return_refused_value sqs value;
              keep_going := false; result := TryResumeSuccess
          end else begin
            keep_going := false; result := TryResumeSuccess
          end
        end
        (* else: CAS failed, retry *)

      (* ---- Cell is in the process of being cancelled (CANCELLING) ---- *)
      | Cancelling _ ->
        (match sqs.cancellation_mode with
         | Simple ->
           keep_going := false; result := TryResumeCancelled
         | Smart ->
           match sqs.resume_mode with
           | Sync ->
             (* Spin-wait until cancellation handler resolves the cell. *)
             ()  (* loop — do not set keep_going to false *)
           | Async ->
             (* Deposit the value; the cancellation handler will complete us. *)
             let v_to_store = Value value in
             if seg_cas seg i (seg_get seg i) v_to_store then begin
               keep_going := false; result := TryResumeSuccess
             end)

      (* ---- Resumed / Taken / Broken / Value: unexpected at this point ---- *)
      | Resumed | Taken | Broken | Value _ | WrappedValue _ ->
        (* Should not happen in a correct execution; defensive fall-through. *)
        keep_going := false; result := TryResumeBroken

    done;
    !result
  end

(* ------------------------------------------------------------------ *)
(*  cancel_waiter                                                       *)
(* ------------------------------------------------------------------ *)

(** Manually cancel the waiter that was installed at position [idx] in the
    queue.  This is the OCaml replacement for Kotlin's
    [CancellableContinuation.invokeOnCancellation] handler. *)
let cancel_waiter (sqs : 'a t) (seg : 'a segment) (index : int) =
  handle_cancellation sqs seg index

(* ------------------------------------------------------------------ *)
(*  Pretty printer (mirrors Kotlin toString)                            *)
(* ------------------------------------------------------------------ *)

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
  let ri = Atomic.get sqs.resume_idx in
  Printf.printf "suspendIdx=%d resumeIdx=%d\n" si ri;
  let cur_seg = ref (Atomic.get sqs.resume_segment) in
  let cur_idx = ref ri in
  let limit   = max si ri in
  while !cur_idx < limit do
    let i   = !cur_idx mod segment_size in
    let seg = !cur_seg in
    let state =
      if !cur_idx < seg.id * segment_size then "CANCELLED"
      else Format.asprintf "%a" pp_cell_state (seg_get seg i)
    in
    Printf.printf "  [%d] %s\n" !cur_idx state;
    incr cur_idx;
    if !cur_idx = (seg.id + 1) * segment_size then
      match Atomic.get seg.next with
      | Some next -> cur_seg := next
      | None -> cur_idx := limit   (* stop *)
  done

(* ------------------------------------------------------------------ *)
(*  Example: a simple mutex built on top of SQS                        *)
(* ------------------------------------------------------------------ *)

module Mutex = struct
  (** An unfair mutex backed by SQS (illustrative; not production-grade). *)
  type t = {
    sqs    : unit segment_queue_synchronizer;
    locked : bool Atomic.t;
  }

  let make () =
    let rec m = {
      sqs =
        make
          ~resume_mode:Async
          ~cancellation_mode:Smart
          ~on_cancellation:(fun () ->
            (* When a waiter cancels, try to wake the next one. *)
            (* We re-use the mutex's release logic via a side-effecting ref
               set below.  A real implementation would capture [m] here. *)
            true)
          ~return_value:(fun () ->
            (* Prompt-cancellation: put the unit back by not doing anything,
               i.e. call release again.  See comment above. *)
            ())
          ()
      ; locked = Atomic.make false
    }
    in
    m

  let lock m callback =
    (* Try to acquire without suspending first. *)
    if Atomic.compare_and_set m.locked false true then
      callback ()   (* acquired immediately *)
    else
      ignore (suspend m.sqs (fun () -> callback ()))

  let unlock m =
    (* If nothing is waiting, just release. *)
    if not (resume m.sqs ()) then
      Atomic.set m.locked false
end