# Contributing to vLLM Rewrite

Thank you for your interest in contributing to the vLLM Rewrite project! This document provides guidelines and information for contributors.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Pull Request Process](#pull-request-process)
- [Daily Tracking](#daily-tracking)
- [Testing](#testing)

## Code of Conduct

This project follows the [vLLM Code of Conduct](https://github.com/vllm-project/vllm/blob/main/CODE_OF_CONDUCT.md). Please be respectful and inclusive in all interactions.

## Getting Started

### Prerequisites

1. **Zig 0.13+**
   ```bash
   # macOS
   brew install zig
   
   # Linux
   curl -L https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz | tar -xJ
   
   # Verify installation
   zig version
   ```

2. **Mojo 24.x+**
   ```bash
   curl -s https://get.modular.com | sh
   modular install mojo
   
   # Verify installation
   mojo --version
   ```

3. **Mangle**
   ```bash
   # Clone and build Google's Mangle
   git clone https://github.com/google/mangle.git
   cd mangle && go build ./...
   ```

4. **CUDA Toolkit 12.x** (for GPU support)
   ```bash
   # Follow NVIDIA's installation guide
   # https://developer.nvidia.com/cuda-downloads
   ```

### Fork and Clone

```bash
# Fork the repository on GitHub, then:
git clone https://github.com/YOUR_USERNAME/vllm-rewrite.git
cd vllm-rewrite

# Add upstream remote
git remote add upstream https://github.com/vllm-project/vllm-rewrite.git
```

## Development Setup

### Building the Project

```bash
# Build Zig components
cd zig
zig build

# Run Zig tests
zig build test

# Build Mojo components
cd ../mojo
mojo build src/

# Validate Mangle rules
cd ../mangle
mangle check config/*.mg scheduling/*.mg
```

### IDE Setup

#### VS Code (Recommended)

Install these extensions:
- **Zig Language** (`ziglang.vscode-zig`)
- **Mojo** (`modular-mojotools.vscode-mojo`)

```json
// .vscode/settings.json
{
  "zig.path": "/usr/local/bin/zig",
  "zig.zls.path": "/usr/local/bin/zls",
  "editor.formatOnSave": true
}
```

## Project Structure

### Language Responsibilities

| Language | Component | Description |
|----------|-----------|-------------|
| **Zig** | Infrastructure | Engine, scheduler, memory, networking |
| **Mojo** | ML Computation | Models, layers, quantization |
| **Mangle** | Rules/Policies | Config validation, scheduling policies |

### Directory Layout

```
vllm-rewrite/
├── zig/src/
│   ├── engine/          # Core inference loop
│   ├── scheduler/       # Request scheduling
│   ├── memory/          # KV-cache block manager
│   ├── distributed/     # Parallelism
│   ├── server/          # HTTP/gRPC
│   └── cli/             # Command line
├── mojo/src/
│   ├── layers/          # NN layers
│   ├── models/          # Model implementations
│   ├── quantization/    # Quantization methods
│   └── multimodal/      # Vision/audio
├── mangle/
│   ├── config/          # Config rules
│   ├── scheduling/      # Scheduling rules
│   └── validation/      # Validation rules
└── tracking/
    └── daily/           # Daily progress
```

## Coding Standards

### Zig Style Guide

```zig
// Use snake_case for functions and variables
fn process_request(request: *Request) !void {
    // ...
}

// Use PascalCase for types
const RequestState = enum {
    pending,
    running,
    completed,
};

// Document public functions
/// Processes incoming inference requests.
/// Returns an error if the request queue is full.
pub fn enqueue_request(req: Request) !void {
    // ...
}

// Prefer explicit error handling
const result = try some_operation();

// Use defer for cleanup
const file = try std.fs.openFile(path, .{});
defer file.close();
```

### Mojo Style Guide

```mojo
# Use snake_case for functions and variables
fn forward(self, x: Tensor) -> Tensor:
    # ...

# Use PascalCase for structs
struct AttentionLayer:
    var num_heads: Int
    var head_dim: Int
    
    fn __init__(inout self, num_heads: Int, head_dim: Int):
        self.num_heads = num_heads
        self.head_dim = head_dim

# Use docstrings
fn compute_attention(
    query: Tensor,
    key: Tensor,
    value: Tensor,
) -> Tensor:
    """
    Computes scaled dot-product attention.
    
    Args:
        query: Query tensor of shape [batch, heads, seq, dim]
        key: Key tensor of shape [batch, heads, seq, dim]
        value: Value tensor of shape [batch, heads, seq, dim]
    
    Returns:
        Attention output tensor
    """
    # ...
```

### Mangle Style Guide

```mangle
# Use descriptive predicate names
valid_config(Config) :-
    Config.batch_size > 0,
    Config.batch_size <= max_batch_size().

# Group related rules together
# -- Scheduling Rules --

schedule_priority(Request, Priority) :-
    Request.is_urgent,
    Priority = 1000.

schedule_priority(Request, Priority) :-
    not Request.is_urgent,
    Priority = Request.base_priority.

# Document complex rules
# Determines if a request can preempt another
# based on priority and checkpoint capability
can_preempt(Victim, Preemptor) :-
    Preemptor.priority > Victim.priority,
    Victim.can_checkpoint,
    Victim.tokens_generated >= min_preempt_tokens().
```

## Pull Request Process

### Branch Naming

```
feature/zig-engine-core
feature/mojo-llama-model
bugfix/memory-leak-scheduler
docs/api-reference
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(zig): implement request queue with priority ordering
fix(mojo): correct attention mask broadcasting
docs: add API reference for scheduler
test(zig): add unit tests for block allocator
perf(mojo): optimize matmul with SIMD
```

### PR Checklist

- [ ] Code follows the style guide for the relevant language
- [ ] Tests added/updated for new functionality
- [ ] Documentation updated
- [ ] Daily tracking updated (if applicable)
- [ ] CI passes
- [ ] No performance regressions

### Review Process

1. Create PR with detailed description
2. Request review from relevant maintainers:
   - Zig: @zig-maintainer
   - Mojo: @mojo-maintainer
   - Mangle: @mangle-maintainer
3. Address feedback
4. Squash and merge

## Daily Tracking

### Creating Daily Reports

Update `tracking/daily/weekXX/dayY.md`:

```markdown
# Day Y - Week XX - Phase Z
**Date**: YYYY-MM-DD
**Engineer**: Your Name

## 🎯 Objectives
- [ ] Task 1
- [ ] Task 2

## 📝 Work Log
### 09:00-12:00 - Morning Session
- Implemented feature X
- Fixed bug Y

### 13:00-17:00 - Afternoon Session
- Code review
- Testing

## 🔢 Metrics
| Metric | Value |
|--------|-------|
| Lines written | 450 |
| Tests added | 12 |
| Test coverage | 85% |

## 🚧 Blockers
- None / [Description]

## 📋 Tomorrow's Plan
- Continue feature X
- Start feature Z
```

### Weekly Summaries

Update `tracking/weekly/weekXX.md` every Friday.

## Testing

### Zig Tests

```bash
# Run all tests
cd zig && zig build test

# Run specific test file
zig test src/engine/request_test.zig

# Run with verbose output
zig build test -- --verbose
```

### Mojo Tests

```bash
# Run all tests
cd mojo && mojo test

# Run specific test
mojo test tests/layers_test.mojo
```

### Mangle Rule Verification

```bash
# Check rule syntax
mangle check config/*.mg

# Run rule tests
mangle test config/model_config_test.mg
```

### Integration Tests

```bash
# Run end-to-end tests
cd tests/e2e && ./run_tests.sh

# Run benchmarks
cd tests/benchmark && ./benchmark.sh
```

## Performance Guidelines

### Benchmarking

Before submitting performance-critical changes:

```bash
# Run baseline benchmark
./tools/benchmarks/run_baseline.sh > baseline.txt

# Make changes, then:
./tools/benchmarks/run_baseline.sh > current.txt

# Compare
diff baseline.txt current.txt
```

### Memory Profiling

```bash
# Zig memory profiling
zig build -Doptimize=Debug
valgrind --tool=memcheck ./zig-out/bin/vllm

# Check for leaks
valgrind --leak-check=full ./zig-out/bin/vllm
```

## Getting Help

- **Zig Questions**: [Zig Discord](https://discord.gg/zig)
- **Mojo Questions**: [Mojo Discord](https://discord.gg/modular)
- **Project Questions**: Open a GitHub Discussion

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.