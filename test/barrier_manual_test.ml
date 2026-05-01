(** Manual concurrent tests for [Barrier].

    Scenarios
    =========
    1. Sequential trivial (parties=1) — [arrive] returns true without
       suspending because the caller is the last party.
    2. Rendezvous (parties=3) — 3 domains each [arrive]; all must return
       true and complete before any domain joins.
    3. Excess arrivals — parties=2, 3 total arrivals.  The first 2 return
       true (they rendezvous); the 3rd sees [arrived >= parties] and
       returns false. *)

let printf = Printf.printf
let fail fmt = Printf.ksprintf (fun s -> printf "FAIL: %s\n" s; exit 1) fmt

(* ------------------------------------------------------------------ *)
(* 1. parties=1 — sole party is the last party                         *)
(* ------------------------------------------------------------------ *)
let test_sequential_basic () =
  Sqs_effects.run (fun () ->
    let b = Barrier.make 1 in
    if not (Barrier.arrive b) then fail "single-party barrier")

(* ------------------------------------------------------------------ *)
(* 2. parties=3 rendezvous across 3 domains                            *)
(* ------------------------------------------------------------------ *)
let test_rendezvous () =
  let parties = 3 in
  let b = Barrier.make parties in
  let results = Array.make parties false in
  let domains = Array.init parties (fun i ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        results.(i) <- Barrier.arrive b)))
  in
  Array.iter Domain.join domains;
  Array.iteri (fun i r ->
    if not r then fail "party %d did not rendezvous" i) results

(* ------------------------------------------------------------------ *)
(* 3. Excess arrivals return false                                     *)
(* ------------------------------------------------------------------ *)
let test_excess_arrivals () =
  let parties = 2 in
  let b = Barrier.make parties in
  let results = Array.make 3 false in
  let d0 = Domain.spawn (fun () ->
    Eio_main.run (fun _env -> results.(0) <- Barrier.arrive b))
  in
  let d1 = Domain.spawn (fun () ->
    Eio_main.run (fun _env -> results.(1) <- Barrier.arrive b))
  in
  Domain.join d0; Domain.join d1;
  (* Both first two should have rendezvoused. *)
  if not (results.(0) && results.(1)) then
    fail "first two arrivals did not rendezvous";
  (* A third arrive after the barrier completed must return false. *)
  Sqs_effects.run (fun () ->
    results.(2) <- Barrier.arrive b);
  if results.(2) then fail "excess arrival returned true"

(* ------------------------------------------------------------------ *)
(* Driver                                                              *)
(* ------------------------------------------------------------------ *)
let () =
  test_sequential_basic ();    printf "ok  sequential_basic\n";
  test_rendezvous ();          printf "ok  rendezvous\n";
  test_excess_arrivals ();     printf "ok  excess_arrivals\n";
  printf "\nAll Barrier manual tests passed!\n"
