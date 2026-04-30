
## Abstract

CancellableQueueSynchronizer is a new experimental framework enabling simple 
and efficient implementations of synchronization primitives for Kotlin coroutines. 
It emphasises rich semantics for lightweight threads that are cheap to suspend and
resume while supporting fair FIFO ordering and abortable operations, all backed
by modular formal proofs of their properties.
In this mini project, we attempt to port this framework to OCaml with the help
of Agentic AI and evaluate its versatility in implementing synchronization 
primitives. All the implementations were tested using QCheck-Lin and QCheck-STM,
and compared against JVM implementations. 
While the results were mixed, we highlight a faster feedback loop porting code and the
need for good abstractions and advanced testing.


## Goals

Our main objective is to port the CancellableQueueSynchronizer (CQS) framework for Kotlin 
coroutines. The highlights of CQS are:
\begin{itemize}
  \item Simple semantics for suspending and resuming coroutines.
  \item Expressive power capable of implementing mutexes, semaphores, barrier, countdown latches.
  \item Formal proofs of properties in Rocq.
\end{itemize}

Being able to do this in a common abstraction helps keep things relatively simple and
allows for modularity and code reuse. As CQS is already implemented in Kotlin, it is also a 
great candidate for understanding the usecase of Agentic AI for porting between languages while
leveraging the existing tests.

In particular, CQS incorporates multiple aspects such as:
\begin{itemize}
  \item Matching suspend and resume operations similar to how push and pop operations are
   matched in a elimination stack.
  \item Helping mechanism while handling cancelled coroutines.
\end{itemize}

Would a similar framework benefit from a OCaml concurrency model? How do our primitives 
implementations compare against Java's and Kotlin's implementation and how can we confirm
this quantitatively?