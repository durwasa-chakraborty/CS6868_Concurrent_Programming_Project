(** Linearisability tests for [Sqs_effects.Semaphore].

    Sequential model
    ================
    State = current permit count (may go negative when waiters outnumber
    available permits).

      Acquire  state > 0  →  Some (state - 1, ())   fast path
      Acquire  state ≤ 0  →  None                   would suspend; try another ordering
      Release  any state  →  Some (state + 1, ())   always valid

    The [release] implementation wakes a waiter only when [p < 0] (i.e. when
    it finds that permits were negative before the FAA), so a release with
    [state ≥ 0] is legal: it just increments the permit pool without waking
    anyone.  No exception is raised.

    Test design
    ===========
    Each domain generates [n/2] Acquires and [n - n/2] Releases, then
    shuffles them.  Balanced per-domain sequences avoid permanent deadlock:
    a domain that acquires will always eventually release, so a waiting
    acquire in another domain is always unblocked.

    Concurrency model
    =================
    Each domain runs inside its own [Eio_main.run] scheduler.
    [Semaphore.acquire] calls [Light_thread.suspend] → [Eio.Private.Suspend.enter],
    which parks the Eio fibre.  [Semaphore.release] calls [Light_thread.resume],
    which is Eio's domain-safe enqueue: it can be called from any domain
    and will wake the parked fibre in its originating scheduler. *)

(* ------------------------------------------------------------------ *)
(* Semaphore spec functor                                              *)
(* ------------------------------------------------------------------ *)

module Make (C : sig val init_permits : int end) = struct
  type sut   = Semaphore.t
  type state = int     (* current permit count; negative = #waiters *)
  type op    = Acquire | Release
  type res   = unit

  let init_sut   () = Semaphore.make C.init_permits
  let init_state () = C.init_permits

  let next state = function
    | Acquire ->
      if state > 0 then Some (state - 1, ())
      else None                            (* would suspend; need a release first *)
    | Release  -> Some (state + 1, ())    (* always legal *)

  let run sut = function
    | Acquire -> Semaphore.acquire sut
    | Release -> Semaphore.release sut

  let equal () () = true
  let show_op  = function Acquire -> "Acquire" | Release -> "Release"
  let show_res () = "()"

  (** Generate [n] ops as alternating critical sections.

      A freely-shuffled mix of Acquire/Release can deadlock: e.g. two domains
      each doing [Acquire; Acquire; Release; Release] concurrently will both
      block on their second Acquire before reaching any Release.

      Restricting each domain to alternating [Acq; Rel; Acq; Rel; ...] or
      [Rel; Acq; Rel; Acq; ...] guarantees that after any blocked Acquire in
      one domain, some other domain will reach a Release (it either starts
      with a Release, or alternates quickly enough to issue one).  Concurrency
      is preserved across domains; the sequential model still sees all
      interleavings that the linearizability checker searches. *)
  let gen_ops n =
    QCheck2.Gen.(
      let* starts_with_acquire = bool in
      return (List.init n (fun i ->
        let acq_turn =
          if starts_with_acquire then i mod 2 = 0 else i mod 2 = 1
        in
        if acq_turn then Acquire else Release))
    )
end

(* ------------------------------------------------------------------ *)
(* Test instances                                                      *)
(* ------------------------------------------------------------------ *)

module Spec1 = Make (struct let init_permits = 1 end)
module Spec2 = Make (struct let init_permits = 2 end)

let () =
  QCheck_base_runner.run_tests_main [
    Lin_harness.make_test (module Spec1)
      ~n_domains:2 ~ops_per_domain:4 ~count:500
      "Semaphore(1) linearisability";
    Lin_harness.make_test (module Spec2)
      ~n_domains:2 ~ops_per_domain:4 ~count:500
      "Semaphore(2) linearisability";
    Lin_harness.make_test (module Spec1)
      ~n_domains:3 ~ops_per_domain:2 ~count:200
      "Semaphore(1) 3-domain linearisability";
  ]
