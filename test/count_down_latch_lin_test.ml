(** Linearisability tests for [Count_down_latch].

    Port of [CountDownLatchLincheckTestBase] in
    [test/kotlin/CancellableQueueSynchronizerLincheckTests.kt].

    Sequential model
    ================
    State = remaining count (may go negative once it has reached zero).

      count_down  any state  →  Some (state - 1, ())          never blocks
      remaining   any state  →  Some (state, max 0 state)     pure read
      await       state ≤ 0  →  Some (state, ())              latch fired
      await       state > 0  →  None                          would suspend

    Once the count reaches zero, [await] is guaranteed to return for every
    interleaving that the checker will explore.  Test generators ensure
    every domain issues at least one [count_down], so the latch always
    eventually fires. *)

module Make (C : sig val init_count : int end) = struct
  type sut   = Count_down_latch.t
  type state = int   (* remaining count; may go negative *)
  type op    = Count_down | Remaining | Await
  type res   = RUnit | RInt of int

  let init_sut   () = Count_down_latch.make C.init_count
  let init_state () = C.init_count

  let next state = function
    | Count_down -> Some (state - 1, RUnit)
    | Remaining  -> Some (state, RInt (max 0 state))
    | Await      ->
      if state <= 0 then Some (state, RUnit)
      else None                           (* would suspend; need count_down *)

  let run sut = function
    | Count_down -> Count_down_latch.count_down sut; RUnit
    | Remaining  -> RInt (Count_down_latch.remaining sut)
    | Await      -> Count_down_latch.await sut; RUnit

  let equal a b = match a, b with
    | RUnit, RUnit        -> true
    | RInt x, RInt y      -> x = y
    | _                   -> false
  let show_op = function
    | Count_down -> "count_down"
    | Remaining  -> "remaining"
    | Await      -> "await"
  let show_res = function
    | RUnit    -> "()"
    | RInt n   -> string_of_int n

  (** Every domain starts with a [count_down] so [init_count] count-downs
      always eventually land.  The remaining ops are a random mix of the
      three primitives. *)
  let gen_ops n =
    QCheck2.Gen.(
      let* rest =
        list_size (return (max 0 (n - 1)))
          (oneofl [Count_down; Remaining; Await])
      in
      return (Count_down :: rest))
end

module Spec1 = Make (struct let init_count = 1 end)
module Spec2 = Make (struct let init_count = 2 end)

let () =
  QCheck_base_runner.run_tests_main [
    Lin_harness.make_test (module Spec1)
      ~n_domains:2 ~ops_per_domain:3 ~count:300
      "CountDownLatch(1) linearisability";
    Lin_harness.make_test (module Spec2)
      ~n_domains:2 ~ops_per_domain:3 ~count:300
      "CountDownLatch(2) linearisability";
    Lin_harness.make_test (module Spec2)
      ~n_domains:3 ~ops_per_domain:2 ~count:200
      "CountDownLatch(2) 3-domain linearisability";
  ]
