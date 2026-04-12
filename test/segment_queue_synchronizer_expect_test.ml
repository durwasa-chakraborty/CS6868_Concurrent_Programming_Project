open Segment_queue_synchronizer

(* Reusable no-op callback for states that need a waiter payload. *)
let noop _ = ()

(* Render internal cell states with the same printer used by the library. *)
let string_of_state state =
  Format.asprintf "%a" pp_cell_state state

(* Keep option output stable and compact inside expect blocks. *)
let string_of_int_option = function
  | None -> "None"
  | Some value -> Printf.sprintf "Some %d" value

(* Pretty-print the internal resume result enum for assertions. *)
let string_of_try_resume_result = function
  | TryResumeSuccess -> "success"
  | TryResumeCancelled -> "cancelled"
  | TryResumeBroken -> "broken"

(* Bound busy-wait loops used by the few domain-based coordination tests. *)
let wait_until ?(limit = 1_000_000) predicate =
  let spins = ref 0 in
  while !spins < limit && not (predicate ()) do
    incr spins;
    Domain.cpu_relax ()
  done;
  predicate ()

(* Print a labelled cell snapshot so expect output stays readable. *)
let print_cell label seg index =
  Printf.printf "%s=%s\n" label (string_of_state (seg_get seg index))

(* Exercise the raw segment helpers, pretty-printer states, and segment unlinking. *)
let%expect_test "segment primitives and traversal" =
  let sample_states =
    [ Empty
    ; Waiter noop
    ; Cancelling noop
    ; Cancelled
    ; Refuse
    ; Resumed
    ; Taken
    ; Broken
    ; Value 1
    ; WrappedValue 2
    ]
  in
  List.iter (fun state -> print_endline (string_of_state state)) sample_states;

  let seg = make_segment 3 None 7 in
  Printf.printf "segment=id:%d pointers:%d\n" seg.id (Atomic.get seg.pointers);
  print_cell "initial" seg 0;
  seg_set seg 0 (Value 10);
  print_cell "after_set" seg 0;
  let old = seg_get_and_set seg 0 (WrappedValue 11) in
  Printf.printf "exchange_old=%s\n" (string_of_state old);
  let current = seg_get seg 0 in
  Printf.printf "cas=%b\n" (seg_cas seg 0 current Broken);
  print_cell "after_cas" seg 0;

  let root = make_segment 0 None 0 in
  for _ = 1 to segment_size do
    on_slot_cleaned root
  done;
  Printf.printf "root_cancelled_count=%d next_is_none=%b\n"
    (Atomic.get root.cancelled_count)
    (Option.is_none (Atomic.get root.next));

  let prev = make_segment 0 None 0 in
  let middle = make_segment 1 (Some prev) 0 in
  let next = make_segment 2 (Some middle) 0 in
  Atomic.set prev.next (Some middle);
  Atomic.set middle.next (Some next);
  for _ = 1 to segment_size do
    on_slot_cleaned middle
  done;
  Printf.printf "unlinked_to=%d\n"
    (match Atomic.get prev.next with
     | Some seg' -> seg'.id
     | None -> -1);

  let seg_ref = Atomic.make prev in
  let found =
    find_segment_and_move_forward seg_ref 2 prev (fun id prev_opt ->
      make_segment id prev_opt 0)
  in
  Printf.printf "found=%d ref=%d\n" found.id (Atomic.get seg_ref).id;

  let ahead_ref = Atomic.make next in
  let ahead =
    find_segment_and_move_forward ahead_ref 1 next (fun id prev_opt ->
      make_segment id prev_opt 0)
  in
  Printf.printf "ahead=%d ref=%d\n" ahead.id (Atomic.get ahead_ref).id;
  [%expect {|
    Empty
    <cont>
    CANCELLING
    CANCELLED
    REFUSE
    RESUMED
    TAKEN
    BROKEN
    <value>
    <wrapped-value>
    segment=id:3 pointers:7
    initial=Empty
    after_set=<value>
    exchange_old=<value>
    cas=true
    after_cas=BROKEN
    root_cancelled_count=16 next_is_none=true
    unlinked_to=2
    found=2 ref=2
    ahead=2 ref=2 |}]

