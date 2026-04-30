# Abstract

Writing concurrent code with ensured correctness and performance is a notoriously tough task.
CancellableQueueSynchronizer (CQS)~\cite{koval2023cqs} is a new experimental framework enabling
simple and efficient implementations of such synchronization primitives for Kotlin coroutines.
It emphasises rich semantics for lightweight threads that are cheap to suspend and
resume while supporting fair FIFO ordering and abortable operations, all backed
by modular formal proofs of their properties. We port the Cancellable Queue Synchronizer
(CQS)~\cite{koval2023cqs} from Kotlin to OCaml~5~\cite{kcsrk2022}. Each primitive is tested against
a hand-written 2-domain linearizability harness, with \texttt{qcheck-lin}~\cite{qcheck},
\texttt{qcheck-stm}, and with manual cross-domain scenarios under ThreadSanitizer; all pass.
We benchmark against \texttt{java.util.concurrent.AbstractQueueSynchronizer}~\cite{lea2005aqs} on
1--8 threads. Our implementations of blocking pools and count-down latch beat Java, but our mutex
and semaphore are slower under contention because Eio fibre park/wake
costs more than a JVM thread context switch. While the results were mixed, we highlight
a faster feedback loop porting code and the need for good abstractions and advanced testing.




# Background

### Motivation: Fairness, Abortability, and the Coroutine Setting

Synchronization primitives like mutexes, semaphores, barriers, etc are among the most fundamental abstractions in concurrent programming. Hence, modern programming languages require strong semantics and formal gurantees from them.

Two properties are particularly desirable. 
- **Fairness**: waiting requests should be served in the order of their arrival (FIFO), preventing starvation. 
- **abortability**: a waiting request must be cancellable at any time, due to a timeout or an explicit user action. 

These requirements have become especially pressing with the rise of *coroutines*, which are:
 - Lightweight scheduling units that can be spawned in large amounts within a single process,
 - Cheaper to suspend and resume than native threads,
 - More frequently cancelled.

When a coroutine suspends, its underlying thread immediately picks up another coroutine rather than blocking. Hence, the cost of fair scheduling is lower than in a thread-based model, while the cost of inefficient cancellation is higher.

The only practical abstraction that provides similar semantics prior to this work is Java's `AbstractQueuedSynchronizer` (AQS), which forms the core of the `java.util.concurrent` package. AQS maintains a CLH-style doubly-linked queue of waiting threads and uses `CAS` on an integer state field. Cancelling a thread in AQS requires traversing the queue linearly and unlinking a cancelled node. While this is fine for a small number of threads, it doesn't scale well for large no of lightweight coroutines that may be cancelled more frequently.

### The CQS Framework

Koval et al. introduce the **Cancellable Queue Synchronizer** (CQS) to close this gap. CQS provides two operations:

- `suspend()`: adds the current thread (or coroutine) as a waiter and suspends.
- `resume(result)`: retrieves and resumes the next waiter, passing it the specified value.

Here, `resume()` may be called *before* `suspend()`. If a `resume()` arrives at a cell before the matching `suspend()`, the value is deposited in the cell and the later `suspend()` claims it atomically and returns immediately without actually suspending — an *elimination*. Primitive implementations exploit this property for both simplicity and performance.

### Asynchronous Resume and Suspend
In a sequential setting, a resume operation coming before suspend cannot be linearized appropriately. However, in a concurrent setting, we need to allow such an execution for high throughput. This implies that a resume operation entering a CQS may be valid as long as a concurrent suspend is available to satisfy it. This is the core idea behind the SYNC/ASYNC mode of CQS operations. 


### Cancellation Support
Supporting cancellation without races is the central technical challenge of CQS. The framework defines two modes for this:

1. **Simple cancellation.** When a waiter is cancelled, its cell is marked `CANCELLED`. A `resume()` that encounters a `CANCELLED` cell simply returns `false`, signalling to the calling primitive that it must retry. This mode is straightforward but has a linear-time worst case when many consecutive waiters are cancelled before the corresponding `resume()` arrives: each `resume()` must traverse all cancelled cells individually.

2. **Smart cancellation.** Smart cancellation allows `resume()` to skip cancelled cells and retry atomically, reducing the cost of a sequence of cancellations per `resume()`. Intuitively, the difference is that in the simple cancellation mode, resume(..) fails if the thread in the corresponding cell has been cancelled, whereas the smart cancellation enables efficient 
skipping a sequence of aborted requests. 

### Synchronization Primitives Built on CQS

The paper demonstrates the expressiveness of the framework by building five primitives on top of it.

**Mutex** and **Semaphore**: 
 - Implemented with a signed integer counter.
 - Non-positive counter encodes the number of waiting `lock()` callers; a positive value encodes the number of available permits. 
 - `lock()`/`acquire()` decrements the counter via Fetch-And-Add (`FAA`); 
    - if the pre-decrement value was positive, the operation succeeds immediately.
    - Otherwise it calls `suspend()`. 
 - `unlock()`/`release()` increments the counter via `FAA`; 
    - if the pre-increment value was negative, there is a waiter, and `resume()` is called. 
    - When in Smart cancellation mode, `onCancellation()`
        - increments the counter and returns `true` if the counter was still negative (waiter successfully removed),
        - or `false` if the counter reached zero or above (a concurrent `resume()` is incoming and must be refused).

