(** Tiny multi-domain benchmark harness for the SQS primitives.

    Contract
    ========
    A benchmark declares:
      - a name for the [primitive] and the [workload]
      - the number of threads (domains on OCaml)
      - a [setup] to initialise the shared SUT
      - a [body : int -> unit] that performs ONE operation for thread
        index [i].  The body is called in a tight loop inside each
        domain's own [Eio_main.run].

    The harness spawns [threads] domains, uses a spin barrier to start
    them together, runs a 1 s warm-up (counts discarded), then times a
    3 s measurement window.  It returns throughput (ops/s) and mean
    latency (ns/op) aggregated across all domains.

    The CSV schema matches the Java-side [Bench]:

      implementation,primitive,workload,threads,ops,duration_s,
      throughput_ops_s,mean_latency_ns,repeat

    [implementation] is always ["ocaml"] from this module. *)

type result = {
  primitive   : string;
  workload    : string;
  threads     : int;
  ops         : int;
  duration_s  : float;
  throughput  : float;
  mean_ns     : float;
  repeat      : int;
}

let now_ns () =
  (* Nanosecond wall-clock — enough precision for ≥µs-scale operations. *)
  Int64.of_float (Unix.gettimeofday () *. 1e9)

(** [run] supports two measurement modes:

    - [ops = 0] (default): time-based.  Warm up for [warmup_ms], measure
      for [measure_ms], count ops.  Reports throughput.
    - [ops > 0]: fixed-N.  Warm up for [warmup_ms], then run exactly
      [ops] iterations per thread, time the wall clock.  Total ops =
      [ops * threads].  Use this when you want both implementations to
      perform the same amount of work and compare wall-clock cost. *)
let run
    ~primitive
    ~workload
    ~threads
    ?(warmup_ms   = 1000)
    ?(measure_ms  = 3000)
    ?(ops         = 0)
    ?(repeat      = 0)
    ~(body : int -> unit)
    () : result =
  if ops > 0 then begin
    (* -------- Fixed-N mode -------- *)
    let warming = Atomic.make true in
    let started = Atomic.make 0 in
    let worker d () =
      Eio_main.run (fun _env ->
        Atomic.incr started;
        while Atomic.get started < threads do Domain.cpu_relax () done;
        while Atomic.get warming do body d done;
        for _ = 1 to ops do body d done)
    in
    let domains = Array.init threads (fun d -> Domain.spawn (worker d)) in
    while Atomic.get started < threads do Domain.cpu_relax () done;
    Unix.sleepf (float warmup_ms /. 1000.);
    let t0 = now_ns () in
    Atomic.set warming false;
    Array.iter Domain.join domains;
    let t1 = now_ns () in
    let total_ops  = ops * threads in
    let elapsed_ns = Int64.to_float (Int64.sub t1 t0) in
    let duration_s = elapsed_ns /. 1e9 in
    let throughput = if duration_s > 0. then float total_ops /. duration_s else 0. in
    let mean_ns =
      if total_ops > 0 then elapsed_ns *. float threads /. float total_ops else 0.
    in
    { primitive; workload; threads; ops = total_ops; duration_s;
      throughput; mean_ns; repeat }
  end else begin
    (* -------- Time-based mode -------- *)
    let warming = Atomic.make true in
    let running = Atomic.make true in
    let started = Atomic.make 0 in
    let counts  = Array.make threads 0 in

    let worker d () =
      Eio_main.run (fun _env ->
        Atomic.incr started;
        while Atomic.get started < threads do Domain.cpu_relax () done;
        while Atomic.get warming do body d done;
        let c = ref 0 in
        while Atomic.get running do
          body d;
          incr c
        done;
        counts.(d) <- !c)
    in
    let domains = Array.init threads (fun d -> Domain.spawn (worker d)) in

    while Atomic.get started < threads do Domain.cpu_relax () done;
    Unix.sleepf (float warmup_ms /. 1000.);
    Atomic.set warming false;

    let t0 = now_ns () in
    Unix.sleepf (float measure_ms /. 1000.);
    Atomic.set running false;
    Array.iter Domain.join domains;
    let t1 = now_ns () in

    let elapsed_ns = Int64.to_float (Int64.sub t1 t0) in
    let duration_s = elapsed_ns /. 1e9 in
    let total_ops = Array.fold_left (+) 0 counts in
    let throughput = if duration_s > 0. then float total_ops /. duration_s else 0. in
    let mean_ns =
      if total_ops > 0 then elapsed_ns *. float threads /. float total_ops else 0.
    in
    { primitive; workload; threads; ops = total_ops; duration_s;
      throughput; mean_ns; repeat }
  end

(* ------------------------------------------------------------------ *)
(* CSV output                                                          *)
(* ------------------------------------------------------------------ *)

let csv_header =
  "implementation,primitive,workload,threads,ops,duration_s,throughput_ops_s,mean_latency_ns,repeat"

let csv_row r =
  Printf.sprintf "ocaml,%s,%s,%d,%d,%.6f,%.2f,%.2f,%d"
    r.primitive r.workload r.threads r.ops r.duration_s
    r.throughput r.mean_ns r.repeat

let append_to ~path row =
  let fresh = not (Sys.file_exists path) in
  let oc = open_out_gen [Open_append; Open_creat; Open_text] 0o644 path in
  if fresh then (output_string oc csv_header; output_char oc '\n');
  output_string oc row;
  output_char oc '\n';
  close_out oc

let pp_stdout r =
  Printf.printf "ocaml  %-30s %-16s T=%d  %10d ops  %9.0f ops/s  %7.0f ns/op (repeat %d)\n%!"
    r.primitive r.workload r.threads r.ops r.throughput r.mean_ns r.repeat