(* Cover helper functions that are easier to validate directly than via the queue API. *)
let%expect_test "helpers and marker transitions" =
  let returned = ref [] in
  let sqs =
    make
      ~try_return_refused_value:(fun value -> value mod 2 = 0)
      ~return_value:(fun value -> returned := value :: !returned)
      ()
  in
  return_refused_value sqs 2;
  return_refused_value sqs 3;
  Printf.printf "returned=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !returned)));

  adjust_resume_idx_to sqs 5;
  adjust_resume_idx_to sqs 4;
  Printf.printf "resume_idx=%d\n" (Atomic.get sqs.resume_idx);

  let helper_seg = make_seg_for sqs 9 None in
  Printf.printf "helper_seg=%d prev_none=%b\n"
    helper_seg.id
    (Option.is_none (Atomic.get helper_seg.prev));

  let seg_waiter = make_segment 0 None 0 in
  seg_set seg_waiter 0 (Waiter noop);
  Printf.printf "mark_waiter=%b " (try_mark_cancelling seg_waiter 0);
  print_cell "state" seg_waiter 0;

  let seg_resumed = make_segment 0 None 0 in
  seg_set seg_resumed 0 Resumed;
  Printf.printf "mark_resumed=%b\n" (try_mark_cancelling seg_resumed 0);

  let seg_cancelling = make_segment 0 None 0 in
  seg_set seg_cancelling 0 (Cancelling noop);
  Printf.printf "mark_cancelling=%b\n" (try_mark_cancelling seg_cancelling 0);

  let seg_empty = make_segment 0 None 0 in
  Printf.printf "mark_empty=%b\n" (try_mark_cancelling seg_empty 0);

  let seg_value = make_segment 0 None 0 in
  seg_set seg_value 0 (Value 11);
  Printf.printf "mark_impl_value=%s " (string_of_int_option (mark_impl seg_value 0 Refuse));
  print_cell "state" seg_value 0;

  let seg_wrapped = make_segment 0 None 0 in
  seg_set seg_wrapped 0 (WrappedValue 12);
  Printf.printf "mark_impl_wrapped=%s " (string_of_int_option (mark_impl seg_wrapped 0 Cancelled));
  print_cell "state" seg_wrapped 0;

  let seg_other = make_segment 0 None 0 in
  Printf.printf "mark_impl_other=%s " (string_of_int_option (mark_impl seg_other 0 Refuse));
  print_cell "state" seg_other 0;

  let seg_cancelled = make_segment 0 None 0 in
  seg_set seg_cancelled 0 (Cancelling noop);
  Printf.printf "mark_cancelled=%s " (string_of_int_option (mark_cancelled sqs seg_cancelled 0));
  print_cell "state" seg_cancelled 0;
  Printf.printf "cancelled_count=%d\n" (Atomic.get seg_cancelled.cancelled_count);

  let seg_refuse = make_segment 0 None 0 in
  seg_set seg_refuse 0 (Cancelling noop);
  Printf.printf "mark_refuse=%s " (string_of_int_option (mark_refuse seg_refuse 0));
  print_cell "state" seg_refuse 0;
  [%expect {|
    returned=3
    resume_idx=5
    helper_seg=9 prev_none=true
    mark_waiter=true state=CANCELLING
    mark_resumed=false
    mark_cancelling=true
    mark_empty=false
    mark_impl_value=Some 11 state=REFUSE
    mark_impl_wrapped=Some 12 state=CANCELLED
    mark_impl_other=None state=REFUSE
    mark_cancelled=None state=CANCELLED
    cancelled_count=1
    mark_refuse=None state=REFUSE |}]

