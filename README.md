# WhirlPool Actor System

WhirlPool is a performance-focused lite-actor system implemented in Zig. It provides a threading model designed to optimize cache efficiency while offering basic isolation between concurrent workloads.
It is currently in very early stages.

## Project Status

**WARNING! This is VERY early in development. DO NOT use this for your production systems**

WhirlPool is in active early development. The API, behavior, and guarantees may change significantly between versions. It currently prioritizes performance over comprehensive isolation, and needs more benchmark testing.

## Core Design Philosophy

WhirlPool is designed with the following principles:

- **Cache-friendly concurrency**: Minimize cache thrashing through isolated memory pools
- **Lightweight message passing**: Simple, efficient work distribution
- **Fast recovery**: Quick restart of failed actors without complex state management
- **Low overhead**: As we are trying to be "actor-lite" we keep overhead to a bare-minimum.

## Architecture

### Key Components

- **Actor**: A self-contained execution unit with its own memory arena and mailbox
- **Mailbox**: A thread-safe queue for work items
- **WhirlPool**: A supervisor that manages a pool of actors and distributes work
- **WorkItem**: A function pointer and data/result buffers to be processed by an actor

### Memory Model

Each actor is allocated a fixed memory block, managed through a `FixedBufferAllocator` and `ArenaAllocator`. This design:

- Prevents actors from interfering with each other's memory
- Enables fast cleanup and recovery after crashes
- Eliminates heap fragmentation concerns
- Maintains cache locality for better performance

## Ideal Use Cases

WhirlPool's goal is to explore use cases around CPU bound ML inferencing for Laconic Design - but can be used for multiple scenarios:

### 1. Small Inference Models

Deploying multiple small machine learning models where:
- Each model needs isolated memory
- Predictable latency is critical
- Cache locality improves throughput
- Models can be restarted cleanly if they crash (Note, it's actor-lite, end users must still handle panics and turn them into errors).

```zig
// Example: Running multiple small models in parallel
const model_data = fetchModelData();
try pool.pushWork(runInferenceModel, model_data, result_buffer);
```

### 2. Parallel Data Processing

Processing independent chunks of data where:
- Work can be easily partitioned
- Each work item has minimal dependencies
- Memory usage per task is predictable
- Failed processing can be retried

```zig
// Example: Process image chunks in parallel
for (image_chunks) |chunk| {
    try pool.pushWork(processImageChunk, chunk, result_buffers[i]);
}
```

### 3. Request Handling

Managing multiple concurrent requests where:
- Each request is relatively self-contained
- Failure of one request shouldn't affect others
- Memory usage per request is bounded
- Quick recovery improves availability

```zig
// Example: Handle multiple client requests
const request_data = client.readRequest();
try pool.pushWork(handleClientRequest, request_data, response_buffer);
```

## Non-Ideal Use Cases

WhirlPool is **not** well-suited for:

### 1. Complex Stateful Applications

Applications with significant shared state or complex dependencies between actors:
- The simple message-passing model doesn't handle complex interactions well
- State recovery after crashes is minimal - Mailboxes are non-preserved.
- No built-in support for distributed consensus - while ERLANG inspired, WhirlPool is focused on local systems.

### 2. Safety-Critical Systems

Systems where failures have severe consequences:
- Limited isolation between actors (thread-based, not process-based)
- Panics can potentially cascade through the system. As such, thorough testing of functions you pass to the system is required!
- No formal verification of correctness

### 3. Long-Running Transactions

Work that requires atomicity across multiple operations:
- No built-in transaction support
- Limited failure recovery semantics
- Work in progress when an actor crashes may be lost

### 4. Unbounded Resource Usage

Tasks that need to allocate unpredictable amounts of memory:
- Fixed memory allocation per actor
- No dynamic memory adjustment
- Resource exhaustion can cause crashes

## Performance Considerations

WhirlPool makes specific tradeoffs to optimize performance:

- **Fixed-size actors**: Each actor has a predetermined memory allocation, optimizing for predictable performance but limiting flexibility
- **Thread-per-actor**: Simple threading model at the cost of scalability to very large numbers of actors
- **Message copying**: Work data is passed by copying, avoiding shared memory complexities but adding overhead for large data
- **Limited isolation**: Crashes in one actor might affect the whole system in some cases

## Example Usage

```zig
// Initialize a pool with 4 actors, 1MB memory each, mailbox capacity 10
var pool = try WhirlPool.init(allocator, 4, 1024 * 1024, 10);
defer pool.deinit();

// Prepare work data and result buffer
const data = [_]u8{ 10, 20 };
var result_buffer = [_]u8{0} ** 32;

// Push work to the pool
try pool.pushWork(addNumbers, &data, &result_buffer);

// Allow time for work to complete
std.time.sleep(std.time.ns_per_ms * 10);

// Output will be in result_buffer
```

## Future Directions

Planned improvements to the WhirlPool system:

- [ ] CPU core pinning for better cache affinity
- [ ] Improved fault isolation and recovery mechanics
- [ ] Adaptive work distribution based on actor load
- [ ] Performance tracing and monitoring
- [ ] Timeout and work cancellation support
- [ ] Extensible logging infrastructure
- [ ] Testing with multiple sizes of ML models to test cache thrashing.

## Contribution
- Contribution is very much welcome. Submit an issue. I'm currently working in this from a private git hoster, but I'll update this once every two weeks going forward.
