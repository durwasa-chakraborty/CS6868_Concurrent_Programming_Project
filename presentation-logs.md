# Section 1: Introduction 
- Comparison with AbstractQueueSynchronizer in Java

# Section 2: Core CQS Structure
- Infinite queue with
- State Diagram and Explaination
    - Resume before suspend
    - SYNC vs ASYNC mode
        - Busy waiting of resume - To allow only concurrent suspend to match with a resume
    - Sma

# Section 2: CQS using simple function thunk - Sonnet [Wrong]
# Section 3: CQS using Effect Handlers
- Issues: Effects in OCaml aren't thread-safe
# Section 4: CQS using Eio.Fiber as Cancellable Thread Primitiveusing Effect Handlers
# Section 5: Benchmarking
