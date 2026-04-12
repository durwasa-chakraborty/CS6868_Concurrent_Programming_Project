let () =
  (* 1. Basic ASYNC: resume before suspend — elimination *)
  let sqs = Segment_queue_synchronizer.make ~resume_mode:Segment_queue_synchronizer.Async () in
  let got = ref 0 in
  let _ok = Segment_queue_synchronizer.resume sqs 42 in
  let _   = Segment_queue_synchronizer.suspend sqs (fun v -> got := v) in
  Printf.printf "elimination (resume-before-suspend): %d (expected 42)\n" !got;

  (* 2. suspend before resume *)
  let sqs2 = Segment_queue_synchronizer.make ~resume_mode:Segment_queue_synchronizer.Async () in
  let got2 = ref 0 in
  let _    = Segment_queue_synchronizer.suspend sqs2 (fun v -> got2 := v) in
  let _    = Segment_queue_synchronizer.resume  sqs2 99 in
  Printf.printf "normal   (suspend-before-resume):    %d (expected 99)\n" !got2;

  (* 3. Multiple sequential waiters *)
  let sqs3 = Segment_queue_synchronizer.make ~resume_mode:Segment_queue_synchronizer.Async () in
  let results = Array.make 3 0 in
  for i = 0 to 2 do
    ignore (Segment_queue_synchronizer.suspend sqs3 (fun v -> results.(i) <- v))
  done;
  for v = 10 to 12 do
    ignore (Segment_queue_synchronizer.resume sqs3 v)
  done;
  Printf.printf "multiple waiters: [%d; %d; %d] (expected [10; 11; 12])\n"
    results.(0) results.(1) results.(2)