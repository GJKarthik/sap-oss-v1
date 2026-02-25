# vLLM Rewrite Architecture

This document describes the architecture of the vLLM rewrite project, including the design decisions, component interactions, and data flow.

## 📋 Table of Contents

- [Overview](#overview)
- [Language Selection Rationale](#language-selection-rationale)
- [Component Architecture](#component-architecture)
- [Data Flow](#data-flow)
- [Memory Model](#memory-model)
- [Concurrency Model](#concurrency-model)
- [FFI Design](#ffi-design)

## Overview

The vLLM rewrite splits the codebase into three language domains:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           User Applications                              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         API Layer (Zig)                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │  HTTP Server    │  │  gRPC Server    │  │  CLI Interface          │  │
│  │  (OpenAI API)   │  │  (Bidirectional)│  │  (vllm serve/bench)     │  │
│  └────────┬────────┘  └────────┬────────┘  └───────────┬─────────────┘  │
│           └────────────────────┴───────────────────────┘                 │
│                                │                                         │
└────────────────────────────────┼─────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Rules Engine (Mangle)                               │
│  ┌──────────────┐  ┌────────────────┐  ┌──────────────┐                 │
│  │ Config       │  │ Scheduling     │  │ Validation   │                 │
│  │ Validation   │  │ Policies       │  │ Rules        │                 │
│  │              │  │                │  │              │                 │
│  │ • Model cfg  │  │ • Priority     │  │ • Request    │                 │
│  │ • HW compat  │  │ • Preemption   │  │ • Response   │                 │
│  │ • Quant      │  │ • Batching     │  │ • Safety     │                 │
│  └──────────────┘  └────────────────┘  └──────────────┘                 │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Engine Core (Zig)                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │  Scheduler   │  │ Block        │  │ Distributed  │  │ Platform    │  │
│  │              │  │ Manager      │  │ Runtime      │  │ Abstraction │  │
│  │ • FCFS       │  │              │  │              │  │             │  │
│  │ • Priority   │  │ • KV-cache   │  │ • Tensor ∥   │  │ • CUDA      │  │
│  │ • Fairness   │  │ • Prefix     │  │ • Pipeline ∥ │  │ • ROCm      │  │
│  │              │  │ • Eviction   │  │ • Data ∥     │  │ • CPU       │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └─────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Model Layer (Mojo)                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │   Models     │  │   Layers     │  │ Quantization │  │ Multimodal  │  │
│  │   (200+)     │  │              │  │              │  │             │  │
│  │              │  │ • Attention  │  │ • FP8        │  │ • CLIP      │  │
│  │ • Llama      │  │ • Linear     │  │ • INT4/INT8  │  │ • Whisper   │  │
│  │ • Mistral    │  │ • MLP        │  │ • AWQ/GPTQ   │  │ • LLaVA     │  │
│  │ • Qwen       │  │ • Norm       │  │ • Marlin     │  │             │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └─────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    CUDA/C++ Kernels (Unchanged)                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Flash Attention  │  GEMM  │  LayerNorm  │  Custom Ops          │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          GPU Hardware                                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐ │
│  │  NVIDIA     │  │  AMD        │  │  Intel      │  │  Apple Silicon  │ │
│  │  (CUDA)     │  │  (ROCm)     │  │  (oneAPI)   │  │  (Metal)        │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Language Selection Rationale

### Why Zig for Infrastructure?

| Requirement | Zig Advantage |
|-------------|---------------|
| Memory Safety | Compile-time memory safety, no GC pauses |
| Performance | Zero-cost abstractions, no runtime overhead |
| C Interop | First-class C ABI compatibility for CUDA FFI |
| Concurrency | Built-in async/await, no GIL |
| Binary Size | Small binaries, static linking |
| Debugging | Rich compile-time errors, runtime safety checks |

```zig
// Example: Zero-allocation request handling
pub fn handle_request(request: *Request) !void {
    // Stack allocation where possible
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    
    // Explicit memory management
    const result = try process(request, fba.allocator());
    defer result.deinit();
    
    // Compile-time checked error handling
    try send_response(result);
}
```

### Why Mojo for Models?

| Requirement | Mojo Advantage |
|-------------|----------------|
| ML-Native | Built for AI/ML workloads |
| SIMD | First-class vectorization support |
| Python Compat | Can import Python libraries during transition |
| Performance | Compiled, not interpreted |
| Tensor Support | Native tensor operations |
| GPU | Direct GPU kernel generation |

```mojo
# Example: SIMD-optimized attention
fn scaled_dot_product_attention(
    query: Tensor[DType.float16],
    key: Tensor[DType.float16],
    value: Tensor[DType.float16],
    scale: Float16,
) -> Tensor[DType.float16]:
    # Automatic SIMD vectorization
    let scores = query @ key.T() * scale
    let weights = softmax(scores, axis=-1)
    return weights @ value
```

### Why Mangle for Rules?

| Requirement | Mangle Advantage |
|-------------|------------------|
| Declarative | Rules as data, not code |
| Verifiable | Formal logic, provable correctness |
| Composable | Rules can be combined |
| Auditable | Clear policy definition |
| Maintainable | Non-programmers can update rules |

```mangle
# Example: Scheduling policy as declarative rules
schedule_request(Request, ScheduleAction) :-
    Request.priority >= urgent_threshold(),
    available_capacity() > Request.estimated_tokens,
    ScheduleAction = schedule_immediately.

schedule_request(Request, ScheduleAction) :-
    Request.priority < urgent_threshold(),
    queue_length() < max_queue_length(),
    ScheduleAction = add_to_queue.

schedule_request(Request, ScheduleAction) :-
    queue_length() >= max_queue_length(),
    ScheduleAction = reject_with_backpressure.
```

## Component Architecture

### 1. API Layer (Zig)

```
┌─────────────────────────────────────────────────────────┐
│                     HTTP Server                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ Router      │  │ Middleware  │  │ SSE Streaming   │  │
│  │             │  │             │  │                 │  │
│  │ /v1/chat    │  │ • Auth      │  │ • Token-by-    │  │
│  │ /v1/completions │ • Logging │  │   token        │  │
│  │ /v1/models  │  │ • Metrics   │  │ • Chunked      │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

**Key Design Decisions:**

1. **Connection Pooling**: Reuse TCP connections to reduce latency
2. **Zero-Copy Parsing**: Parse JSON without heap allocations
3. **Streaming**: Server-Sent Events for real-time token delivery
4. **Backpressure**: Reject requests when queue is full

### 2. Engine Core (Zig)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Engine Core                               │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                     Request Lifecycle                       │ │
│  │                                                             │ │
│  │  [Arrive] → [Validate] → [Queue] → [Schedule] → [Execute]  │ │
│  │      │          │           │           │           │       │ │
│  │      ▼          ▼           ▼           ▼           ▼       │ │
│  │   Mangle    Mangle      Priority    Mangle      Mojo       │ │
│  │   Rules     Rules       Queue       Rules       Model      │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────┐  ┌──────────────────────────────────┐ │
│  │   Scheduler          │  │   Memory Manager                  │ │
│  │                      │  │                                   │ │
│  │  • Continuous        │  │  • PagedAttention blocks         │ │
│  │    batching          │  │  • Prefix caching                │ │
│  │  • Dynamic           │  │  • Copy-on-write                 │ │
│  │    batch sizing      │  │  • Speculative allocation        │ │
│  │  • Preemption        │  │                                   │ │
│  └──────────────────────┘  └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Key Data Structures:**

```zig
// Request state machine
const RequestState = enum {
    pending,        // Waiting in queue
    running,        // Currently being processed
    preempted,      // Paused for higher priority
    completed,      // Finished successfully
    failed,         // Error occurred
};

// KV-cache block
const Block = struct {
    physical_id: u32,
    ref_count: u32,
    last_access: i64,
    hash: u64,          // For prefix caching
    data: [*]f16,       // Pointer to GPU memory
};

// Block table for paged attention
const BlockTable = struct {
    logical_to_physical: []u32,
    num_blocks: u32,
    sequence_id: u64,
};
```

### 3. Model Layer (Mojo)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Model Layer                               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Model Registry                         │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────────┐ │   │
│  │  │ Llama   │ │ Mistral │ │ Qwen    │ │ ... (200+ more) │ │   │
│  │  └────┬────┘ └────┬────┘ └────┬────┘ └────────┬────────┘ │   │
│  │       └───────────┴───────────┴───────────────┘          │   │
│  │                           │                               │   │
│  │                           ▼                               │   │
│  │  ┌──────────────────────────────────────────────────┐    │   │
│  │  │              Base Model Interface                 │    │   │
│  │  │  • forward(input_ids, positions, kv_cache)       │    │   │
│  │  │  • load_weights(path)                            │    │   │
│  │  │  • get_config() -> ModelConfig                   │    │   │
│  │  └──────────────────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                      Layer Library                        │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐            │   │
│  │  │ Attention  │ │ Linear     │ │ MLP        │            │   │
│  │  │            │ │            │ │            │            │   │
│  │  │ • MHA      │ │ • Dense    │ │ • GatedMLP │            │   │
│  │  │ • GQA      │ │ • LoRA     │ │ • SwiGLU   │            │   │
│  │  │ • MQA      │ │ • Quant    │ │ • GeGLU    │            │   │
│  │  └────────────┘ └────────────┘ └────────────┘            │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐            │   │
│  │  │ Embedding  │ │ Norm       │ │ Activation │            │   │
│  │  │            │ │            │ │            │            │   │
│  │  │ • Token    │ │ • RMSNorm  │ │ • SiLU     │            │   │
│  │  │ • Position │ │ • LayerNorm│ │ • GELU     │            │   │
│  │  │ • RoPE     │ │ • GroupNorm│ │ • ReLU     │            │   │
│  │  └────────────┘ └────────────┘ └────────────┘            │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**Model Interface:**

```mojo
trait Model:
    fn forward(
        inout self,
        input_ids: Tensor[DType.int32],      # [batch, seq_len]
        positions: Tensor[DType.int32],       # [batch, seq_len]
        kv_cache: KVCache,                    # Paged KV cache
        input_metadata: InputMetadata,        # Attention metadata
    ) -> Tensor[DType.float16]:              # [batch, seq_len, vocab]
        ...
    
    fn load_weights(inout self, path: String) -> None:
        ...
    
    fn num_parameters(self) -> Int:
        ...
```

### 4. Rules Engine (Mangle)

```
┌─────────────────────────────────────────────────────────────────┐
│                       Rules Engine                               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Rule Categories                        │   │
│  │                                                           │   │
│  │  ┌─────────────────┐  ┌─────────────────────────────────┐│   │
│  │  │ Configuration   │  │ Scheduling                      ││   │
│  │  │                 │  │                                 ││   │
│  │  │ valid_config/1  │  │ schedule_priority/2             ││   │
│  │  │ compatible/2    │  │ can_preempt/2                   ││   │
│  │  │ requires_gpu/1  │  │ batch_compatible/2              ││   │
│  │  └─────────────────┘  └─────────────────────────────────┘│   │
│  │                                                           │   │
│  │  ┌─────────────────┐  ┌─────────────────────────────────┐│   │
│  │  │ Memory          │  │ Validation                      ││   │
│  │  │                 │  │                                 ││   │
│  │  │ allocate/2      │  │ valid_request/1                 ││   │
│  │  │ evict/2         │  │ safe_content/1                  ││   │
│  │  │ share_prefix/2  │  │ within_limits/1                 ││   │
│  │  └─────────────────┘  └─────────────────────────────────┘│   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Query Interface                        │   │
│  │                                                           │   │
│  │   Zig Engine ←──────→ Mangle Runtime ←──────→ Rule Files │   │
│  │                                                           │   │
│  │   query("schedule_priority", request) → priority_value    │   │
│  │   query("valid_config", config) → true/false              │   │
│  │   query("can_preempt", [req1, req2]) → true/false         │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### Request Processing Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Request Processing Pipeline                       │
└─────────────────────────────────────────────────────────────────────────┘

1. HTTP Request Arrives
   │
   ▼
┌──────────────────┐
│ Parse JSON       │ ← Zig: Zero-copy JSON parsing
│ (Zig HTTP)       │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Validate Request │ ← Mangle: valid_request(Request)
│ (Mangle Rules)   │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Tokenize Input   │ ← Mojo: BPE/SentencePiece
│ (Mojo Tokenizer) │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Calculate        │ ← Mangle: schedule_priority(Request, Priority)
│ Priority         │
│ (Mangle Rules)   │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Enqueue Request  │ ← Zig: Priority queue insertion O(log n)
│ (Zig Scheduler)  │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Allocate KV      │ ← Mangle: allocate(Request, Blocks)
│ Blocks           │   Zig: Physical block allocation
│ (Zig + Mangle)   │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Execute Forward  │ ← Mojo: Model forward pass
│ Pass             │   CUDA: Kernels
│ (Mojo + CUDA)    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Sample Next      │ ← Mojo: Top-k/Top-p sampling
│ Token            │
│ (Mojo Sampler)   │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Detokenize &     │ ← Mojo: Token → Text
│ Stream Response  │   Zig: SSE streaming
│ (Mojo + Zig)     │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Check Stop       │ ← Loop until stop condition
│ Condition        │
└──────────────────┘
```

### Continuous Batching Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Continuous Batching                               │
└─────────────────────────────────────────────────────────────────────────┘

Time ──────────────────────────────────────────────────────────────────►

Batch Slot 0: │ Req A ──────────────────────────│ Req D ────────────────│
Batch Slot 1: │ Req B ────────────│ Req E ──────────────────────────────│
Batch Slot 2: │ Req C ──────│ Req F ────│ Req G ────────────────────────│
Batch Slot 3: │ (empty) │ Req H ──────────────────────│ Req I ──────────│

Legend:
────── = Request executing (prefill + decode)
│      = Batch boundary (scheduler iteration)

Scheduler Logic (each iteration):
1. Check for completed requests → Free slots
2. Check for preemption conditions → Pause low priority
3. Fill empty slots with waiting requests
4. Adjust batch composition for optimal throughput
```

## Memory Model

### KV-Cache Block Structure

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         GPU Memory Layout                                │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                        Block Pool                                   │ │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐           │ │
│  │  │Block 0 │ │Block 1 │ │Block 2 │ │Block 3 │ │Block 4 │  ...      │ │
│  │  │        │ │        │ │        │ │        │ │        │           │ │
│  │  │ K[0:16]│ │ K[16:32│ │ K[0:16]│ │ (free) │ │ K[32:48│           │ │
│  │  │ V[0:16]│ │ V[16:32│ │ V[0:16]│ │        │ │ V[32:48│           │ │
│  │  │        │ │        │ │        │ │        │ │        │           │ │
│  │  │ Req A  │ │ Req A  │ │ Req B  │ │        │ │ Req A  │           │ │
│  │  └────────┘ └────────┘ └────────┘ └────────┘ └────────┘           │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                      Block Tables                                   │ │
│  │                                                                     │ │
│  │  Request A: [0, 1, 4, ...]     (Logical → Physical mapping)        │ │
│  │  Request B: [2, ...]                                                │ │
│  │  Request C: [0, 2, ...]        (Sharing block 0 with A - prefix)   │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘

Block Size: 16 tokens × num_heads × head_dim × 2 (K+V) × sizeof(dtype)
Example: 16 × 32 × 128 × 2 × 2 bytes = 256 KB per block
```

### Prefix Caching

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Prefix Caching                                   │
│                                                                          │
│  Request A: "You are a helpful assistant. User: What is 2+2?"           │
│  Request B: "You are a helpful assistant. User: What is the capital?"   │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    Shared Prefix Tree                             │   │
│  │                                                                   │   │
│  │                    "You are a helpful"                            │   │
│  │                           │                                       │   │
│  │                           ▼                                       │   │
│  │                    [Block 0: hash=0x1234]                         │   │
│  │                           │                                       │   │
│  │                           ▼                                       │   │
│  │                    "assistant. User:"                             │   │
│  │                           │                                       │   │
│  │                           ▼                                       │   │
│  │                    [Block 1: hash=0x5678]                         │   │
│  │                          / \                                      │   │
│  │                         /   \                                     │   │
│  │              "What is 2+2?"  "What is the capital?"               │   │
│  │                    │                │                             │   │
│  │                    ▼                ▼                             │   │
│  │            [Block 2: A only]  [Block 3: B only]                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  Memory Savings: Blocks 0, 1 are shared → 50% reduction                 │
└─────────────────────────────────────────────────────────────────────────┘
```

## Concurrency Model

### Zig Async Architecture

```zig
// Non-blocking event loop
pub fn main() !void {
    var server = try Server.init(config);
    defer server.deinit();
    
    // Async accept loop
    while (true) {
        const conn = try server.accept();
        
        // Spawn handler without blocking
        _ = async handleConnection(conn);
    }
}

fn handleConnection(conn: *Connection) !void {
    defer conn.close();
    
    while (true) {
        // Non-blocking read
        const request = try conn.readRequest();
        
        // Process request asynchronously
        const response = try processRequest(request);
        
        // Non-blocking write
        try conn.writeResponse(response);
    }
}
```

### Thread Pool Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Thread Pool Architecture                         │
│                                                                          │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────────────────────┐│
│  │ IO Threads    │  │ Compute       │  │ GPU Streams                   ││
│  │ (Network)     │  │ Threads       │  │                               ││
│  │               │  │               │  │                               ││
│  │ • Accept      │  │ • Tokenize    │  │ • Stream 0: Prefill           ││
│  │ • Read        │  │ • Detokenize  │  │ • Stream 1: Decode            ││
│  │ • Write       │  │ • Sample      │  │ • Stream 2: Copy H2D          ││
│  │ • TLS         │  │ • Schedule    │  │ • Stream 3: Copy D2H          ││
│  │               │  │               │  │                               ││
│  │ Count: 4      │  │ Count: 8      │  │ Count: 4                      ││
│  └───────────────┘  └───────────────┘  └───────────────────────────────┘│
│                                                                          │
│  Communication:                                                          │
│  • Lock-free queues between thread pools                                │
│  • Async notifications via eventfd                                       │
│  • Zero-copy buffer passing                                              │
└─────────────────────────────────────────────────────────────────────────┘
```

## FFI Design

### Zig ↔ Mojo Interface

```zig
// zig/src/ffi/mojo.zig

/// Opaque handle to Mojo model
const MojoModel = opaque {};

/// FFI function declarations (linked at build time)
extern fn mojo_model_load(path: [*:0]const u8) ?*MojoModel;
extern fn mojo_model_forward(
    model: *MojoModel,
    input_ids: [*]const i32,
    positions: [*]const i32,
    batch_size: usize,
    seq_len: usize,
    kv_cache_ptr: *anyopaque,
    output: [*]f16,
) void;
extern fn mojo_model_free(model: *MojoModel) void;

/// Safe Zig wrapper
pub const Model = struct {
    handle: *MojoModel,
    
    pub fn load(path: []const u8) !Model {
        const c_path = try std.mem.dupeZ(u8, path);
        defer std.heap.c_allocator.free(c_path);
        
        const handle = mojo_model_load(c_path.ptr) orelse 
            return error.ModelLoadFailed;
        
        return Model{ .handle = handle };
    }
    
    pub fn forward(self: *Model, batch: Batch, kv_cache: *KVCache) ![]f16 {
        // ...
    }
    
    pub fn deinit(self: *Model) void {
        mojo_model_free(self.handle);
    }
};
```

### Zig ↔ CUDA Interface

```zig
// zig/src/ffi/cuda_kernels.zig

/// Link to existing CUDA kernels
extern fn flash_attention_forward(
    q: *const f16,
    k: *const f16,
    v: *const f16,
    out: *f16,
    batch_size: c_int,
    seq_len: c_int,
    num_heads: c_int,
    head_dim: c_int,
    stream: *anyopaque,
) void;

extern fn rms_norm_forward(
    input: *const f16,
    weight: *const f16,
    output: *f16,
    num_tokens: c_int,
    hidden_size: c_int,
    epsilon: f32,
    stream: *anyopaque,
) void;

/// Safe Zig wrappers with dimension checking
pub fn flashAttention(
    q: Tensor(f16),
    k: Tensor(f16),
    v: Tensor(f16),
    stream: CudaStream,
) !Tensor(f16) {
    // Validate dimensions
    if (q.shape[0] != k.shape[0] or q.shape[0] != v.shape[0]) {
        return error.DimensionMismatch;
    }
    
    var output = try Tensor(f16).allocate(q.shape);
    
    flash_attention_forward(
        q.ptr,
        k.ptr,
        v.ptr,
        output.ptr,
        @intCast(q.shape[0]),
        @intCast(q.shape[1]),
        @intCast(q.shape[2]),
        @intCast(q.shape[3]),
        stream.handle,
    );
    
    return output;
}
```

### Mangle Query Interface

```zig
// zig/src/ffi/mangle.zig

const MangleRuntime = opaque {};

extern fn mangle_runtime_new(rules_path: [*:0]const u8) ?*MangleRuntime;
extern fn mangle_query(
    runtime: *MangleRuntime,
    predicate: [*:0]const u8,
    args: [*]const MangleValue,
    num_args: usize,
    result: *MangleValue,
) bool;
extern fn mangle_runtime_free(runtime: *MangleRuntime) void;

pub const RulesEngine = struct {
    runtime: *MangleRuntime,
    
    pub fn init(rules_dir: []const u8) !RulesEngine {
        // Load all .mg files
        // ...
    }
    
    pub fn queryPriority(self: *RulesEngine, request: *Request) !i32 {
        var result: MangleValue = undefined;
        const args = [_]MangleValue{
            MangleValue.fromRequest(request),
        };
        
        if (!mangle_query(
            self.runtime,
            "schedule_priority",
            &args,
            args.len,
            &result,
        )) {
            return error.QueryFailed;
        }
        
        return result.toInt();
    }
    
    pub fn canPreempt(
        self: *RulesEngine,
        victim: *Request,
        preemptor: *Request,
    ) bool {
        // ...
    }
};
```

## Performance Considerations

### Memory Alignment

```zig
// Align structures for cache efficiency
const Request = struct {
    // Hot fields (accessed every iteration) - first cache line
    state: RequestState align(64),
    priority: i32,
    tokens_generated: u32,
    next_token_id: u32,
    
    // Cold fields (accessed less frequently)
    request_id: [36]u8,
    arrival_time: i64,
    // ...
};

comptime {
    // Verify alignment
    std.debug.assert(@alignOf(Request) == 64);
    std.debug.assert(@sizeOf(Request) <= 128); // Fits in 2 cache lines
}
```

### SIMD Operations in Mojo

```mojo
# Vectorized sampling
fn top_k_sample[width: Int](
    logits: Tensor[DType.float16],
    k: Int,
) -> Int:
    alias simd_width = simdwidthof[DType.float16]()
    
    var max_vals = SIMD[DType.float16, simd_width](-inf)
    var max_idxs = SIMD[DType.int32, simd_width](0)
    
    # Process in SIMD chunks
    for i in range(0, logits.size(), simd_width):
        let chunk = logits.load[width=simd_width](i)
        let mask = chunk > max_vals
        max_vals = mask.select(chunk, max_vals)
        max_idxs = mask.select(SIMD[DType.int32, simd_width].iota() + i, max_idxs)
    
    # Reduce across SIMD lanes
    return reduce_max(max_vals, max_idxs)
```

---

## Summary

This architecture leverages:

1. **Zig** for memory-safe, high-performance systems code without GC pauses
2. **Mojo** for ML-native tensor operations with automatic SIMD vectorization
3. **Mangle** for declarative, auditable policy rules that can be modified without recompilation

The result is a faster, safer, and more maintainable vLLM implementation.