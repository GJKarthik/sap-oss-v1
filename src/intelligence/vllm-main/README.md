# AI Core Private LLM

Private LLM deployment service for on-premise and air-gapped environments.

## Features

- **Local Models**: Run LLaMA, Mistral, Gemma locally
- **GGUF Support**: Optimized GGUF model format
- **GPU Acceleration**: Metal (macOS), CUDA (Linux)
- **Quantization**: 4-bit, 8-bit quantized models
- **OpenAI Compatible**: Drop-in replacement API

## Supported Models

| Model | Parameters | VRAM Required |
|-------|------------|---------------|
| LLaMA 3.1 8B | 8B | 6GB |
| LLaMA 3.1 70B | 70B | 40GB |
| Mistral 7B | 7B | 5GB |
| Gemma 2B | 2B | 2GB |
| Phi-3 Mini | 3.8B | 3GB |

## Architecture

```
┌──────────────────────────────────────┐
│         OpenAI-Compatible API        │
│    (/v1/chat/completions, etc.)      │
└─────────────────┬────────────────────┘
                  │
┌─────────────────▼────────────────────┐
│         Request Router               │
│    (Model selection, load balance)   │
└─────────────────┬────────────────────┘
                  │
┌─────────────────▼────────────────────┐
│         Inference Engine             │
│    (llama.cpp / Metal / CUDA)        │
└─────────────────┬────────────────────┘
                  │
┌─────────────────▼────────────────────┐
│         Model Store                  │
│    (GGUF files on disk/S3)           │
└──────────────────────────────────────┘
```

## Quick Start

```bash
# Download a model
wget https://huggingface.co/TheBloke/Llama-2-7B-Chat-GGUF/resolve/main/llama-2-7b-chat.Q4_K_M.gguf \
  -O models/llama-2-7b.gguf

# Build and run
cd zig && zig build -Doptimize=ReleaseFast
./zig-out/bin/openai-gateway --model models/llama-2-7b.gguf

# Or use Docker
docker build -t privatellm:latest .
docker run -p 8080:8080 -v $(pwd)/models:/models privatellm:latest
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/chat/completions` | Chat completion |
| POST | `/v1/completions` | Text completion |
| POST | `/v1/embeddings` | Generate embeddings |
| GET | `/v1/models` | List available models |
| GET | `/health` | Health check |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8080 | Service port |
| `MODEL_PATH` | /models | Model directory |
| `DEFAULT_MODEL` | llama-2-7b | Default model |
| `CONTEXT_SIZE` | 4096 | Context window size |
| `GPU_LAYERS` | -1 | Layers to offload (-1 = all) |
| `THREADS` | 8 | CPU threads |

## Usage Example

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-2-7b",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'