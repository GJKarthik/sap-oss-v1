# SAP OpenAI-Compatible Server for World Monitor

A full OpenAI-compatible HTTP server written in TypeScript for the World Monitor application, routing to SAP AI Core.

## Features

- **Full OpenAI API Compatibility** - All OpenAI endpoints supported
- **SAP AI Core Integration** - Routes to Claude 3.5 Sonnet and other models
- **TypeScript Native** - Fits the World Monitor tech stack
- **Zero Dependencies** - Uses only Node.js built-in modules
- **Assistants API** - Full Assistants v2 API support
- **Batches API** - Batch processing support

## Quick Start

```bash
# Install @types/node if needed
npm install --save-dev @types/node

# Run directly with tsx
npx tsx sap_openai_server/server.ts --port=8300

# Or compile and run
npx tsc -p sap_openai_server
node sap_openai_server/dist/server.js --port=8300
```

## Environment Variables

```bash
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
```

## Full OpenAI API Endpoints

### Core Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/models` | GET | List models |
| `/v1/models/{id}` | GET | Get model |
| `/v1/chat/completions` | POST | Chat completions |
| `/v1/embeddings` | POST | Embeddings |
| `/v1/completions` | POST | Legacy completions |
| `/v1/search` | POST | Semantic search |
| `/v1/files` | GET/POST | File management |
| `/v1/fine-tunes` | GET | List fine-tunes |

### Moderations & Media
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/moderations` | POST | Content moderation |
| `/v1/images/generations` | POST | Image generation (stub) |
| `/v1/audio/transcriptions` | POST | Audio transcription (stub) |
| `/v1/audio/translations` | POST | Audio translation (stub) |
| `/v1/audio/speech` | POST | Text-to-speech (stub) |

### Assistants API (v2)
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/assistants` | GET/POST | List/create assistants |
| `/v1/assistants/{id}` | GET/DELETE | Get/delete assistant |
| `/v1/threads` | POST | Create thread |
| `/v1/threads/{id}` | GET/DELETE | Get/delete thread |
| `/v1/threads/{id}/messages` | GET/POST | Messages |
| `/v1/threads/{id}/runs` | GET/POST | Runs |

### Batches API
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/batches` | GET/POST | List/create batches |
| `/v1/batches/{id}` | GET | Get batch |
| `/v1/batches/{id}/cancel` | POST | Cancel batch |

### Vector Store
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/hana/tables` | GET | List vector tables |
| `/v1/hana/vectors` | POST | Store vectors |
| `/v1/hana/search` | POST | Search vectors |

## Usage with OpenAI SDK

```typescript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'http://localhost:8300/v1',
  apiKey: 'any'
});

// Chat
const response = await client.chat.completions.create({
  model: 'claude-3.5-sonnet',
  messages: [{ role: 'user', content: 'Hello!' }]
});

// Assistants
const assistant = await client.beta.assistants.create({
  model: 'claude-3.5-sonnet',
  name: 'World Monitor Assistant'
});

const thread = await client.beta.threads.create();
await client.beta.threads.messages.create(thread.id, {
  role: 'user',
  content: 'What is the current world situation?'
});

const run = await client.beta.threads.runs.create(thread.id, {
  assistant_id: assistant.id
});
```

## Integration with World Monitor

Add to `package.json`:

```json
{
  "scripts": {
    "openai:server": "tsx sap_openai_server/server.ts --port=8300"
  }
}
```

## License

AGPL-3.0-only (same as World Monitor)