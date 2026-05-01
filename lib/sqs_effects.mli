(** Segment Queue Synchronizer — public interface.

    See [sqs_effects.ml] for the full design rationale.  Only the surface
    needed by the synchronization primitives in [implementations/] and by
    top-level tests is re-exported here; the cell state machine, segment
    mechanics, and debug helpers are internal. *)

(** Raised at the suspension point when a parked waiter is discontinued. *)
exception Cancelled

(** Whether [resume] waits for the matching [suspend] to claim the value
    ([Sync]) or returns immediately once the value is deposited ([Async]). *)
type resume_mode = Sync | Async

(** [Simple] never skips cancelled cells during [resume]; [Smart] does, and
    enables the [on_cancellation] / [try_return_refused_value] hooks. *)
type cancellation_mode = Simple | Smart

(** An SQS carrying values of type ['a]. *)
type 'a t

(** Aliases preserved so callers can name the type without shadowing [t]. *)
type 'a sqs                        = 'a t
type 'a segment_queue_synchronizer = 'a t

(** [make ()] allocates a fresh SQS.

    - [resume_mode]              — default [Sync].
    - [cancellation_mode]        — default [Simple].
    - [on_cancellation]          — [Smart] only; [true] ⇒ cell becomes
                                   CANCELLED, [false] ⇒ cell becomes REFUSE.
    - [try_return_refused_value] — called when a resume lands on a REFUSE
                                   cell; returning [false] falls back to
                                   [return_value].
    - [return_value]             — terminal sink for values that cannot be
                                   delivered or re-inserted. *)
val make :
  ?resume_mode:resume_mode ->
  ?cancellation_mode:cancellation_mode ->
  ?on_cancellation:(unit -> bool) ->
  ?try_return_refused_value:('a -> bool) ->
  ?return_value:('a -> unit) ->
  unit ->
  'a t

(** [suspend sqs] parks the current light thread until a matching [resume]
    delivers a value.  Raises {!Cancelled} if the waiter is discontinued.
    Must be called inside a {!run} context. *)
val suspend : 'a t -> 'a

(** [resume sqs v] delivers [v] to the next live waiter.  Returns [true] on
    success, [false] if no waiter could be resumed (e.g. all reachable cells
    were cancelled in [Simple] mode, or a SYNC race broke the handshake). *)
val resume : 'a t -> 'a -> bool

(** [run f] installs the {!Light_thread} handler and runs [f ()] inside an
    Eio event loop, making {!suspend} and {!resume} available to [f]. *)
val run : (unit -> 'a) -> 'a
