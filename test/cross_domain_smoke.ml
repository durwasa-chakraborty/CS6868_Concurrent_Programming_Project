(* Cross-domain smoke test for [Semaphore] built on [Sqs_effects].

   Two Eio schedulers on separate domains contend for a single-permit
   semaphore, exercising the domain-safe [Light_thread.resume] path: a
   release on one domain must be able to wake an acquirer parked on the
   other.  The previous [Acq; Acq; Rel; Rel] sequence deadlocked a
   domain on its own second [Acq] before its [Rel]s could run, so the
   scheduler never reached the cross-domain case. *)

let log_mutex = Stdlib.Mutex.create ()
let log msg =
  Stdlib.Mutex.lock log_mutex;
  Printf.printf "[%f] %s\n%!" (Unix.gettimeofday ()) msg;
  Stdlib.Mutex.unlock log_mutex

let test_balanced_2x4 () =
  log "=== balanced 2 domains x 4 ops (Acq/Rel interleaved) ===";
  let sem = Semaphore.make 1 in
  let ready = Atomic.make 0 in
  let ops = [| "Acq"; "Rel"; "Acq"; "Rel" |] in
  let run_one d op_name =
    match op_name with
    | "Acq" ->
      log (Printf.sprintf "D%d: acquire enter" d);
      Semaphore.acquire sem;
      log (Printf.sprintf "D%d: acquire exit" d)
    | "Rel" ->
      log (Printf.sprintf "D%d: release enter" d);
      Semaphore.release sem;
      log (Printf.sprintf "D%d: release exit" d)
    | _ -> assert false
  in
  let domains = Array.init 2 (fun d ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        Atomic.incr ready;
        while Atomic.get ready < 2 do Domain.cpu_relax () done;
        Array.iter (run_one d) ops
      )
    )
  ) in
  Array.iter Domain.join domains;
  log "All joined"

let test_balanced_2x4_2 () =
  log "=== balanced 2 domains x 4 ops (Acq/Rel interleaved) ===";
  let sem = Semaphore.make 2 in
  let ready = Atomic.make 0 in
  let ops = [| "Acq"; "Acq"; "Rel"; "Rel" |] in
  let run_one d op_name =
    match op_name with
    | "Acq" ->
      log (Printf.sprintf "D%d: acquire enter" d);
      Semaphore.acquire sem;
      log (Printf.sprintf "D%d: acquire exit" d)
    | "Rel" ->
      log (Printf.sprintf "D%d: release enter" d);
      Semaphore.release sem;
      log (Printf.sprintf "D%d: release exit" d)
    | _ -> assert false
  in
  let domains = Array.init 2 (fun d ->
    Domain.spawn (fun () ->
      Eio_main.run (fun _env ->
        Atomic.incr ready;
        while Atomic.get ready < 2 do Domain.cpu_relax () done;
        Array.iter (run_one d) ops
      )
    )
  ) in
  Array.iter Domain.join domains;
  log "All joined"

let () = test_balanced_2x4_2 () ;
test_balanced_2x4 ()
