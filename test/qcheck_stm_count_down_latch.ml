(** QCheck-STM State Machine Test for SQS-based CountDownLatch.

    SQS State Machine Correspondence
    ================================
    Each command exercises a deterministic path through the SQS cell
    state machine documented in [sqs_state.png]:

      Count_down (count > 1)     : FAA only; no SQS cell touched
                                   ([implementations/count_down_latch.ml:76-78]).
      Count_down (count drops to 0,
                  no waiters)    : sets [done_bit] via CAS on
                                   [waiters]; [resume_waiters]'s for-loop
                                   runs zero times, so still no SQS cell
                                   touched.
      Count_down (count drops to 0,
                  waiters present)*: sets [done_bit] and calls
                                   [resume t.sqs ()] once per waiter,
                                   which traverses Waiter -> Resumed via
                                   [try_resume_impl] in [sqs_effects.ml:376].
                                   * Not exercised by this test, since
                                   [Await] is excluded from the
                                   non-blocking subset.
      Remaining                  : pure read; no SQS cell touched.

    The blocking [Await] path (Empty -> Waiter, then Waiter -> Resumed
    after a sufficient number of Count_downs) is covered by
    [count_down_latch_lin_test.ml] via the Eio-aware [Lin_harness].

    Model state
    ===========
      state : int   -- model count, may go negative.
                       Count_down decrements state.
                       Remaining returns max 0 state (matching the impl
                       at [implementations/count_down_latch.ml:93]). *)

open QCheck
open STM

module CDL = Count_down_latch

let init_count = 5

type cmd =
  | Count_down
  | Remaining

let show_cmd = function
  | Count_down -> "Count_down"
  | Remaining  -> "Remaining"

let arb_cmd _state =
  QCheck.make ~print:show_cmd
    Gen.(oneof [
      return Count_down;
      return Remaining;
    ])

let next_state cmd state =
  match cmd with
  | Count_down -> state - 1
  | Remaining  -> state

let precond _ _ = true

let run cmd sut =
  match cmd with
  | Count_down -> Res (unit, CDL.count_down sut)
  | Remaining  -> Res (int,  CDL.remaining   sut)

let postcond cmd state result =
  match cmd, result with
  | Count_down, Res ((Unit, _), ()) -> true
  | Remaining,  Res ((Int,  _), n)  -> n = (if state < 0 then 0 else state)
  | _ -> false

module Spec = struct
  type sut = CDL.t
  type state = int
  type nonrec cmd = cmd

  let arb_cmd     = arb_cmd
  let init_state  = init_count
  let next_state  = next_state
  let precond     = precond
  let run         = run
  let init_sut () = CDL.make init_count
  let cleanup _   = ()
  let postcond    = postcond
  let show_cmd    = show_cmd
end

module Seq = STM_sequential.Make (Spec)
module Dom = STM_domain.Make     (Spec)

let run_sequential_test () =
  Printf.printf "Running sequential STM test on CountDownLatch...\n%!";
  let t = Seq.agree_test ~count:1000 ~name:"CountDownLatch sequential" in
  QCheck_base_runner.run_tests ~verbose:true [t]

let run_concurrent_test () =
  Printf.printf "Running concurrent STM test on CountDownLatch...\n%!";
  let arb_triple =
    Dom.arb_triple 15 10 Spec.arb_cmd Spec.arb_cmd Spec.arb_cmd
  in
  let t =
    QCheck.Test.make ~retries:10 ~count:200
      ~name:"CountDownLatch concurrent" arb_triple
    @@ Dom.agree_prop_par
  in
  QCheck_base_runner.run_tests ~verbose:true [t]

let () =
  let mode = if Array.length Sys.argv > 1 then Sys.argv.(1) else "sequential" in
  match mode with
  | "sequential" | "seq"  -> ignore (run_sequential_test ())
  | "concurrent" | "conc" -> ignore (run_concurrent_test ())
  | _ ->
    Printf.eprintf "Usage: %s [sequential|concurrent]\n" Sys.argv.(0);
    exit 1
