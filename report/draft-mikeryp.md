# Abstract
Writing concurrent code with ensureed correctness and performance is a notoriously tough task. CQS is an abstraction which offers a common framework for building and reasoning about these concurrent data structures and their interactions. It also offers support for cancellation of threads, and hence promises high performance in concurrent applications with high number of operation abortion 
The project covers its replication, implementation and some optimizations in OCaml. We compare it against the equivalent abstraction in Java (AbstractQueueSynchronizer) and Kotlin (Original Work)


# Background


# Implementation (Core)

### Basic Construction
- CQS is implemented as an infinite doubly linked list of `Segments`, where each segment stores a fixed number of slots for waiting EIO Fibers.
    - Doubly linked list is an implementation detail enabling fast deletion of cancelled/refused segments

- Supported Operations:
    1. Resume (val):
    2. Suspend
    3. Cancel

- Each cell is meant to store the following values in the corresponding case:
    1. Suspended waiter thread (on calling suspend)
    2. Resumed state return value (When resume is called before suspend)
    2. Cancelled slot value
    3. Refused slot value

- Any segment with all slots being cancelled, refused or completed are removed from the doubly linked list


## Operations on CQS

### Suspend
It parks the calling light weight thread in the queue untill a matching [resume] operation delivers it a value to continue with.
In `Sync` mode, the suspend operation also

### Resume (val): 
- It matches with a pending suspend operation in the queue to continue the waiter with the value.
- Resumes are also allowed to enter the synchronizer queue without any 

### Cancel



### LightWeight threads as EIO Fibers
Original work defined the queue mechanisms on top of a cancellable LightWeight thread interface, which is a language native feature in Kotlin.
This however is not the case in OCaml, which contains mainly the `Domain` type for OS thread mapping.
To replicate the same behavior in OCaml world, we have used `EIO.Fiber` as a cancellable Lightweight Thread replacement.

