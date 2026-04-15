(* Debug: find what specific scenario hangs. *)

let log msg = Printf.printf "[%f] %s\n%!" (Unix.gettimeofday ()) msg

(* Scenario: Semaphore(1), two domains each doing [Acq; Acq; Rel; Rel]. *)
let test_balanced_2x4 () =
  log "=== balanced 2 domains x 4 ops (2acq/2rel each) ===";
  let sem = Semaphore.make 1 in
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

let () = test_balanced_2x4 ()
