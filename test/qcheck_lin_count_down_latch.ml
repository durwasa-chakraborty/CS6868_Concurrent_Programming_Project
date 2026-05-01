(** QCheck-Lin Linearizability Test for Count_down_latch — non-blocking subset.

    Follows the [qcheck_lin_batch_queue.ml] template.  As with
    [qcheck_lin_semaphore.ml], the Lin DSL can only drive primitives that
    never suspend, so this test exercises [count_down] and [remaining].
    The suspending [await] path is exercised by
    [count_down_latch_manual_test.ml] and the Task-3 harness
    [count_down_latch_lin_test.ml]. *)

module LatchSig = struct
  type t = Count_down_latch.t

  let init    () = Count_down_latch.make 3
  let cleanup _  = ()

  open Lin
  let api = [
    val_ "Count_down_latch.count_down" Count_down_latch.count_down
         (t @-> returning unit);
    val_ "Count_down_latch.remaining"  Count_down_latch.remaining
         (t @-> returning int);
  ]
end

module Latch_domain = Lin_domain.Make (LatchSig)

let () =
  QCheck_base_runner.run_tests_main [
    Latch_domain.lin_test ~count:1000
      ~name:"Count_down_latch (count_down/remaining) linearizability";
  ]
