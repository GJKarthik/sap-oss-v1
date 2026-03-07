# Local Models Proxy Server

A high-performance Zig HTTP server that provides OpenAI-compatible API endpoints and proxies requests to local LLM backends (Rust/llama.cpp) with Mangle prompt enhancement.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Client Applications                              │
│        (OpenAI SDK, LangChain, Open WebUI, AnythingLLM)             │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│               Zig Local Models Proxy (Port 8080)                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │  HTTP Server     │  │  Mangle Engine   │  │  Backend Client  │  │
│  │  Multi-threaded  │──│  Prompt Enhance  │──│  HTTP Forward    │  │
│  │  Streaming SSE   │  │  Context Inject  │  │  /v1/chat/...    │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  Rust LLM Backend (Port 3000)                        │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │  Axum Server     │  │  Model Registry  │  │  llama.cpp       │  │
│  │  OpenAI Compat   │──│  Template Engine │──│  Inference       │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Features

### OpenAI-Compatible Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion with streaming support |
| `/v1/completions` | POST | Legacy completions endpoint |
| `/v1/embeddings` | POST | Embeddings generation |
| `/v1/models` | GET | List available models |
| `/health` | GET | Health check |
| `/ready` | GET | Readiness check (with backend connectivity) |

### Mangle Prompt Enhancement

The Mangle engine automatically enhances prompts based on content analysis:

| Pattern | Action | Enhancement |
|---------|--------|-------------|
| "code" | inject_system | Add coding assistant context |
| "analyze" | inject_system | Add analyst context |
| "log" | inject_system | Add log analysis expert context |
| "json" | append_instruction | Add JSON formatting instruction |
| "summarize" | inject_system | Add summarization context |

## Building

```bash
# Build
zig build

# Build with optimizations
zig build -Doptimize=ReleaseFast

# Run
zig build run

# Run tests
zig build test
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Server bind address |
| `PORT` | `8080` | Server port |
| `BACKEND_URL` | `http://localhost:3000` | Rust backend URL |
| `BACKEND_TIMEOUT_MS` | `120000` | Backend request timeout |
| `API_KEY` | - | Optional API key for authentication |
| `DEFAULT_MODEL` | - | Default model if not specified |
| `DEFAULT_TEMPERATURE` | `0.7` | Default temperature |
| `DEFAULT_MAX_TOKENS` | `2048` | Default max tokens |
| `STREAMING_ENABLED` | `true` | Enable streaming support |
| `MANGLE_ENABLED` | `true` | Enable Mangle prompt enhancement |
| `LOG_LEVEL` | `info` | Log level (debug, info, warn, error) |

## Usage Examples

### Chat Completion

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "phi3-mini-4k-instruct",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ],
    "temperature": 0.7,
    "max_tokens": 100
  }'
```

### Streaming Chat Completion

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3-8b-instruct",
    "messages": [
      {"role": "user", "content": "Write a short poem about coding"}
    ],
    "stream": true
  }'
```

### List Models

```bash
curl http://localhost:8080/v1/models
```

### Health Check

```bash
curl http://localhost:8080/health
```

## Project Structure

```
zig/
├── build.zig           # Build configuration
├── README.md           # This file
└── src/
    ├── main.zig        # HTTP server and routing
    ├── config.zig      # Configuration management
    ├── openai.zig      # OpenAI API types
    ├── llm_backend.zig # Backend client
    └── mangle.zig      # Prompt enhancement engine
```

## Mangle Rules

The Mangle engine uses pattern matching to enhance prompts:

```zig
// Rule structure
const Rule = struct {
    pattern: []const u8,      // Pattern to match in user message
    action: RuleAction,       // inject_system, append_instruction, modify_temperature
    content: []const u8,      // Content to inject/append
};

// Custom rule example
try engine.addRule("custom", Rule{
    .pattern = "kubernetes",
    .action = .inject_system,
    .content = "You are a Kubernetes expert. Provide detailed YAML examples.",
});
```

## Integration with Open WebUI & AnythingLLM

Both platforms are compatible with this proxy:

```yaml
# Open WebUI configuration
OPENAI_API_BASE_URL: http://localhost:8080/v1
OPENAI_API_KEY: your-optional-key

# AnythingLLM configuration
LLM_PROVIDER: openai
OPENAI_BASE_PATH: http://localhost:8080/v1
```

## Performance

- **Zero-copy** request handling where possible
- **Multi-threaded** request processing
- **Streaming SSE** support for real-time responses
- **Small binary** size (~500KB optimized)
- **No GC pauses** - predictable latency

## Supported Models

Compatible with any model supported by the Rust backend:

- **Llama 3** (8B, 70B)
- **Phi-3** (mini, small, medium)
- **Qwen2** (7B, 72B)
- **Mistral** (7B, 8x7B)
- **ChatGLM** (6B)
- And more via llama.cpp GGUF format

## License

MIT