# vLLM Local Development Sample

This sample demonstrates how to use `@sap-ai-sdk/vllm` with a local vLLM server.

## Prerequisites

- Docker with NVIDIA Container Toolkit
- NVIDIA GPU with sufficient VRAM:
  - 8B model: ~16GB VRAM
  - 13B model: ~24GB VRAM
  - 70B model: ~80GB VRAM (or quantized ~40GB)
- Node.js 18+

## Quick Start

### 1. Start vLLM Server

```bash
# Start with default 8B model
docker-compose up -d

# Or start with smaller model (less VRAM)
docker-compose --profile small up -d

# Or start multiple models
docker-compose --profile multi up -d
```

### 2. Install Dependencies

```bash
npm install
# or
pnpm install
```

### 3. Run Examples

```bash
# Basic chat example
npm run basic

# Streaming example
npm run streaming

# Multi-model router example
npm run multi-model
```

## Examples

### Basic Chat (`src/basic-chat.ts`)

Demonstrates:
- Simple chat completion
- Multi-turn conversations
- Custom parameters (temperature, maxTokens)

```typescript
import { VllmChatClient } from '@sap-ai-sdk/vllm';

const client = new VllmChatClient({
  endpoint: 'http://localhost:8000',
  model: 'meta-llama/Llama-3.1-8B-Instruct',
});

const response = await client.chat([
  { role: 'user', content: 'Hello!' },
]);
```

### Streaming (`src/streaming.ts`)

Demonstrates:
- Async iterator streaming
- StreamBuilder with callbacks
- Collecting stream content

```typescript
const stream = await client.chatStream([
  { role: 'user', content: 'Tell me a story' },
]);

for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0].delta.content || '');
}
```

### Multi-Model Router (`src/multi-model.ts`)

Demonstrates:
- Routing requests to different models
- Task-based model selection
- Health monitoring
- Load balancing

```typescript
const router = new ModelRouter({
  defaultModel: 'general',
  loadBalanceStrategy: 'round-robin',
});

router.registerModel('general', generalClient);
router.registerModel('code', codeClient);
router.setTaskMapping('code', ['code-generation']);

const response = await router.chat(messages, { task: 'code-generation' });
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VLLM_ENDPOINT` | vLLM server URL | `http://localhost:8000` |
| `VLLM_MODEL` | Model identifier | `meta-llama/Llama-3.1-8B-Instruct` |
| `VLLM_API_KEY` | API key (optional) | - |
| `VLLM_CODE_ENDPOINT` | Code model endpoint | - |
| `HF_TOKEN` | Hugging Face token (for gated models) | - |

### Docker Compose Profiles

| Profile | Description | GPU Memory |
|---------|-------------|------------|
| (default) | Llama 3.1 8B | ~16GB |
| `small` | Phi-3 Mini | ~8GB |
| `multi` | Multiple models | ~32GB+ |

## Directory Structure

```
vllm-local/
├── docker-compose.yml    # vLLM server configuration
├── package.json          # Dependencies
├── README.md             # This file
└── src/
    ├── basic-chat.ts     # Basic usage example
    ├── streaming.ts      # Streaming example
    └── multi-model.ts    # Router example
```

## Troubleshooting

### Server Not Starting

```bash
# Check logs
docker-compose logs vllm

# Check GPU availability
nvidia-smi
```

### Out of Memory

Use a smaller model:
```bash
docker-compose --profile small up -d
```

Or use quantized model in `docker-compose.yml`:
```yaml
command: >
  --model meta-llama/Llama-3.1-8B-Instruct
  --quantization awq  # or gptq
```

### Connection Refused

Ensure the server is running and healthy:
```bash
curl http://localhost:8000/health
```

## License

Apache-2.0