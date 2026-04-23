(lang dune 3.21)
(name cs6868_concurrent_programming_project)
(generate_opam_files true)

(package
 (name cs6868_concurrent_programming_project)
 (allow_empty)
 (synopsis "Segment Queue Synchronizer in OCaml with Eio")
 (description
  "Implementation and tests of the CQS/Segment Queue Synchronizer primitive \
   (semaphore, mutex, count-down latch, barrier, blocking queue/stack) \
   built on top of Eio fibers and effect handlers.")
 (depends
  (ocaml (>= 5.2))
  (dune (>= 3.21))
  (eio (>= 1.3))
  (eio_main (>= 1.3))
  (ppx_expect (>= v0.17))
  (qcheck-core (>= 0.25))
  (qcheck-lin (>= 0.10))))
