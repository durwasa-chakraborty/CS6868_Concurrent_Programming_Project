(** Manual concurrent tests for [Blocking_queue_pool] and [Blocking_stack_pool].

    The two pools share a [BlockingPool] interface; every scenario below
    is parameterised by a module of that signature and run against both
    variants.

    Scenarios
    =========
    1. Sequential basic — put; retrieve round-trips the value.
    2. Blocking retrieve — retrieve on an empty pool blocks until a
       concurrent put arrives.
    3. FIFO order (queue) / LIFO order (stack) — single producer, single
       consumer, three values.
    4. No lost items — N producers + N consumers exchange every integer
       in [0, N*M); the multiset of retrieved values equals the multiset
       of deposited values.
    5. Stress — N producers × M puts and N consumers × M retrieves,
       interleaved; no deadlock and all items accounted for. *)

let printf = Printf.printf
let fail fmt = Printf.ksprintf (fun s -> printf "FAIL: %s\n" s; exit 1) fmt

module type Pool = sig
  type 'a t
  val make     : unit -> 'a t
  val put      : 'a t -> 'a -> unit
  val retrieve : 'a t -> 'a
  val name     : string
  val ordering : [ `Fifo | `Lifo ]
end

module Queue_pool : Pool = struct
  type 'a t = 'a Blocking_queue_pool.t
  let make     () = Blocking_queue_pool.make ()
  let put      t v = Blocking_queue_pool.put t v
  let retrieve t   = Blocking_queue_pool.retrieve t
  let name = "queue"
  let ordering = `Fifo
end

module Stack_pool : Pool = struct
  type 'a t = 'a Blocking_stack_pool.t
  let make     () = Blocking_stack_pool.make ()
  let put      t v = Blocking_stack_pool.put t v
  let retrieve t   = Blocking_stack_pool.retrieve t
  let name = "stack"
  let ordering = `Lifo
end

(* ------------------------------------------------------------------ *)
(* 1. Sequential                                                       *)
(* ------------------------------------------------------------------ *)
let test_sequential_basic (module P : Pool) =
  Sqs_effects.run (fun () ->
    let p = P.make () in
    P.put p 42;
    let v = P.retrieve p in
    if v <> 42 then fail "%s: round-trip got %d" P.name v)

(* ------------------------------------------------------------------ *)
(* 2. Blocking retrieve                                                *)
(* ------------------------------------------------------------------ *)
let test_blocking_retrieve (module P : Pool) =
  let p = P.make () in
  let got = Atomic.make (-1) in
  let entered = Atomic.make false in
  let d = Domain.spawn (fun () ->
    Eio_main.run (fun _env ->
      Atomic.set entered true;
      Atomic.set got (P.retrieve p)))
  in
  while not (Atomic.get entered) do Domain.cpu_relax () done;
  Unix.sleepf 0.05;
  if Atomic.get got >= 0 then fail "%s: retrieved before put" P.name;
  P.put p 77;
  Domain.join d;
  if Atomic.get got <> 77 then
    fail "%s: got %d expected 77" P.name (Atomic.get got)

(* ------------------------------------------------------------------ *)
(* 3. Ordering: FIFO for queue, LIFO for stack                         *)
(* ------------------------------------------------------------------ *)
let test_ordering (module P : Pool) =
  Sqs_effects.run (fun () ->
    let p = P.make () in
    P.put p 1; P.put p 2; P.put p 3;
    let a = P.retrieve p and b = P.retrieve p and c = P.retrieve p in
    let expected = match P.ordering with
      | `Fifo -> [1; 2; 3]
      | `Lifo -> [3; 2; 1]
    in
    if [a; b; c] <> expected then
      fail "%s: ordering got [%d; %d; %d]" P.name a b c)

(* ------------------------------------------------------------------ *)
(* 4. No lost items — multiset equality under concurrency              *)
(* ------------------------------------------------------------------ *)
let test_no_lost_items (module P : Pool) =
  let n_producers = 4 and per_producer = 50 in
  let p = P.make () in
  let total = n_producers * per_producer in
  let got = Atomic.make 0 in
  let seen = Array.init total (fun _ -> Atomic.make 0) in
  let producers = Array.init n_producers (fun pi ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        for j = 0 to per_producer - 1 do
          P.put p (pi * per_producer + j)
        done)))
  in
  let consumers = Array.init n_producers (fun _ ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        for _ = 1 to per_producer do
          let v = P.retrieve p in
          Atomic.incr seen.(v);
          Atomic.incr got
        done)))
  in
  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;
  if Atomic.get got <> total then
    fail "%s: retrieved %d expected %d" P.name (Atomic.get got) total;
  for i = 0 to total - 1 do
    if Atomic.get seen.(i) <> 1 then
      fail "%s: item %d seen %d times" P.name i (Atomic.get seen.(i))
  done

(* ------------------------------------------------------------------ *)
(* 5. Stress                                                           *)
(* ------------------------------------------------------------------ *)
let test_stress (module P : Pool) =
  let n = 6 and m = 80 in
  let p = P.make () in
  let got = Atomic.make 0 in
  let producers = Array.init n (fun _ ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        for _ = 1 to m do P.put p 1 done)))
  in
  let consumers = Array.init n (fun _ ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        for _ = 1 to m do
          let _ = P.retrieve p in Atomic.incr got
        done)))
  in
  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;
  if Atomic.get got <> n * m then
    fail "%s: stress got=%d expected=%d" P.name (Atomic.get got) (n * m)

(* ------------------------------------------------------------------ *)
(* Driver                                                              *)
(* ------------------------------------------------------------------ *)
let run_all (module P : Pool) =
  test_sequential_basic  (module P); printf "ok  %s.sequential_basic\n"  P.name;
  test_blocking_retrieve (module P); printf "ok  %s.blocking_retrieve\n" P.name;
  test_ordering          (module P); printf "ok  %s.ordering\n"          P.name;
  test_no_lost_items     (module P); printf "ok  %s.no_lost_items\n"     P.name;
  test_stress            (module P); printf "ok  %s.stress\n"            P.name

let () =
  run_all (module Queue_pool);
  run_all (module Stack_pool);
  printf "\nAll blocking-pool manual tests passed!\n"
