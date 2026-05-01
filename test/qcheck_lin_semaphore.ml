(** QCheck-Lin Linearizability Test for Semaphore — non-blocking subset.

    Follows the [qcheck_lin_batch_queue.ml] template: declare a [Spec]
    module describing the API via the [Lin.val_] DSL, then instantiate
    [Lin_domain.Make] to obtain the parallel linearizability test.

    Scope
    =====
    [Lin_domain] runs each command synchronously on its domain; there is
    no hook to wrap the domain in an Eio event loop.  That limits the
    exposed operations to the primitives that never suspend, i.e.
    [try_acquire] and [release].  The suspending [acquire] path is
    exercised by [semaphore_manual_test.ml] and the Task-3 harness
    [semaphore_lin_test.ml], not here. *)

module SemaphoreSig = struct
  type t = Semaphore.t

  let init    () = Semaphore.make 2
  let cleanup _  = ()

  open Lin
  let api = [
    val_ "Semaphore.try_acquire"       Semaphore.try_acquire
         (t @-> returning bool);
    val_ "Semaphore.release"           Semaphore.release
         (t @-> returning unit);
    val_ "Semaphore.available_permits" Semaphore.available_permits
         (t @-> returning int);
  ]
end

module Sem_domain = Lin_domain.Make (SemaphoreSig)

let () =
  QCheck_base_runner.run_tests_main [
    Sem_domain.lin_test ~count:1000
      ~name:"Semaphore (try_acquire/release) linearizability";
  ]
