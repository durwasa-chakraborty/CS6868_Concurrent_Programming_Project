(** Manual concurrent tests for [Mutex].

    [Mutex.lock] takes a callback and runs it under the lock — it is
    equivalent to Kotlin's [mutex.withLock { … }].  The tests below
    follow the [test_manual.ml] template.

    Scenarios
    =========
    1. Sequential basic — uncontended lock runs the callback and returns.
    2. Mutual exclusion — two domains each run 200 increments inside the
       lock; the final counter equals 400 iff the mutex serialises them.
    3. Cross-domain wakeup — one domain parks in [lock]; another calls
       [unlock]; the parked fibre must run its callback. *)

let printf = Printf.printf
let fail fmt = Printf.ksprintf (fun s -> printf "FAIL: %s\n" s; exit 1) fmt

(* ------------------------------------------------------------------ *)
(* 1. Sequential basic                                                 *)
(* ------------------------------------------------------------------ *)
let test_sequential_basic () =
  Sqs_effects.run (fun () ->
    let m = Mutex.make () in
    let ran = ref false in
    Mutex.lock m (fun () -> ran := true);
    Mutex.unlock m;
    if not !ran then fail "callback did not run")

(* ------------------------------------------------------------------ *)
(* 2. Mutual exclusion                                                 *)
(* ------------------------------------------------------------------ *)
let test_mutual_exclusion () =
  let m = Mutex.make () in
  let counter = ref 0 in   (* non-atomic — relies on mutex *)
  let iters = 200 in
  let worker () =
    Eio_main.run (fun _env ->
      for _ = 1 to iters do
        Mutex.lock m (fun () ->
          let v = !counter in
          Domain.cpu_relax ();
          counter := v + 1);
        Mutex.unlock m
      done)
  in
  let d1 = Domain.spawn worker in
  let d2 = Domain.spawn worker in
  Domain.join d1; Domain.join d2;
  if !counter <> 2 * iters then
    fail "counter=%d expected=%d" !counter (2 * iters)

(* ------------------------------------------------------------------ *)
(* 3. Cross-domain wakeup                                              *)
(* ------------------------------------------------------------------ *)
let test_cross_domain_wakeup () =
  let m = Mutex.make () in
  (* Grab the lock on the main thread (fast path, no suspension). *)
  Mutex.lock m (fun () -> ());
  let ran = Atomic.make false in
  let entered = Atomic.make false in
  let d = Domain.spawn (fun () ->
    Eio_main.run (fun _env ->
      Atomic.set entered true;
      Mutex.lock m (fun () -> Atomic.set ran true);
      Mutex.unlock m))
  in
  while not (Atomic.get entered) do Domain.cpu_relax () done;
  Unix.sleepf 0.05;
  if Atomic.get ran then fail "ran before unlock";
  Mutex.unlock m;
  Domain.join d;
  if not (Atomic.get ran) then fail "callback never ran"

(* ------------------------------------------------------------------ *)
(* Driver                                                              *)
(* ------------------------------------------------------------------ *)
let () =
  test_sequential_basic ();     printf "ok  sequential_basic\n";
  test_mutual_exclusion ();     printf "ok  mutual_exclusion\n";
  test_cross_domain_wakeup ();  printf "ok  cross_domain_wakeup\n";
  printf "\nAll Mutex manual tests passed!\n"
