(** A blocking resource pool backed by a LIFO Treiber stack.

    Semantics identical to {!Blocking_queue_pool} but retrieval order is
    LIFO ("hottest" element first), which improves cache locality for
    resources such as connections or buffers.

    Algorithm: §7 of the CQS paper (Listings 16–17, stack variant).

    The stack stores elements as a linked list of nodes.  A node with
    [element = None] is a *failure marker* inserted by [try_retrieve] when
    the stack is empty, signalling to a concurrent [try_insert] that the
    element must be delivered via [resume] rather than stored.

    Cancellation mode: SMART.
    - [on_cancellation]          — increments [available]; returns [s < 0]
                                   (true → no [put] is coming, safe CANCEL;
                                    false → a [put] is in flight, REFUSE it).
    - [try_return_refused_value] — tries to push the refused element back
                                   onto the stack.
    - [return_value]             — calls [put] as a fallback if the push
                                   fails. *)

open Sqs_effects

(** A node in the Treiber stack.  [element = None] marks a failure node
    inserted by a [retrieve] that found the stack empty. *)
type 'a node = {
  element : 'a option;
  next    : 'a node option;
}

type 'a t = {
  sqs       : 'a sqs;
  available : int Atomic.t;
  head      : 'a node option Atomic.t;
}

(** Try to push [element] onto the stack.
    Returns [false] if a failure node is at the top (a [retrieve] arrived
    first and is waiting for a direct [resume] delivery); consuming the
    failure node and signalling to the caller to use [resume] instead. *)
let rec try_insert t element =
  let h = Atomic.get t.head in
  match h with
  | Some { element = None; next } ->
    (* Failure node at the top: consume it and signal retry-via-resume. *)
    if Atomic.compare_and_set t.head h next then false
    else try_insert t element
  | _ ->
    (* Stack is empty or has elements: push normally. *)
    let new_head = Some { element = Some element; next = h } in
    if Atomic.compare_and_set t.head h new_head then true
    else try_insert t element

(** Try to pop the top element.
    If the stack is empty (or topped by failure nodes), pushes another
    failure node and returns [None] — the paired [put] will detect this
    and deliver via [resume]. *)
let try_retrieve t =
  let rec loop () =
    let h = Atomic.get t.head in
    match h with
    | None | Some { element = None; _ } ->
      let fail = Some { element = None; next = h } in
      if Atomic.compare_and_set t.head h fail then None
      else loop ()
    | Some node ->
      if Atomic.compare_and_set t.head h node.next then node.element
      else loop ()
  in
  loop ()

(** Deposit [element] into the pool.
    If a [retrieve] is waiting (s < 0), resume it directly.  In SMART
    mode [resume] never returns [false] when there is a real waiter.
    May be called from any context. *)
let rec put t element =
  let s = Atomic.fetch_and_add t.available 1 in
  if s < 0 then
    ignore (resume t.sqs element)
  else if not (try_insert t element) then
    put t element

let make () =
  let t_ref = ref None in
  let get_t () = match !t_ref with Some t -> t | None -> assert false in
  let sqs =
    make
      ~resume_mode:Async
      ~cancellation_mode:Smart
      ~on_cancellation:(fun () ->
        let s = Atomic.fetch_and_add (get_t ()).available 1 in
        s < 0)
      ~try_return_refused_value:(fun v -> try_insert (get_t ()) v)
      ~return_value:(fun v -> put (get_t ()) v)
      ()
  in
  let t = { sqs; available = Atomic.make 0; head = Atomic.make None } in
  t_ref := Some t;
  t

(** Take one element from the pool (most recently inserted first),
    suspending if it is empty.
    Must be called from within a {!run} handler. *)
let retrieve t =
  let rec loop () =
    let s = Atomic.fetch_and_add t.available (-1) in
    if s > 0 then begin
      match try_retrieve t with
      | Some v -> v
      | None   -> loop ()
    end else
      suspend t.sqs
  in
  loop ()
