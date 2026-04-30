
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


