(** OCaml benchmark driver — one binary that exercises every primitive
    across every workload/thread combination and appends rows to the
    shared summary CSV. *)

let parse_ints s =
  String.split_on_char ',' s
  |> List.filter_map (fun t ->
      let t = String.trim t in
      if t = "" then None else Some (int_of_string t))

let () =
  let out       = ref "benchmark/results/summary.csv" in
  let threads   = ref [1; 2; 4; 8] in
  let repeats   = ref 3 in
  let warmup    = ref 1000 in
  let measure   = ref 2000 in
  let selected  = ref [] in
  let specs = [
    "--out",     Arg.Set_string out,
      " path to summary.csv (default benchmark/results/summary.csv)";
    "--threads", Arg.String (fun s -> threads := parse_ints s),
      " comma-separated thread counts (default 1,2,4,8)";
    "--repeats", Arg.Set_int repeats,
      " number of repetitions per configuration (default 3)";
    "--warmup-ms", Arg.Set_int warmup,
      " warmup duration in ms (default 1000)";
    "--measure-ms", Arg.Set_int measure,
      " measurement duration in ms (default 2000)";
    "--only", Arg.String (fun s ->
        selected := String.split_on_char ',' s |> List.map String.trim),
      " comma-separated subset of primitives to run";
  ] in
  Arg.parse specs (fun _ -> ()) "bench_runner --out … --threads 1,2,4 …";

  let cap_threads =
    try max 1 (Domain.recommended_domain_count () - 1) with _ -> 4
  in
  let wanted prim =
    match !selected with [] -> true | xs -> List.mem prim xs
  in

  let run_bench ~primitive ~workload ~threads ~body =
    for r = 0 to !repeats - 1 do
      let res =
        Bench.run ~primitive ~workload ~threads
          ~warmup_ms:!warmup ~measure_ms:!measure ~repeat:r ~body ()
      in
      Bench.pp_stdout res;
      Bench.append_to ~path:!out (Bench.csv_row res)
    done
  in

  let selected_threads =
    List.filter (fun t -> t <= cap_threads) !threads
    |> function [] -> [1] | xs -> xs
  in

  (* --------------------------------------------------------------- *)
  (* Semaphore                                                        *)
  (* --------------------------------------------------------------- *)
  if wanted "Semaphore" then begin
    List.iter (fun t ->
      let s = Semaphore.make (if t = 1 then 1 else 1) in
      run_bench ~primitive:"Semaphore(1)" ~workload:"W2_contended"
        ~threads:t ~body:(fun _ ->
          Semaphore.acquire s;
          Semaphore.release s)
    ) selected_threads;
    (* Fast-path uncontended baseline. *)
    let s = Semaphore.make 1 in
    run_bench ~primitive:"Semaphore(1)" ~workload:"W1_uncontended"
      ~threads:1 ~body:(fun _ ->
        Semaphore.acquire s;
        Semaphore.release s)
  end;

  (* --------------------------------------------------------------- *)
  (* Mutex                                                            *)
  (* --------------------------------------------------------------- *)
  if wanted "Mutex" then begin
    List.iter (fun t ->
      let m = Mutex.make () in
      run_bench ~primitive:"Mutex" ~workload:"W2_contended"
        ~threads:t ~body:(fun _ ->
          Mutex.lock m (fun () -> ());
          Mutex.unlock m)
    ) selected_threads;
    let m = Mutex.make () in
    run_bench ~primitive:"Mutex" ~workload:"W1_uncontended"
      ~threads:1 ~body:(fun _ ->
        Mutex.lock m (fun () -> ());
        Mutex.unlock m)
  end;

  (* --------------------------------------------------------------- *)
  (* Blocking queue / stack pool — producer/consumer in short cycles. *)
  (* The queue pool uses a fixed-size slot array (1024); long-running *)
  (* producer bursts overrun it, so each cycle uses a fresh pool and  *)
  (* bounded pairs to stay well under the limit.                      *)
  (*                                                                  *)
  (* Workers are spawned ONCE per repeat: each domain enters one      *)
  (* Eio_main.run and walks the pre-allocated pool array.  Spawning a *)
  (* fresh Domain + Eio scheduler per cycle (the previous structure)  *)
  (* leaks pthread stacks and Eio state on macOS — RSS grows into the *)
  (* GBs across the full pipeline and the kernel SIGKILLs the process *)
  (* during the last benchmark.                                       *)
  (* --------------------------------------------------------------- *)
  let run_pool_bench ~primitive ~workload ~make_pool ~put ~retrieve
      ~threads:t =
    if t >= 2 then
      for r = 0 to !repeats - 1 do
        let half            = max 1 (t / 2) in
        (* Total inserts per cycle = half * pairs_per_cycle.  Keep it
           well under Blocking_queue_pool.slot_count = 1024 at every T. *)
        let pairs_per_cycle = max 50 (800 / half) in
        let cycles          = 40 in
        let pools           = Array.init cycles (fun _ -> make_pool ()) in
        let started_at      = Bench.now_ns () in
        let producers = Array.init half (fun _ ->
          Domain.spawn (fun () ->
            Eio_main.run (fun _env ->
              for c = 0 to cycles - 1 do
                for _ = 1 to pairs_per_cycle do put pools.(c) 1 done
              done)))
        in
        let consumers = Array.init half (fun _ ->
          Domain.spawn (fun () ->
            Eio_main.run (fun _env ->
              for c = 0 to cycles - 1 do
                for _ = 1 to pairs_per_cycle do
                  ignore (retrieve pools.(c))
                done
              done)))
        in
        Array.iter Domain.join producers;
        Array.iter Domain.join consumers;
        let ended      = Bench.now_ns () in
        let total_ops  = cycles * pairs_per_cycle * half * 2 in
        let elapsed_ns = Int64.to_float (Int64.sub ended started_at) in
        let duration_s = elapsed_ns /. 1e9 in
        let res = Bench.{
          primitive; workload; threads = t;
          ops = total_ops; duration_s;
          throughput = float total_ops /. duration_s;
          mean_ns    = elapsed_ns /. float total_ops;
          repeat     = r;
        } in
        Bench.pp_stdout res;
        Bench.append_to ~path:!out (Bench.csv_row res)
      done
  in
  if wanted "BlockingQueuePool" then
    List.iter (fun t ->
      run_pool_bench ~primitive:"BlockingQueuePool" ~workload:"W3_pc_queue"
        ~make_pool:Blocking_queue_pool.make
        ~put:Blocking_queue_pool.put
        ~retrieve:Blocking_queue_pool.retrieve
        ~threads:t
    ) selected_threads;

  if wanted "BlockingStackPool" then
    List.iter (fun t ->
      run_pool_bench ~primitive:"BlockingStackPool" ~workload:"W4_pc_stack"
        ~make_pool:Blocking_stack_pool.make
        ~put:Blocking_stack_pool.put
        ~retrieve:Blocking_stack_pool.retrieve
        ~threads:t
    ) selected_threads;

  (* --------------------------------------------------------------- *)
  (* Count-down latch — fire latency                                  *)
  (* --------------------------------------------------------------- *)
  (* Latch is one-shot: measure standalone (not inside the harness's
     long-running loop).  Loop many single-latch cycles and time the
     aggregate. *)
  if wanted "CountDownLatch" then begin
    List.iter (fun t ->
      if t >= 2 then
        for r = 0 to !repeats - 1 do
          let cycles = 200 in
          (* Pre-allocate one latch per cycle and spawn the t-1 awaiter
             domains exactly once per repeat.  Each awaiter walks every
             latch in order; the main thread acts as the firer, waiting
             for all awaiters to park on cycle [c] before counting down.
             This avoids the Domain.spawn + Eio_main.run-per-cycle leak
             that was OOM-killing the process at the end of the run. *)
          let latches = Array.init cycles
            (fun _ -> Count_down_latch.make 1) in
          let awoke = Atomic.make 0 in
          let started_at = Bench.now_ns () in
          let awaiters = Array.init (t - 1) (fun _ ->
            Domain.spawn (fun () ->
              Eio_main.run (fun _env ->
                for c = 0 to cycles - 1 do
                  Count_down_latch.await latches.(c);
                  Atomic.incr awoke
                done)))
          in
          for c = 0 to cycles - 1 do
            (* Tiny wait so awaiters reach the suspend point inside Eio
               before we count down.  Without it the latch would already
               be open and the await would short-circuit, masking the
               park/wake latency we are trying to measure. *)
            Unix.sleepf 0.0005;
            Count_down_latch.count_down latches.(c);
            (* Wait for all t-1 awaiters to acknowledge cycle [c] before
               proceeding so cycles stay serialized. *)
            let target = (c + 1) * (t - 1) in
            while Atomic.get awoke < target do Domain.cpu_relax () done
          done;
          Array.iter Domain.join awaiters;
          let ended = Bench.now_ns () in
          let elapsed_ns = Int64.to_float (Int64.sub ended started_at) in
          let duration_s = elapsed_ns /. 1e9 in
          let res = Bench.{
            primitive = "CountDownLatch(1)";
            workload  = "W5_latch_fire";
            threads   = t;
            ops       = cycles;
            duration_s;
            throughput = float cycles /. duration_s;
            mean_ns    = elapsed_ns /. float cycles;
            repeat     = r;
          } in
          Bench.pp_stdout res;
          Bench.append_to ~path:!out (Bench.csv_row res)
        done
    ) selected_threads
  end;

  (* --------------------------------------------------------------- *)
  (* Barrier — rendezvous latency                                      *)
  (* --------------------------------------------------------------- *)
  if wanted "Barrier" then begin
    List.iter (fun t ->
      if t >= 2 then
        for r = 0 to !repeats - 1 do
          let cycles = 200 in
          (* Pre-allocate one barrier per cycle and spawn t worker
             domains exactly once per repeat.  Each worker walks every
             barrier in order and arrives on it; barriers naturally
             serialize the cycles since arrive(b[c+1]) cannot complete
             until every party has cleared b[c].  Same motivation as
             the latch restructure: avoid Domain + Eio_main.run churn
             that OOM-kills the process at high t. *)
          let barriers = Array.init cycles (fun _ -> Barrier.make t) in
          let started_at = Bench.now_ns () in
          let doms = Array.init t (fun _ ->
            Domain.spawn (fun () ->
              Eio_main.run (fun _env ->
                for c = 0 to cycles - 1 do
                  ignore (Barrier.arrive barriers.(c))
                done)))
          in
          Array.iter Domain.join doms;
          let ended = Bench.now_ns () in
          let elapsed_ns = Int64.to_float (Int64.sub ended started_at) in
          let duration_s = elapsed_ns /. 1e9 in
          let res = Bench.{
            primitive = "Barrier";
            workload  = "W6_barrier";
            threads   = t;
            ops       = cycles;
            duration_s;
            throughput = float cycles /. duration_s;
            mean_ns    = elapsed_ns /. float cycles;
            repeat     = r;
          } in
          Bench.pp_stdout res;
          Bench.append_to ~path:!out (Bench.csv_row res)
        done
    ) selected_threads
  end