(* Drive the simple and smart cancellation branches, including forwarded values. *)
let%expect_test "cancellation flows" =
  let simple_sqs = make ~cancellation_mode:Simple () in
  let simple_seg = make_segment 0 None 0 in
  seg_set simple_seg 0 (Waiter noop);
  handle_cancellation simple_sqs simple_seg 0;
  print_cell "simple" simple_seg 0;
  Printf.printf "simple_count=%d\n" (Atomic.get simple_seg.cancelled_count);

  let untouched = make_segment 0 None 0 in
  seg_set untouched 0 Resumed;
  cancel_waiter simple_sqs untouched 0;
  print_cell "cancel_waiter_resumed" untouched 0;

  let refuse_returns = ref [] in
  let refuse_seg = make_segment 0 None 0 in
  let refuse_sqs =
    make
      ~resume_mode:Async
      ~cancellation_mode:Smart
      ~on_cancellation:(fun () ->
        seg_set refuse_seg 0 (Value 21);
        false)
      ~try_return_refused_value:(fun _ -> false)
      ~return_value:(fun value -> refuse_returns := value :: !refuse_returns)
      ()
  in
  seg_set refuse_seg 0 (Waiter noop);
  handle_cancellation refuse_sqs refuse_seg 0;
  print_cell "smart_refuse" refuse_seg 0;
  Printf.printf "smart_refuse_returns=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !refuse_returns)));

  let forwarded = ref [] in
  let forward_sqs =
    make
      ~resume_mode:Async
      ~cancellation_mode:Smart
      ()
  in
  let forward_seg = Atomic.get forward_sqs.resume_segment in
  Atomic.set forward_sqs.suspend_idx 1;
  ignore (suspend forward_sqs (fun value -> forwarded := value :: !forwarded));
  let forward_cancel_sqs =
    { forward_sqs with
      on_cancellation =
        (fun () ->
           seg_set forward_seg 0 (Value 30);
           true)
    }
  in
  seg_set forward_seg 0 (Waiter noop);
  handle_cancellation forward_cancel_sqs forward_seg 0;
  print_cell "smart_cancelled" forward_seg 0;
  Printf.printf "forwarded=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !forwarded)));

  let returned_after_failed_resume = ref [] in
  let failed_seg = make_segment 0 None 0 in
  let failed_sqs =
    make
      ~resume_mode:Sync
      ~cancellation_mode:Smart
      ~on_cancellation:(fun () ->
        seg_set failed_seg 0 (Value 44);
        true)
      ~return_value:(fun value ->
        returned_after_failed_resume := value :: !returned_after_failed_resume)
      ()
  in
  seg_set failed_seg 0 (Waiter noop);
  handle_cancellation failed_sqs failed_seg 0;
  print_cell "failed_forward" failed_seg 0;
  Printf.printf "failed_forward_returns=%s\n"
    (String.concat ","
       (List.rev_map string_of_int (List.rev !returned_after_failed_resume)));
  [%expect {|
    simple=CANCELLED
    simple_count=1
    cancel_waiter_resumed=RESUMED
    smart_refuse=REFUSE
    smart_refuse_returns=21
    smart_cancelled=CANCELLED
    forwarded=30
    failed_forward=CANCELLED
    failed_forward_returns=44
    |}]

