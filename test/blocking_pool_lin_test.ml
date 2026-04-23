(** Linearisability tests for the blocking resource pools.

    Port of [BlockingPoolLincheckTestBase] in
    [test/kotlin/CancellableQueueSynchronizerLincheckTests.kt], covering
    both the queue-backed and stack-backed implementations.  The payload
    type is [unit] (Kotlin uses [Unit]) since the pool is treated as a
    bag with no ordering guarantee on retrieval.

    Sequential model
    ================
    State = number of deposited elements (negative ⇒ number of waiters).

      put       any state  →  Some (state + 1, ())
      retrieve  state > 0  →  Some (state - 1, ())
      retrieve  state ≤ 0  →  None                      would suspend *)

(* ------------------------------------------------------------------ *)
(* Shared spec over any pool type                                     *)
(* ------------------------------------------------------------------ *)

module type Pool_api = sig
  type t
  val make     : unit -> t
  val put      : t -> unit -> unit
  val retrieve : t -> unit
  val name     : string
end

module Make (P : Pool_api) = struct
  type sut   = P.t
  type state = int
  type op    = Put | Retrieve
  type res   = unit

  let init_sut   () = P.make ()
  let init_state () = 0

  let next state = function
    | Put      -> Some (state + 1, ())
    | Retrieve ->
      if state > 0 then Some (state - 1, ())
      else None

  let run sut = function
    | Put      -> P.put sut ()
    | Retrieve -> P.retrieve sut

  let equal () () = true
  let show_op  = function Put -> "put" | Retrieve -> "retrieve"
  let show_res () = "()"

  (** Each domain issues [Put; Retrieve; Put; Retrieve; …], always starting
      with [Put].  This guarantees that the total puts across all domains
      is never exceeded by the retrieves, so no retrieve can permanently
      block an empty pool.  The Eio scheduler still produces plenty of
      interleavings for the linearisability checker to explore. *)
  let gen_ops n =
    QCheck2.Gen.return
      (List.init n (fun i -> if i mod 2 = 0 then Put else Retrieve))
end

(* ------------------------------------------------------------------ *)
(* Concrete pool bindings                                             *)
(* ------------------------------------------------------------------ *)

module Queue_pool : Pool_api = struct
  type t = unit Blocking_queue_pool.t
  let make     () = Blocking_queue_pool.make ()
  let put      t v = Blocking_queue_pool.put t v
  let retrieve t   = Blocking_queue_pool.retrieve t
  let name     = "BlockingQueuePool"
end

module Stack_pool : Pool_api = struct
  type t = unit Blocking_stack_pool.t
  let make     () = Blocking_stack_pool.make ()
  let put      t v = Blocking_stack_pool.put t v
  let retrieve t   = Blocking_stack_pool.retrieve t
  let name     = "BlockingStackPool"
end

module Queue_spec = Make (Queue_pool)
module Stack_spec = Make (Stack_pool)

let () =
  QCheck_base_runner.run_tests_main [
    Lin_harness.make_test (module Queue_spec)
      ~n_domains:2 ~ops_per_domain:4 ~count:300
      (Queue_pool.name ^ " linearisability");
    Lin_harness.make_test (module Queue_spec)
      ~n_domains:3 ~ops_per_domain:2 ~count:150
      (Queue_pool.name ^ " 3-domain linearisability");
    Lin_harness.make_test (module Stack_spec)
      ~n_domains:2 ~ops_per_domain:4 ~count:300
      (Stack_pool.name ^ " linearisability");
    Lin_harness.make_test (module Stack_spec)
      ~n_domains:3 ~ops_per_domain:2 ~count:150
      (Stack_pool.name ^ " 3-domain linearisability");
  ]
