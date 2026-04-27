(** QCheck-STM State Machine Test for SQS-based Semaphore.

    SQS State Machine Correspondence
    ================================
    Each command exercises a deterministic path through the SQS cell
    state machine documented in [sqs_state.png]:

      Try_acquire (permits > 0)  : no SQS cell touched (FAA + CAS fast
                                   path, [implementations/semaphore.ml:46-53]).
      Try_acquire (permits = 0)  : no SQS cell touched, returns false.
      Release (no waiters)       : no SQS cell touched (FAA only,
                                   [implementations/semaphore.ml:60-62]).
      Available_permits          : pure read, no SQS cell touched.

    The blocking [Acquire] path (Empty -> Waiter, paired with a future
    Release's Waiter -> Resumed) is exercised by [semaphore_lin_test.ml]
    via the Eio-aware [Lin_harness], not here.  This file restricts to
    the non-blocking subset {try_acquire, release, available_permits}
    so no command needs an Eio scheduler in scope.

    Model state
    ===========
      state : int   -- model permit count, always >= 0.
                       Try_acquire succeeds iff state > 0.
                       Release always succeeds and increments state.
                       Available_permits returns state. *)

open QCheck
open STM

module S = Semaphore

let init_permits = 2

type cmd =
  | Try_acquire
  | Release
  | Available_permits

let show_cmd = function
  | Try_acquire       -> "Try_acquire"
  | Release           -> "Release"
  | Available_permits -> "Available_permits"

let arb_cmd _state =
  QCheck.make ~print:show_cmd
    Gen.(oneof [
      return Try_acquire;
      return Release;
      return Available_permits;
    ])

let next_state cmd state =
  match cmd with
  | Try_acquire       -> if state > 0 then state - 1 else state
  | Release           -> state + 1
  | Available_permits -> state

let precond _ _ = true

let run cmd sut =
  match cmd with
  | Try_acquire       -> Res (bool, S.try_acquire sut)
  | Release           -> Res (unit, S.release sut)
  | Available_permits -> Res (int,  S.available_permits sut)

let postcond cmd state result =
  match cmd, result with
  | Try_acquire,       Res ((Bool, _), b)  -> b = (state > 0)
  | Release,           Res ((Unit, _), ()) -> true
  | Available_permits, Res ((Int,  _), n)  -> n = state
  | _ -> false

module Spec = struct
  type sut = S.t
  type state = int
  type nonrec cmd = cmd

  let arb_cmd     = arb_cmd
  let init_state  = init_permits
  let next_state  = next_state
  let precond     = precond
  let run         = run
  let init_sut () = S.make init_permits
  let cleanup _   = ()
  let postcond    = postcond
  let show_cmd    = show_cmd
end

module Seq = STM_sequential.Make (Spec)
module Dom = STM_domain.Make     (Spec)

let run_sequential_test () =
  Printf.printf "Running sequential STM test on Semaphore...\n%!";
  let t = Seq.agree_test ~count:1000 ~name:"Semaphore sequential" in
  QCheck_base_runner.run_tests ~verbose:true [t]

let run_concurrent_test () =
  Printf.printf "Running concurrent STM test on Semaphore...\n%!";
  let arb_triple =
    Dom.arb_triple 15 10 Spec.arb_cmd Spec.arb_cmd Spec.arb_cmd
  in
  let t =
    QCheck.Test.make ~retries:10 ~count:200
      ~name:"Semaphore concurrent" arb_triple
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
