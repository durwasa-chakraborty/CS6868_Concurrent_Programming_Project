(** Lightweight cooperative fibre backed by Eio.

    Replaces the OCaml 5 [Effect.Deep.continuation]-based implementation
    with Eio's fibre-scheduling primitives.  The critical improvement is
    **domain safety**: {!resume} and {!discontinue} may now be called from
    any domain, not just the domain that performed the original {!suspend}.

    -------------------------------------------------------------------------
    Why the old implementation was not domain-safe
    -------------------------------------------------------------------------

    The previous version stored the suspended fibre as an
    [Effect.Deep.continuation].  OCaml 5 continuations are domain-local: the
    runtime stores a pointer to the originating domain's stack, so calling
    [Effect.Deep.continue k v] from a different domain is undefined behaviour.

    This made it impossible to have one domain call [suspend] (e.g. inside
    [Semaphore.acquire]) while another domain calls [resume] (e.g. inside
    [Semaphore.release]) — a pattern that is central to concurrent testing
    with multi-domain frameworks such as [qcheck-lin.domain].

    -------------------------------------------------------------------------
    How Eio fixes it
    -------------------------------------------------------------------------

    Eio represents a suspended fibre as an *enqueue* function of type
    [('a, exn) result -> unit].  The Eio runtime guarantees that this
    function is thread-safe and may be called from any domain or systhread
    (documented in [Eio.Private.Suspend.enter]).  Calling it with [Ok v]
    schedules the fibre to resume with value [v]; calling it with [Error e]
    schedules it to resume by raising [e].

    -------------------------------------------------------------------------
    Relationship to Kotlin coroutines
    -------------------------------------------------------------------------

    | Kotlin                        | Previous (effects)                | This module (Eio)             |
    |-------------------------------|-----------------------------------|-------------------------------|
    | [launch { … }]                | [run f]                           | [run f]                       |
    | [suspendCoroutine { k -> … }] | [suspend register]                | [suspend register]            |
    | [continuation.resume(v)]      | [Effect.Deep.continue k v]        | [k (Ok v)]  ← domain-safe    |
    | [continuation.cancel(exn)]    | [Effect.Deep.discontinue k exn]   | [k (Error exn)]  ← domain-safe|
*)

(* ====================================================================== *)
(*  Type                                                                   *)
(* ====================================================================== *)

(** A suspended light fibre waiting for a value of type ['a].

    Internally this is Eio's domain-safe enqueue function:
    - [t (Ok v)]    resumes the fibre with value [v].
    - [t (Error e)] resumes the fibre by raising exception [e].

    Unlike the previous [Effect.Deep.continuation]-based representation,
    this value may be safely stored and called from any domain. *)
type 'a t = ('a, exn) result -> unit

(* ====================================================================== *)
(*  Primitives                                                             *)
(* ====================================================================== *)

(** [suspend register] suspends the current Eio fibre.

    Eio captures the fibre and calls [register k] synchronously in the
    scheduler's context, where [k] is the domain-safe wake-up function.
    [register] should store [k] somewhere (e.g. in an SQS cell) so that a
    future {!resume} or {!discontinue} call can wake the fibre.

    Returns the value supplied by [resume k v], or raises the exception
    supplied by [discontinue k exn].

    Must be called from within a {!run} context (i.e. inside an Eio fibre). *)
let suspend register =
  Eio.Private.Suspend.enter "sqs_suspend" (fun _ctx enqueue ->
    register enqueue)

(** [resume t v] schedules the suspended fibre [t] to resume with value [v].

    Domain-safe: may be called from any domain or systhread.
    Unlike [Effect.Deep.continue], this call returns immediately; the fibre
    is added to the Eio run-queue and will be scheduled by the runtime. *)
let resume (t : 'a t) (v : 'a) : unit = t (Ok v)

(** [discontinue t e] schedules the suspended fibre [t] to resume by
    raising [e] at its suspension point.  Used for cancellation.

    The name *discontinue* is preserved from [Effect.Deep.discontinue] to
    make clear that this is the *cancellation* path, not a normal value
    delivery — even though the underlying mechanism (calling the enqueue
    function) is identical to {!resume}.

    Domain-safe: may be called from any domain or systhread. *)
let discontinue (t : 'a t) (e : exn) : unit = t (Error e)

(* ====================================================================== *)
(*  Handler                                                                *)
(* ====================================================================== *)

(** [run f] executes [f ()] inside an Eio event loop, making {!suspend},
    {!resume}, and {!discontinue} available to all code reachable from [f].

    This replaces [Effect.Deep.match_with] as the top-level entry point.
    [run] should be called exactly once at the boundary between non-Eio
    and Eio code; it must not be nested.

    Typical usage:
    {[
      let sem = Sqs_effects.Semaphore.make 1 in
      Sqs_effects.run (fun () ->
        Sqs_effects.Semaphore.acquire sem;
        (* … critical section … *)
        Sqs_effects.Semaphore.release sem)
    ]} *)
let run f =
  Eio_main.run (fun _env -> f ())
