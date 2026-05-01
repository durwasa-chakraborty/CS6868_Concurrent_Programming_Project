(** Generic linearisability test harness for SQS primitives.

    Architecture
    ============
    - N domains are spawned, each running its operations inside its own
      [Eio_main.run] event loop.
    - A spin barrier synchronises domain start to maximise concurrent overlap.
    - Domains join naturally once all operations have completed.
    - Linearisability is verified by backtracking over all per-domain
      interleavings and comparing actual results against the sequential model.

    Why one [Eio_main.run] per domain?
    ====================================
    [Light_thread.suspend] calls [Eio.Private.Suspend.enter], which must run
    inside an Eio scheduler.  Eio's enqueue function is domain-safe: a resume
    issued from domain D1 correctly wakes a fibre suspended in D0's scheduler.
    Each domain therefore gets its own independent Eio event loop. *)

(* ------------------------------------------------------------------ *)
(* Specification interface                                             *)
(* ------------------------------------------------------------------ *)

module type Spec = sig
  type sut    (** System under test — shared across all domains.       *)
  type state  (** Sequential model state.                              *)
  type op     (** Operation type.                                      *)
  type res    (** Result type.                                         *)

  val init_sut   : unit -> sut
  val init_state : unit -> state

  (** [next state op] returns [Some (state', res)] if [op] is valid from
      [state] and produces result [res] in the sequential model.
      Returns [None] if [op] would block in this state — the checker then
      tries a different interleaving where a matching operation comes first.*)
  val next : state -> op -> (state * res) option

  (** Run [op] against the shared [sut].  Always called from within an
      [Eio_main.run] context, so [Light_thread.suspend] is available. *)
  val run : sut -> op -> res

  val equal   : res -> res -> bool
  val show_op : op -> string
  val show_res : res -> string

  (** [gen_ops n] generates a list of [n] operations for one domain.
      Implementations should ensure the generated sequences cannot permanently
      deadlock (e.g. equal numbers of acquire and release). *)
  val gen_ops : int -> op list QCheck2.Gen.t
end

(* ------------------------------------------------------------------ *)
(* Linearisability checker                                             *)
(* ------------------------------------------------------------------ *)

(** [check_linearizable (module S) ~init_state traces] returns [true] iff
    some sequential interleaving of the per-domain [traces] is consistent
    with the sequential model.  Per-domain operation order is always
    preserved; the search backtracks when [S.next] returns [None] or the
    expected result differs from the observed one. *)
let check_linearizable
    (type sut state op res)
    (module S : Spec with type sut   = sut   and type state = state
                      and type op    = op    and type res   = res)
    ~(init_state : state)
    (traces : (op * res) array array) : bool =
  let n       = Array.length traces in
  let indices = Array.make n 0 in
  let lengths = Array.map Array.length traces in
  let rec go state =
    let all_done = ref true in
    for d = 0 to n - 1 do
      if indices.(d) < lengths.(d) then all_done := false
    done;
    if !all_done then true
    else begin
      let found = ref false in
      let d     = ref 0 in
      while !d < n && not !found do
        if indices.(!d) < lengths.(!d) then begin
          let (op, actual) = traces.(!d).(indices.(!d)) in
          (match S.next state op with
           | None -> ()
           | Some (state', expected) ->
             if S.equal expected actual then begin
               indices.(!d) <- indices.(!d) + 1;
               if go state' then found := true;
               indices.(!d) <- indices.(!d) - 1    (* backtrack *)
             end)
        end;
        incr d
      done;
      !found
    end
  in
  go init_state

(* ------------------------------------------------------------------ *)
(* Parallel runner                                                     *)
(* ------------------------------------------------------------------ *)

(** [run_parallel (module S) ~sut ops] spawns one domain per row of [ops],
    executes the operations sequentially within each domain's Eio event loop,
    and returns per-domain [(op, result)] traces. *)
let run_parallel
    (type sut state op res)
    (module S : Spec with type sut   = sut   and type state = state
                      and type op    = op    and type res   = res)
    ~(sut : sut)
    (ops  : op array array) : (op * res) array array =
  let n     = Array.length ops in
  let ready = Atomic.make 0 in
  let domains = Array.init n (fun d ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        (* Spin barrier: stall until all domains are inside Eio *)
        Atomic.incr ready;
        while Atomic.get ready < n do Domain.cpu_relax () done;
        (* Execute this domain's ops sequentially within one Eio fibre *)
        Array.map (fun op -> (op, S.run sut op)) ops.(d)
      )
    )
  ) in
  (* Join in spawn order.  Domains run concurrently; join only waits for
     completion, so this cannot deadlock even if d0 blocks waiting for d1. *)
  Array.map Domain.join domains

(* ------------------------------------------------------------------ *)
(* Error formatting                                                    *)
(* ------------------------------------------------------------------ *)

let pp_violation
    (type sut state op res)
    (module S : Spec with type sut   = sut   and type state = state
                      and type op    = op    and type res   = res)
    (traces : (op * res) array array) : string =
  let buf = Buffer.create 256 in
  Array.iteri (fun d trace ->
    Printf.bprintf buf "  Domain %d:\n" d;
    Array.iter (fun (op, res) ->
      Printf.bprintf buf "    %-20s -> %s\n" (S.show_op op) (S.show_res res)
    ) trace
  ) traces;
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* QCheck2 test builder                                                *)
(* ------------------------------------------------------------------ *)

(** [make_test (module S) ?n_domains ?ops_per_domain ?count name] creates a
    [QCheck2.Test.t] that runs [count] random parallel trials and checks
    linearisability of the observed results. *)
let make_test
    (type sut state op res)
    (module S : Spec with type sut   = sut   and type state = state
                      and type op    = op    and type res   = res)
    ?(n_domains      = 2)
    ?(ops_per_domain = 4)
    ?(count          = 200)
    (name : string) : QCheck2.Test.t =
  let gen =
    QCheck2.Gen.(array_size (return n_domains) (S.gen_ops ops_per_domain))
  in
  QCheck2.Test.make ~name ~count gen (fun ops_lists ->
    let sut        = S.init_sut   () in
    let init_state = S.init_state () in
    let ops        = Array.map Array.of_list ops_lists in
    let traces     = run_parallel (module S) ~sut ops in
    let ok         = check_linearizable (module S) ~init_state traces in
    if not ok then
      Printf.eprintf "Linearisability violation!\n%s\n%!"
        (pp_violation (module S) traces);
    ok
  )
