# Abstract
Writing concurrent code with ensureed correctness and performance is a notoriously tough task. CQS is an abstraction which offers a common framework for building and reasoning about these concurrent data structures and their interactions. It also offers support for cancellation of threads, and hence promises high performance in concurrent applications with high number of operation abortion 
The project covers its replication, implementation and some optimizations in OCaml. We compare it against the equivalent abstraction in Java (AbstractQueueSynchronizer) and Kotlin (Original Work)


# Background


# Implementation (Core)

### Basic Construction
- CQS is implemented as an infinite doubly linked list of `Segments`, where each segment stores a fixed number of slots for waiting EIO Fibers (EIO Fiber discussion covered later).
    - Doubly linked list is an implementation detail enabling fast deletion of cancelled/refused segments

- Supported Operations on CQS:
    1. Resume (val):
    2. Suspend
    3. Cancel

- EIO Fiber is used as a thread-safe alternative for the Thread API in Kotlin (Covered in later section )

- Each cell stores the following values in the corresponding cases:
    1. Suspended waiter thread (on calling suspend)
    2. Resumed state return value (When resume is called before suspend)
    3. Cancelled slot value
    4. Refused slot value

- Any segment with all slots being cancelled, refused or completed are removed from the doubly linked list


## Operations on CQS

### Suspend
- It parks the calling light weight thread in the queue untill a matching [resume] operation delivers it a value to continue with.
- In a sequential setting, a [resume] operation coming before [suspend] cannot be linearized appropriately, however in a concurrent/parallel setting, we may allow such an execution
- This implies that a [resume] operation entering a CQS may be valid as long as a concurrent [suspend] can be guaranteed to satisfy it. This is the core idea behind the ASYNC mode of CQS operations.
- However, we cannot naively allow [resume] to exist in the CQS Queue, since a sequential [suspend] can satisfy the [resume] operation enqueued.
- As a solution to this, `Sync` mode forces [resume] to busy wait for a bounded time frame, within which a concurrent [suspend] operation can match with a spinning [resume] operation 
    - If [resume] matches with a concurrent [suspend], the [suspend]ed Lightweight Thread is immediately resumed with the value passed in by the [resume] operation
    - If [resume] cannot be matched with a concurrent [suspend] 

### Resume (val): 
- It matches with a pending [suspend] in the CQS to continue the waiter with the value.
- Resumes are also allowed to enter the synchronizer queue without any 

### Cancel
For a waiter in the CQS, the [cancel] operation can be performed when thread is in the `suspended` state.


### LightWeight threads as EIO Fibers
Original work defined the queue mechanisms on top of a cancellable LightWeight thread interface, which is a language native feature in Kotlin.
This however is not the case in OCaml, which contains mainly the `Domain` type for OS thread mapping.
To replicate a similar behavior in OCaml, we have used `EIO.Fiber` as a cancellable Lightweight Thread replacement.

#### Original Idea: Implement concurrency using Effect Handlers
Drawing from class lectures, our original idea 



## Synchronization Primitives
We implemented the following synchronization primitives, effectively by following the description of them in the original paper /cite{nikita} 