**Barrier**: 
 - maintains a `remaining` counter initialized to the number of coroutines. 
 - Each `arrive()` decrements `remaining` via `FAA`. All coroutines except the last caller will get suspended. The last caller issues `coroutines - 1` `resume()` calls to wake up all the others. 
 - Note: Cancellation is not supported. Cancelling a coroutine that has already physically reached the barrier point should not block the remaining coroutines. And so cancelled waiters are silently ignored via smart cancellation.

**Count-Down Latch**: 
 - maintains two counters: 
    - `count` (remaining `countDown()` calls) and
    - `waiters` (number of suspended `await()` callers).
 - When a latch is fire, a special `DONE_BIT` is set atomically by the thread that drives `count` to zero, signalling that the latch has fired. Afterwards, `await()` checks this and returns immediately if the latch has already fired.

**Blocking Pools** (queue and stack variants):
 - transfer actual elements through CQS rather than unit tokens
 - combines a `FAA`-based availability counter with a flat array for FIFO order or a Treiber stack for LIFO. 
    - `put()` increments the counter; if negative it calls `resume(element)` directly.
    - `retrieve()` decrements the counter; if positive it pops an element; otherwise it calls `suspend()`. 
 - Note: Neither variant is linearizable — concurrent races can produce non-FIFO or non-LIFO delivery — but this matches practical pool semantics where elements are interchangeable resources.

### Formal Proofs
All algorithms described above are formally verified using Iris - a concurrent separation logic framework implemented in Rocq. The proofs are written in a modular way so that the CQS proof is independent of the proofs of current or future primitives. One limitation the authors acknowledge is that the Iris specifications do not currently capture FIFO ordering (as waiting operations are allowed to complete in any order) or the absence of memory leaks (which have only been manually tested with Lincheck).






# Reflections

### Tools and models used

We initially started with Claude Sonnet. However, Claude Opus became our the main coding agent. We also used ChatGPT Codex (GPT-5) for paper explanation
and quick lookups. Claude Opus did most of the OCaml/Eio porting, the test scaffolding, and the benchmark drivers

### What worked well

Several aspects contributed to the success of using 
agentic LLM in the project. We found that 
dividing single-shot prompts into distinct phases
significantly improved structure and clarity. 
The use of plan mode ensured detailed explanations and 
enhanced understanding at each stage. Sanity and smoke
tests were used early on to prevent regressions
during development. Assignment templates provided to Claude 
were instrumental in generating LinCheck and STM tests. 
Clear definition of benchmark requirements, along with a 
well-organized folder structure, streamlined the workflow. 
Additionally, human-in-the-loop discussions with Claude 
enabled the implementation of essential optimizations and
alternatives, which proved crucial for a successful port

### What did not work

Our experience revealed several significant limitations in using Agentic LLMs
for large-scale software development tasks. PDF inputs proved particularly
ineffective, sometimes dramatically increasing token consumption.
Additionally, Sonnet demonstrated substantial weaknesses in preserving nuanced
implementation invariants, frequently introducing silent errors that were
difficult to detect without careful manual review. Poorly scoped or
insufficiently precise prompts further amplified these issues; for example, an
early attempt to have Sonnet port an implementation from Kotlin led to the
silent omission of a critical REFUSED cell state, fundamentally breaking the
correctness of the system and necessitating extensive repository-wide rewrites
using Opus. However, even more capable models such as Opus were not immune to
similar failures when operating on larger task units. During test suite
generation, Opus introduced a subtle concurrency bug in semaphore testing by
incorrectly configuring a Semaphore(1) for a scenario requiring Semaphore(2),
causing thread blocking that had to be manually identified and corrected. 


### What was surprising

One of the more surprising outcomes of our experience with Agentic LLMs was
their capacity to rapidly recover and substantially improve solution quality
when guided by carefully framed, strategically designed questions. In several
instances, the agent initially pursued flawed architectural directions; such as
attempting to implement lightweight threads through Effect Handlers; which, while
conceptually plausible, introduced critical issues related to continuation
safety. Specifically, although data transferred across continuations could be
made thread-safe, the continuation objects themselves were inherently unsafe for
the intended concurrency model. This limitation became especially apparent when
extending the system to support a cancellable API, a requirement that Sonnet
failed to adequately address in its original implementation. However, once the
problem was reframed through deliberate questioning and deeper chain-of-thought
exploration using Opus, the agent was able to reassess its approach, identify
more suitable abstractions, and ultimately propose a correct and significantly
more robust port of CQS using EIO Fibers. This demonstrated that while baseline
outputs may be error-prone, the models possess a surprisingly strong capacity
for strategic course correction when provided with precise conceptual guidance,
highlighting the importance of human-driven interrogation and iterative
refinement in maximizing the effectiveness of agentic development workflows.


### What was difficult
- Communication with Opus
- Correct ammount of verbosity in prompts

Explaining benchmark results was the hardest part. We had to tell the
agent that Java's \texttt{ReentrantLock} is reentrant (so the contended-
mutex numbers were not an apples-to-apples comparison with our non-reentrant SQS
mutex, and that the producer-consumer pool numbers looked too good
because the OCaml run was hitting the fast path). The agent will not
notice these things unless you point them out.

### Your overall assessment
These failures collectively underscore that while agentic LLMs can accelerate
development, they remain highly sensitive to prompt quality, struggle with
preserving subtle correctness guarantees, and require rigorous human oversight
to catch silent but potentially catastrophic implementation flaws.