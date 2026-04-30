# Abstract

We port the Cancellable Queue Synchronizer (CQS)~\cite{koval2023cqs} from
Kotlin to OCaml~5. CQS is the framework behind Kotlin's coroutine library
that lets you build fair, FIFO, abortable synchronization primitives like
semaphores and mutexes on top of a single queue-of-waiters abstraction.

Porting it directly with OCaml~5's effect handlers does not work, because
the continuations they capture are tied to the domain that created them;
so a \texttt{release} on one domain cannot wake a \texttt{suspend} on
another. We fix this by routing wake-ups through Eio's domain-safe enqueue
function~\cite{eio}, while keeping the rest of the CQS design (segment
linked list, cell state machine, Sync/Async resume modes, Simple/Smart
cancellation) the same. On top of this we build six primitives: mutex,
semaphore, barrier, count-down latch, and blocking queue and stack pools.

We test each primitive with a hand-written 2-domain linearizability
harness, with \texttt{qcheck-lin}~\cite{qcheck} and \texttt{qcheck-stm},
and with manual cross-domain scenarios under ThreadSanitizer; all pass.
We benchmark against \texttt{java.util.concurrent}~\cite{lea2005aqs} on
1--8 threads. Our pools and count-down latch beat Java, but our mutex
and semaphore are slower under contention because Eio fibre park/wake
costs more than a JVM thread context switch. The main takeaway: CQS
ports cleanly to OCaml~5 once you have a domain-safe wake-up primitive.

