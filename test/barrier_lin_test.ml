(** Linearisability tests for [Barrier].

    Port of [BarrierLincheckTestBase] in
    [test/kotlin/CancellableQueueSynchronizerLincheckTests.kt].

    Sequential model
    ================
    State = number of arrivals observed so far (capped at [parties + excess]).

      arrive  state < parties - 1  →  Some (state + 1, true)   suspends,
                                                               will return
                                                               true once the
                                                               barrier fires
      arrive  state = parties - 1  →  Some (parties, true)     last party
      arrive  state ≥ parties      →  Some (state + 1, false)  excess arrival

    The first case treats a suspended arrival as if it had already returned
    [true] — a valid linearisation because the last party's call unblocks
    all preceding arrivals at a single point.  Tests pick
    [n_domains ≥ parties] so the barrier is always guaranteed to fire. *)

module Make (C : sig val parties : int end) = struct
  type sut   = Barrier.t
  type state = int
  type op    = Arrive
  type res   = bool

  let init_sut   () = Barrier.make C.parties
  let init_state () = 0

  let next state Arrive =
    if state < C.parties - 1   then Some (state + 1, true)
    else if state = C.parties - 1 then Some (C.parties, true)
    else                            Some (state + 1, false)

  let run sut Arrive = Barrier.arrive sut

  let equal (a : bool) (b : bool) = a = b
  let show_op  Arrive = "arrive"
  let show_res = string_of_bool

  (** Barrier exposes only one op; each domain issues [n] arrives. *)
  let gen_ops n = QCheck2.Gen.return (List.init n (fun _ -> Arrive))
end

module B1 = Make (struct let parties = 1 end)
module B2 = Make (struct let parties = 2 end)
module B3 = Make (struct let parties = 3 end)

let () =
  QCheck_base_runner.run_tests_main [
    Lin_harness.make_test (module B1)
      ~n_domains:1 ~ops_per_domain:2 ~count:200
      "Barrier(1) linearisability";
    Lin_harness.make_test (module B2)
      ~n_domains:2 ~ops_per_domain:2 ~count:300
      "Barrier(2) linearisability";
    Lin_harness.make_test (module B3)
      ~n_domains:3 ~ops_per_domain:2 ~count:200
      "Barrier(3) linearisability";
  ]
