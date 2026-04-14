(** Lightweight cooperative thread (fibre) backed by OCaml 5 Effect Handlers.

    A [LightThread.t] is a suspended computation waiting for a value of type
    ['a].  The life-cycle of a light thread is:

      1. {!run} installs the effect handler and starts executing a function.
      2. {!suspend} — called inside that function — parks the current thread
         by capturing its continuation and passing it to a caller-supplied
         [register] callback.
      3. {!resume} — called from anywhere — delivers a value to the parked
         thread, restarting it from the suspension point.
      4. {!discontinue} — restarts the parked thread by raising an exception
         at the suspension point (used for cancellation).

    These four primitives are the complete green-thread substrate.  Higher-
    level synchronisers (semaphores, mutexes, channels, …) call [suspend] and
    [resume] and leave scheduling policy to whoever invokes [run].

    -------------------------------------------------------------------------
    Relationship to Kotlin coroutines
    -------------------------------------------------------------------------

    | Kotlin                          | This module                        |
    |---------------------------------|------------------------------------|
    | [CoroutineScope.launch { … }]   | [run f]                            |
    | [suspendCoroutine { k -> … }]   | [suspend register]                 |
    | [continuation.resume(v)]        | [resume t v]                       |
    | [continuation.cancel(exn)]      | [discontinue t exn]                |

    The [Suspend] effect is the single extension point; the handler installed
    by [run] dispatches it.  Every other green-thread primitive is built on
    top of these four operations.
*)

(* ====================================================================== *)
(*  Type                                                                   *)
(* ====================================================================== *)

(** A suspended light thread waiting for a value of type ['a].

    Internally this is an OCaml 5 first-class continuation.  Each [t] value
    represents a paused computation and must be resumed (via {!resume} or
    {!discontinue}) exactly once — OCaml 5 continuations are linear. *)
type 'a t = ('a, unit) Effect.Deep.continuation

(* ====================================================================== *)
(*  Effect                                                                 *)
(* ====================================================================== *)

(** The single effect declared by this module.  Performing [Suspend register]
    captures the current continuation [k] and calls [register k] before
    returning control to the nearest enclosing {!run} handler.

    The [register] callback is responsible for storing [k] (e.g. in an SQS
    cell) so that a future call to {!resume} can wake the thread. *)
type _ Effect.t +=
  | Suspend : ('a t -> unit) -> 'a Effect.t

(* ====================================================================== *)
(*  Primitives                                                             *)
(* ====================================================================== *)

(** [suspend register] suspends the current light thread.

    [register k] is called synchronously with the captured continuation
    before control is returned to {!run}'s caller.  [suspend] returns the
    value later supplied by a corresponding {!resume}. *)
let suspend register =
  Effect.perform (Suspend register)

(** [resume t v] restarts suspended thread [t] with value [v].

    [v] becomes the return value of the [suspend] call that parked [t].
    Must be called exactly once per [t]. *)
let resume t v = Effect.Deep.continue t v

(** [discontinue t exn] restarts suspended thread [t] by raising [exn]
    at its suspension point.

    Used for cancellation: the thread receives an exception instead of a
    value.  Must be called exactly once per [t]. *)
let discontinue t exn = Effect.Deep.discontinue t exn

(* ====================================================================== *)
(*  Handler                                                                *)
(* ====================================================================== *)

(** [run f] executes [f ()] with the [Suspend] effect handler installed.

    When [f] (or any function it calls) performs [suspend register]:
    - the current continuation [k] is captured,
    - [register k] is called (typically to park [k] in a queue),
    - control returns to [run]'s caller.

    A later call to [resume k v] restarts the computation from after the
    [suspend] point, returning [v] there.  If [f] performs another [suspend]
    during the resumed execution, the same handler catches it.

    Typical usage — wrapping a single fibre:
    {[
      run (fun () ->
        let v = suspend (fun k -> enqueue_somewhere k) in
        Printf.printf "resumed with %d\n" v)
    ]} *)
let run f =
  Effect.Deep.match_with f ()
    { Effect.Deep.retc = (fun () -> ())
    ; exnc = raise
    ; effc = fun (type a) (eff : a Effect.t) ->
        match eff with
        | Suspend register ->
          Some (fun (k : (a, _) Effect.Deep.continuation) ->
            register k)
        | _ -> None
    }