(* Cover the public suspend/resume surface across success, refusal, and broken states. *)
let%expect_test "suspend, suspend_cancelled, and resume" =
  let async_sqs = make ~resume_mode:Async () in
  let async_seg = Atomic.get async_sqs.resume_segment in
  let async_received = ref [] in
  Printf.printf "resume_before_suspend=%b\n" (resume async_sqs 42);
  Printf.printf "suspend_after_resume=%b\n"
    (suspend async_sqs (fun value -> async_received := value :: !async_received));
  print_cell "async_cell" async_seg 0;
  Printf.printf "async_received=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !async_received)));

  let broken_sqs = make ~resume_mode:Async () in
  let broken_seg = Atomic.get broken_sqs.suspend_segment in
  seg_set broken_seg 0 Broken;
  Printf.printf "suspend_broken=%b\n" (suspend broken_sqs noop);

  let wrapped_sqs = make ~resume_mode:Async () in
  let wrapped_seg = Atomic.get wrapped_sqs.suspend_segment in
  let wrapped_received = ref [] in
  seg_set wrapped_seg 0 (WrappedValue 9);
  Printf.printf "suspend_wrapped=%b\n"
    (suspend wrapped_sqs (fun value -> wrapped_received := value :: !wrapped_received));
  print_cell "wrapped_cell" wrapped_seg 0;
  Printf.printf "wrapped_received=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !wrapped_received)));

  let poll_sqs = make ~resume_mode:Async () in
  Printf.printf "suspend_cancelled_empty=%s\n"
    (string_of_int_option (suspend_cancelled poll_sqs));

  let poll_broken_sqs = make ~resume_mode:Async () in
  let poll_broken_seg = Atomic.get poll_broken_sqs.suspend_segment in
  seg_set poll_broken_seg 0 Broken;
  Printf.printf "suspend_cancelled_broken=%s\n"
    (string_of_int_option (suspend_cancelled poll_broken_sqs));

  let poll_value_sqs = make ~resume_mode:Async () in
  let poll_value_seg = Atomic.get poll_value_sqs.suspend_segment in
  seg_set poll_value_seg 0 (Value 77);
  Printf.printf "suspend_cancelled_value=%s\n"
    (string_of_int_option (suspend_cancelled poll_value_sqs));
  print_cell "poll_value_cell" poll_value_seg 0;

  let poll_wrapped_sqs = make ~resume_mode:Async () in
  let poll_wrapped_seg = Atomic.get poll_wrapped_sqs.suspend_segment in
  seg_set poll_wrapped_seg 0 (WrappedValue 78);
  Printf.printf "suspend_cancelled_wrapped=%s\n"
    (string_of_int_option (suspend_cancelled poll_wrapped_sqs));
  print_cell "poll_wrapped_cell" poll_wrapped_seg 0;

  let direct_resume_sqs = make ~resume_mode:Async ~cancellation_mode:Simple () in
  let direct_received = ref [] in
  ignore (suspend direct_resume_sqs (fun value -> direct_received := value :: !direct_received));
  Printf.printf "resume_waiter=%b\n" (resume direct_resume_sqs 7);
  Printf.printf "resume_waiter_received=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !direct_received)));

  let smart_resume_sqs = make ~resume_mode:Async ~cancellation_mode:Smart () in
  let smart_seg = Atomic.get smart_resume_sqs.resume_segment in
  let smart_received = ref [] in
  seg_set smart_seg 0 Cancelled;
  Atomic.set smart_resume_sqs.suspend_idx 1;
  ignore (suspend smart_resume_sqs (fun value -> smart_received := value :: !smart_received));
  Printf.printf "resume_skip_cancelled=%b\n" (resume smart_resume_sqs 8);
  Printf.printf "resume_skip_cancelled_received=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !smart_received)));

  let refuse_returns = ref [] in
  let refuse_resume_sqs =
    make
      ~resume_mode:Async
      ~try_return_refused_value:(fun _ -> false)
      ~return_value:(fun value -> refuse_returns := value :: !refuse_returns)
      ()
  in
  let refuse_resume_seg = Atomic.get refuse_resume_sqs.resume_segment in
  seg_set refuse_resume_seg 0 Refuse;
  Printf.printf "resume_refuse=%b\n" (resume refuse_resume_sqs 12);
  Printf.printf "resume_refuse_returns=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !refuse_returns)));

  let broken_resume_sqs = make ~resume_mode:Async () in
  let broken_resume_seg = Atomic.get broken_resume_sqs.resume_segment in
  seg_set broken_resume_seg 0 Broken;
  Printf.printf "resume_broken=%b\n" (resume broken_resume_sqs 99);
  [%expect {|
    resume_before_suspend=true
    suspend_after_resume=true
    async_cell=TAKEN
    async_received=42
    suspend_broken=false
    suspend_wrapped=true
    wrapped_cell=TAKEN
    wrapped_received=9
    suspend_cancelled_empty=None
    suspend_cancelled_broken=None
    suspend_cancelled_value=Some 77
    poll_value_cell=TAKEN
    suspend_cancelled_wrapped=Some 78
    poll_wrapped_cell=TAKEN
    resume_waiter=true
    resume_waiter_received=7
    resume_skip_cancelled=true
    resume_skip_cancelled_received=8
    resume_refuse=true
    resume_refuse_returns=12
    resume_broken=false |}]

