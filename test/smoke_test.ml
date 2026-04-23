let () =
  Sqs_effects.run (fun () ->
    (* 1. ASYNC elimination: resume deposits before suspend arrives. *)
    let sqs = Sqs_effects.make ~resume_mode:Sqs_effects.Async () in
    let _ok = Sqs_effects.resume sqs 42 in
    let got = Sqs_effects.suspend sqs in
    Printf.printf "elimination (resume-before-suspend): %d (expected 42)\n" got;

    (* 2. Normal path: a second fibre delivers the value to the parked one. *)
    let sqs2 = Sqs_effects.make ~resume_mode:Sqs_effects.Async () in
    let got2 = ref 0 in
    Eio.Fiber.both
      (fun () -> got2 := Sqs_effects.suspend sqs2)
      (fun () -> ignore (Sqs_effects.resume sqs2 99));
    Printf.printf "normal   (suspend-before-resume):    %d (expected 99)\n" !got2;

    (* 3. Three parked waiters, resumed in FIFO order by a fourth fibre. *)
    let sqs3 = Sqs_effects.make ~resume_mode:Sqs_effects.Async () in
    let results = Array.make 3 0 in
    Eio.Fiber.all [
      (fun () -> results.(0) <- Sqs_effects.suspend sqs3);
      (fun () -> results.(1) <- Sqs_effects.suspend sqs3);
      (fun () -> results.(2) <- Sqs_effects.suspend sqs3);
      (fun () ->
         for v = 10 to 12 do ignore (Sqs_effects.resume sqs3 v) done);
    ];
    Printf.printf "multiple waiters: [%d; %d; %d] (expected [10; 11; 12])\n"
      results.(0) results.(1) results.(2))
