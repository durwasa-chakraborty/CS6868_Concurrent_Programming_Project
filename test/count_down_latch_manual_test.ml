(** Manual concurrent tests for [Count_down_latch].

    Scenarios
    =========
    1. Sequential basic — counts down to zero, remaining tracks correctly.
    2. Await after fire — once the latch has fired, [await] returns
       immediately (no suspension).
    3. Await before fire — an awaiter on D1 must unblock when another
       domain drives the count to zero.
    4. Multiple awaiters — every parked awaiter wakes up when the latch
       fires, regardless of which domain held it.
    5. Concurrent count-downs — N domains each issue one [count_down];
       the N-th decrement releases any pending awaiters exactly once. *)

let printf = Printf.printf
let fail fmt = Printf.ksprintf (fun s -> printf "FAIL: %s\n" s; exit 1) fmt

(* ------------------------------------------------------------------ *)
(* 1. Sequential                                                       *)
(* ------------------------------------------------------------------ *)
let test_sequential_basic () =
  let l = Count_down_latch.make 3 in
  if Count_down_latch.remaining l <> 3 then fail "initial";
  Count_down_latch.count_down l;
  if Count_down_latch.remaining l <> 2 then fail "after 1 count_down";
  Count_down_latch.count_down l;
  Count_down_latch.count_down l;
  if Count_down_latch.remaining l <> 0 then fail "after 3 count_downs";
  (* Extra count_downs must never make remaining negative. *)
  Count_down_latch.count_down l;
  if Count_down_latch.remaining l <> 0 then fail "remaining clamped at 0"

(* ------------------------------------------------------------------ *)
(* 2. Await after fire                                                 *)
(* ------------------------------------------------------------------ *)
let test_await_after_fire () =
  Sqs_effects.run (fun () ->
    let l = Count_down_latch.make 1 in
    Count_down_latch.count_down l;
    (* Should not suspend. *)
    Count_down_latch.await l)

(* ------------------------------------------------------------------ *)
(* 3. Await before fire                                                *)
(* ------------------------------------------------------------------ *)
let test_await_before_fire () =
  let l = Count_down_latch.make 1 in
  let awoke = Atomic.make false in
  let entered = Atomic.make false in
  let d = Domain.spawn (fun () ->
    Eio_main.run (fun _env ->
      Atomic.set entered true;
      Count_down_latch.await l;
      Atomic.set awoke true))
  in
  while not (Atomic.get entered) do Domain.cpu_relax () done;
  Unix.sleepf 0.05;
  if Atomic.get awoke then fail "awoke before count_down";
  Count_down_latch.count_down l;
  Domain.join d;
  if not (Atomic.get awoke) then fail "never awoke"

(* ------------------------------------------------------------------ *)
(* 4. Multiple awaiters wake up together                               *)
(* ------------------------------------------------------------------ *)
let test_multiple_awaiters () =
  let n_awaiters = 4 in
  let l = Count_down_latch.make 2 in
  let woken = Atomic.make 0 in
  let domains = Array.init n_awaiters (fun _ ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        Count_down_latch.await l;
        Atomic.incr woken)))
  in
  Unix.sleepf 0.05;   (* let everyone park *)
  Count_down_latch.count_down l;   (* remaining: 1 *)
  Count_down_latch.count_down l;   (* remaining: 0 — fires *)
  Array.iter Domain.join domains;
  if Atomic.get woken <> n_awaiters then
    fail "woken=%d expected=%d" (Atomic.get woken) n_awaiters

(* ------------------------------------------------------------------ *)
(* 5. Concurrent count-downs drive the latch to zero exactly once      *)
(* ------------------------------------------------------------------ *)
let test_concurrent_count_downs () =
  let n = 8 in
  let l = Count_down_latch.make n in
  let done_flag = Atomic.make false in
  let awaiter = Domain.spawn (fun () ->
    Eio_main.run (fun _env ->
      Count_down_latch.await l;
      Atomic.set done_flag true))
  in
  let counters = Array.init n (fun _ ->
    Domain.spawn (fun () -> Count_down_latch.count_down l))
  in
  Array.iter Domain.join counters;
  Domain.join awaiter;
  if not (Atomic.get done_flag) then fail "awaiter never woke";
  if Count_down_latch.remaining l <> 0 then fail "remaining non-zero"

(* ------------------------------------------------------------------ *)
(* Driver                                                              *)
(* ------------------------------------------------------------------ *)
let () =
  test_sequential_basic ();        printf "ok  sequential_basic\n";
  test_await_after_fire ();        printf "ok  await_after_fire\n";
  test_await_before_fire ();       printf "ok  await_before_fire\n";
  test_multiple_awaiters ();       printf "ok  multiple_awaiters\n";
  test_concurrent_count_downs (); printf "ok  concurrent_count_downs\n";
  printf "\nAll Count_down_latch manual tests passed!\n"
