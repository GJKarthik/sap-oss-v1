# SAP OpenAI-Compatible Server for UI5 Web Components NGX

A full OpenAI-compatible HTTP server for Angular/NX projects using UI5 Web Components.

## Features

- **Full OpenAI API Compatibility** - All standard OpenAI endpoints
- **SAP AI Core Integration** - Routes to Claude 3.5 Sonnet and other models
- **TypeScript Native** - Fits the Angular/NX tech stack
- **Assistants API** - Full Assistants v2 API support
- **Batches API** - Batch processing support

## Quick Start

```bash
# Run directly with ts-node
npx ts-node libs/openai-server/src/server.ts --port=8400

# Or compile and run
npx tsc -p libs/openai-server
node libs/openai-server/dist/server.js --port=8400
```

## Environment Variables

```bash
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
# Optional OCR hardening
export OPENAI_OCR_INTERNAL_TOKEN=your-ocr-internal-token
export OPENAI_OCR_MAX_UPLOAD_BYTES=5242880
export OPENAI_OCR_ALLOWED_MIME_TYPES=text/plain,application/pdf,image/png,image/jpeg,image/webp
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/models` | GET | List models |
| `/v1/chat/completions` | POST | Chat completions |
| `/v1/embeddings` | POST | Embeddings |
| `/v1/files` | GET/POST | File management |
| `/v1/moderations` | POST | Content moderation |
| `/v1/assistants` | GET/POST | Assistants |
| `/v1/threads` | POST | Threads |
| `/v1/batches` | GET/POST | Batches |
| `/v1/ocr/documents` | POST | OCR + invoice extraction contract |
| `/v1/ocr/documents` | GET | List OCR documents |
| `/v1/ocr/documents/:id` | GET | Retrieve OCR document result |
| `/v1/hana/tables` | GET | Vector tables |
| `/v1/hana/vectors` | POST | Store vectors |
| `/v1/hana/search` | POST | Search vectors |

### Arabic-first chat routing

If `model` is omitted on `/v1/chat/completions`, the server auto-selects the Arabic-focused
model alias `google/gemma-4-E4B-it` when either:

- `x-ui-language: ar` (or request body `language: "ar"`) is provided, or
- incoming message content includes Arabic script.

The alias resolves only when a matching Gemma deployment exists in AI Core. Otherwise the request
returns an explicit error instead of silently routing to another model.

## Usage with Angular Service

```typescript
import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class OpenAIService {
  private baseUrl = 'http://localhost:8400/v1';

  constructor(private http: HttpClient) {}

  chat(messages: Array<{ role: string; content: string }>) {
    return this.http.post(`${this.baseUrl}/chat/completions`, {
      model: 'claude-3.5-sonnet',
      messages
    });
  }
}
```

## NX Integration

Add to `project.json`:

```json
{
  "targets": {
    "serve:openai": {
      "executor": "nx:run-commands",
      "options": {
        "command": "npx ts-node libs/openai-server/src/server.ts --port=8400"
      }
    }
  }
}
```

## License

Apache-2.0 (same as UI5 Web Components NGX)