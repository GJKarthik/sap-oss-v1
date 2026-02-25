# CAP LLM Plugin — Angular Client

Typed Angular HTTP client for the CAP LLM Plugin service.

## Generated from

- **Source:** `docs/api/openapi.yaml` (OpenAPI 3.0.3)
- **CDS definition:** `srv/llm-service.cds`

## Installation

Copy this directory into your Angular project or reference it via a path dependency:

```json
{
  "dependencies": {
    "@cap-llm-plugin/angular-client": "file:../cap-llm-plugin-main/generated/angular-client"
  }
}
```

## Usage

```typescript
import { CAPLLMPluginService } from '@cap-llm-plugin/angular-client';
import { firstValueFrom } from 'rxjs';

@Component({ /* ... */ })
export class ChatComponent {
  constructor(private llm: CAPLLMPluginService) {}

  async sendMessage(text: string) {
    const response = await firstValueFrom(
      this.llm.getChatCompletionWithConfig({
        config: { modelName: 'gpt-4o', resourceGroup: 'default' },
        messages: [{ role: 'user', content: text }],
      })
    );
    console.log(response);
  }
}
```

## Peer Dependencies

- `@angular/core` >= 17.0.0
- `@angular/common` >= 17.0.0
- `rxjs` >= 7.0.0

## Regeneration

From the cap-llm-plugin root:

```bash
npm run generate:client
```
