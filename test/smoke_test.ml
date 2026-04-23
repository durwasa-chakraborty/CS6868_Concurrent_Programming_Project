let () =
  (* 1. Basic ASYNC: resume before suspend — elimination *)
  let sqs: int Sqs_effects.t = Sqs_effects.make ~resume_mode:Sqs_effects.Async () in
  let got = ref 0 in
  let _ok = Sqs_effects.resume sqs 42 in
  let _   = Sqs_effects.suspend sqs in
  Printf.printf "elimination (resume-before-suspend): %d (expected 42)\n" !got;

  (* 2. suspend before resume *)
  let sqs2 = Sqs_effects.make ~resume_mode:Sqs_effects.Async () in
  let got2 = ref 0 in
  let _    = Sqs_effects.suspend sqs2 in
  let _    = Sqs_effects.resume  sqs2 99 in
  Printf.printf "normal   (suspend-before-resume):    %d (expected 99)\n" !got2;

  (* 3. Multiple sequential waiters *)
  let sqs3 = Sqs_effects.make ~resume_mode:Sqs_effects.Async () in
  let results = Array.make 3 0 in
  for i = 0 to 2 do
    ignore (Sqs_effects.suspend sqs3)
  done;
  for v = 10 to 12 do
    ignore (Sqs_effects.resume sqs3 v)
  done;
  Printf.printf "multiple waiters: [%d; %d; %d] (expected [10; 11; 12])\n"
    results.(0) results.(1) results.(2)