(* Hit the deeper try_resume_impl state machine, dump output, and the sample mutex wrapper. *)
let%expect_test "try_resume_impl, dump, and mutex" =
  let moved_sqs = make ~resume_mode:Async () in
  let moved_seg = make_segment 1 None 0 in
  Atomic.set moved_sqs.resume_segment moved_seg;
  let moved = try_resume_impl moved_sqs 5 true in
  Printf.printf "moved=%s idx=%d prev_none=%b\n"
    (string_of_try_resume_result moved)
    (Atomic.get moved_sqs.resume_idx)
    (Option.is_none (Atomic.get moved_seg.prev));

  let empty_async_sqs = make ~resume_mode:Async () in
  let empty_async_seg = Atomic.get empty_async_sqs.resume_segment in
  let empty_async = try_resume_impl empty_async_sqs 6 false in
  Printf.printf "empty_async=%s " (string_of_try_resume_result empty_async);
  print_cell "state" empty_async_seg 0;

  let empty_sync_sqs = make ~resume_mode:Sync () in
  let empty_sync_seg = Atomic.get empty_sync_sqs.resume_segment in
  let empty_sync = try_resume_impl empty_sync_sqs 7 false in
  Printf.printf "empty_sync=%s " (string_of_try_resume_result empty_sync);
  print_cell "state" empty_sync_seg 0;

  let cancelled_sqs = make ~resume_mode:Async () in
  let cancelled_seg = Atomic.get cancelled_sqs.resume_segment in
  seg_set cancelled_seg 0 Cancelled;
  Printf.printf "cancelled=%s\n"
    (string_of_try_resume_result (try_resume_impl cancelled_sqs 1 false));

  let waiter_sqs = make ~resume_mode:Async () in
  let waiter_seg = Atomic.get waiter_sqs.resume_segment in
  let waiter_received = ref [] in
  seg_set waiter_seg 0 (Waiter (fun value -> waiter_received := value :: !waiter_received));
  let waiter_result = try_resume_impl waiter_sqs 13 false in
  Printf.printf "waiter=%s " (string_of_try_resume_result waiter_result);
  print_cell "state" waiter_seg 0;
  Printf.printf "waiter_received=%s\n"
    (String.concat "," (List.rev_map string_of_int (List.rev !waiter_received)));

  let simple_cancelling_sqs =
    make ~resume_mode:Async ~cancellation_mode:Simple ()
  in
  let simple_cancelling_seg = Atomic.get simple_cancelling_sqs.resume_segment in
  seg_set simple_cancelling_seg 0 (Cancelling noop);
  Printf.printf "cancelling_simple=%s\n"
    (string_of_try_resume_result (try_resume_impl simple_cancelling_sqs 14 false));

  let async_cancelling_sqs =
    make ~resume_mode:Async ~cancellation_mode:Smart ()
  in
  let async_cancelling_seg = Atomic.get async_cancelling_sqs.resume_segment in
  seg_set async_cancelling_seg 0 (Cancelling noop);
  let async_cancelling = try_resume_impl async_cancelling_sqs 15 false in
  Printf.printf "cancelling_async=%s " (string_of_try_resume_result async_cancelling);
  print_cell "state" async_cancelling_seg 0;

  let sync_returns = ref [] in
  let sync_cancelling_sqs =
    make
      ~resume_mode:Sync
      ~cancellation_mode:Smart
      ~try_return_refused_value:(fun _ -> false)
      ~return_value:(fun value -> sync_returns := value :: !sync_returns)
      ()
  in
  let sync_cancelling_seg = Atomic.get sync_cancelling_sqs.resume_segment in
  seg_set sync_cancelling_seg 0 (Cancelling noop);
  let sync_job =
    Domain.spawn (fun () -> try_resume_impl sync_cancelling_sqs 16 false)
  in
  ignore (wait_until (fun () -> Atomic.get sync_cancelling_sqs.resume_idx = 1));
  seg_set sync_cancelling_seg 0 Refuse;
  let sync_cancelling = Domain.join sync_job in
  Printf.printf "cancelling_sync=%s returns=%s\n"
    (string_of_try_resume_result sync_cancelling)
    (String.concat "," (List.rev_map string_of_int (List.rev !sync_returns)));

  let resumed_sqs = make ~resume_mode:Async () in
  let resumed_seg = Atomic.get resumed_sqs.resume_segment in
  seg_set resumed_seg 0 Resumed;
  Printf.printf "unexpected_resumed=%s\n"
    (string_of_try_resume_result (try_resume_impl resumed_sqs 17 false));

  let taken_sqs = make ~resume_mode:Async () in
  let taken_seg = Atomic.get taken_sqs.resume_segment in
  seg_set taken_seg 0 Taken;
  Printf.printf "unexpected_taken=%s\n"
    (string_of_try_resume_result (try_resume_impl taken_sqs 18 false));

  let value_sqs = make ~resume_mode:Async () in
  let value_seg = Atomic.get value_sqs.resume_segment in
  seg_set value_seg 0 (Value 19);
  Printf.printf "unexpected_value=%s\n"
    (string_of_try_resume_result (try_resume_impl value_sqs 19 false));

  let wrapped_value_sqs = make ~resume_mode:Async () in
  let wrapped_value_seg = Atomic.get wrapped_value_sqs.resume_segment in
  seg_set wrapped_value_seg 0 (WrappedValue 20);
  Printf.printf "unexpected_wrapped=%s\n"
    (string_of_try_resume_result (try_resume_impl wrapped_value_sqs 20 false));

  let dump_sqs = make ~resume_mode:Async () in
  let dump_seg0 = Atomic.get dump_sqs.resume_segment in
  let dump_seg1 = make_segment 1 None 0 in
  Atomic.set dump_seg0.next (Some dump_seg1);
  seg_set dump_seg0 15 Cancelled;
  seg_set dump_seg1 0 Refuse;
  Atomic.set dump_sqs.resume_idx 15;
  Atomic.set dump_sqs.suspend_idx 17;
  dump dump_sqs;

  let removed_dump_sqs = make ~resume_mode:Async () in
  let removed_seg = make_segment 1 None 0 in
  Atomic.set removed_dump_sqs.resume_segment removed_seg;
  Atomic.set removed_dump_sqs.resume_idx 0;
  Atomic.set removed_dump_sqs.suspend_idx 2;
  dump removed_dump_sqs;

  let mutex = Mutex.make () in
  let mutex_log = ref [] in
  Mutex.lock mutex (fun () -> mutex_log := !mutex_log @ [ "first" ]);
  Mutex.lock mutex (fun () -> mutex_log := !mutex_log @ [ "second" ]);
  Mutex.unlock mutex;
  Mutex.unlock mutex;
  Printf.printf "mutex=%s locked=%b\n"
    (String.concat "," !mutex_log)
    (Atomic.get mutex.locked);
  [%expect {|
    moved=cancelled idx=16 prev_none=true
    empty_async=success state=<value>
    empty_sync=broken state=BROKEN
    cancelled=cancelled
    waiter=success state=RESUMED
    waiter_received=13
    cancelling_simple=cancelled
    cancelling_async=success state=<value>
    cancelling_sync=success returns=16
    unexpected_resumed=broken
    unexpected_taken=broken
    unexpected_value=broken
    unexpected_wrapped=broken
    suspendIdx=17 resumeIdx=15
      [15] CANCELLED
      [16] REFUSE
    suspendIdx=2 resumeIdx=0
      [0] CANCELLED
      [1] CANCELLED
    mutex=first,second locked=true
    |}]
