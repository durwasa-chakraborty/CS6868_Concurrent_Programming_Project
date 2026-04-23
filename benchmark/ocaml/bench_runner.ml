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
  (* Blocking queue pool — producer/consumer                          *)
  (* --------------------------------------------------------------- *)
  if wanted "BlockingQueuePool" then begin
    List.iter (fun t ->
      if t >= 2 then begin
        let pool = Blocking_queue_pool.make () in
        run_bench ~primitive:"BlockingQueuePool" ~workload:"W3_pc_queue"
          ~threads:t ~body:(fun idx ->
            if idx mod 2 = 0 then
              Blocking_queue_pool.put pool 1
            else
              ignore (Blocking_queue_pool.retrieve pool))
      end
    ) selected_threads
  end;

  (* --------------------------------------------------------------- *)
  (* Blocking stack pool — producer/consumer                          *)
  (* --------------------------------------------------------------- *)
  if wanted "BlockingStackPool" then begin
    List.iter (fun t ->
      if t >= 2 then begin
        let pool = Blocking_stack_pool.make () in
        run_bench ~primitive:"BlockingStackPool" ~workload:"W4_pc_stack"
          ~threads:t ~body:(fun idx ->
            if idx mod 2 = 0 then
              Blocking_stack_pool.put pool 1
            else
              ignore (Blocking_stack_pool.retrieve pool))
      end
    ) selected_threads
  end;

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
          let started_at = Bench.now_ns () in
          for _ = 1 to cycles do
            let l = Count_down_latch.make 1 in
            let awoke = Atomic.make 0 in
            let awaiters = Array.init (t - 1) (fun _ ->
              Domain.spawn (fun () ->
                Eio_main.run (fun _env ->
                  Count_down_latch.await l;
                  Atomic.incr awoke)))
            in
            (* Tiny wait so awaiters park inside Eio. *)
            Unix.sleepf 0.0005;
            Count_down_latch.count_down l;
            Array.iter Domain.join awaiters
          done;
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
          let started_at = Bench.now_ns () in
          for _ = 1 to cycles do
            let b = Barrier.make t in
            let doms = Array.init t (fun _ ->
              Domain.spawn (fun () ->
                Eio_main.run (fun _env ->
                  ignore (Barrier.arrive b))))
            in
            Array.iter Domain.join doms
          done;
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
