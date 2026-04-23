(** Manual concurrent tests for [Semaphore].

    Follows the [test_manual.ml] template: one top-level function per
    scenario, each asserting its post-condition, plus a driver that runs
    them in sequence.

    Scenarios
    =========
    1. Sequential basic — make/acquire/release under no contention.
    2. try_acquire fast path — returns true when permits available,
       false when exhausted.
    3. Mutual exclusion — 2 domains, Semaphore(1), 100 increments each
       of a shared counter under the semaphore.  Final counter must equal
       200 iff [acquire]/[release] provide mutex semantics.
    4. Cross-domain wakeup — D0 holds the permit while D1's [acquire]
       suspends; D0's [release] must wake D1 from the other domain.
    5. Stress — N domains × M ops of alternating acquire/release on
       Semaphore(P); must not deadlock or lose permits. *)

let printf = Printf.printf
let log_mutex = Stdlib.Mutex.create ()
let log fmt =
  Printf.ksprintf (fun s ->
    Stdlib.Mutex.lock log_mutex;
    print_string s; print_newline (); flush stdout;
    Stdlib.Mutex.unlock log_mutex) fmt

let fail fmt = Printf.ksprintf (fun s -> printf "FAIL: %s\n" s; exit 1) fmt

(* ------------------------------------------------------------------ *)
(* 1. Sequential                                                       *)
(* ------------------------------------------------------------------ *)
let test_sequential_basic () =
  Sqs_effects.run (fun () ->
    let s = Semaphore.make 2 in
    if Semaphore.available_permits s <> 2 then fail "initial permits";
    Semaphore.acquire s;
    Semaphore.acquire s;
    if Semaphore.available_permits s <> 0 then fail "after 2 acquires";
    Semaphore.release s;
    Semaphore.release s;
    if Semaphore.available_permits s <> 2 then fail "after 2 releases")

(* ------------------------------------------------------------------ *)
(* 2. try_acquire fast path                                            *)
(* ------------------------------------------------------------------ *)
let test_try_acquire () =
  let s = Semaphore.make 1 in
  if not (Semaphore.try_acquire s) then fail "try_acquire on fresh(1)";
  if      Semaphore.try_acquire s  then fail "try_acquire on empty";
  Semaphore.release s;
  if not (Semaphore.try_acquire s) then fail "try_acquire after release"

(* ------------------------------------------------------------------ *)
(* 3. Mutual exclusion across domains                                  *)
(* ------------------------------------------------------------------ *)
let test_mutual_exclusion () =
  let s = Semaphore.make 1 in
  let counter = ref 0 in   (* deliberately non-atomic: relies on mutex *)
  let iters = 100 in
  let worker () =
    Eio_main.run (fun _env ->
      for _ = 1 to iters do
        Semaphore.acquire s;
        let v = !counter in
        Domain.cpu_relax ();
        counter := v + 1;
        Semaphore.release s
      done)
  in
  let d1 = Domain.spawn worker in
  let d2 = Domain.spawn worker in
  Domain.join d1; Domain.join d2;
  if !counter <> 2 * iters then
    fail "mutual exclusion: counter=%d expected=%d" !counter (2 * iters)

(* ------------------------------------------------------------------ *)
(* 4. Cross-domain wakeup                                              *)
(* ------------------------------------------------------------------ *)
let test_cross_domain_wakeup () =
  let s = Semaphore.make 1 in
  (* D0 takes the permit on the main thread, then D1 will block on
     acquire, then main releases, D1 must unblock from D0. *)
  Semaphore.acquire s;   (* main: fast path, permit=0. no Eio needed. *)
  let woken = Atomic.make false in
  let entered = Atomic.make false in
  let d1 = Domain.spawn (fun () ->
    Eio_main.run (fun _env ->
      Atomic.set entered true;
      Semaphore.acquire s;   (* blocks: permit would go -1 *)
      Atomic.set woken true))
  in
  while not (Atomic.get entered) do Domain.cpu_relax () done;
  (* Give D1 a moment to actually park inside Eio. *)
  Unix.sleepf 0.05;
  if Atomic.get woken then fail "D1 woke before release";
  Semaphore.release s;     (* wakes D1 via Light_thread.resume *)
  Domain.join d1;
  if not (Atomic.get woken) then fail "D1 never woke"

(* ------------------------------------------------------------------ *)
(* 5. Stress: N domains × M alternating acquire/release                *)
(* ------------------------------------------------------------------ *)
let test_stress () =
  let n_domains = 4 and ops_per_domain = 200 and permits = 2 in
  let s = Semaphore.make permits in
  let domains = Array.init n_domains (fun _ ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        for _ = 1 to ops_per_domain do
          Semaphore.acquire s;
          Semaphore.release s
        done)))
  in
  Array.iter Domain.join domains;
  if Semaphore.available_permits s <> permits then
    fail "stress: permits=%d expected=%d"
      (Semaphore.available_permits s) permits

(* ------------------------------------------------------------------ *)
(* Driver                                                              *)
(* ------------------------------------------------------------------ *)
let () =
  test_sequential_basic ();       log "ok  sequential_basic";
  test_try_acquire ();            log "ok  try_acquire";
  test_mutual_exclusion ();       log "ok  mutual_exclusion";
  test_cross_domain_wakeup ();    log "ok  cross_domain_wakeup";
  test_stress ();                 log "ok  stress";
  printf "\nAll Semaphore manual tests passed!\n"
