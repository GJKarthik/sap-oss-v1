# Mangle Query Service - TypeScript Client

gRPC client for integrating with cap-llm-plugin or any Node.js/TypeScript service.

## Usage in cap-llm-plugin

```typescript
import { MangleClient } from '@sap-oss/mangle-query-client';

const mangle = new MangleClient({ address: 'localhost:50051' });

// Resolve a user query (80% handled without LLM)
const result = await mangle.resolve(
  'What is our return policy?',
  [],           // optional embeddings
  'req-12345'   // correlation ID
);

console.log(result.path);       // "cache", "factual", "rag", "llm", "llm_fallback"
console.log(result.answer);     // resolved answer
console.log(result.latencyMs);  // resolution latency

// Notify of entity changes (CDC)
await mangle.syncEntity('orders', 'PO-123', 'update', '{"status":"delivered"}');

// Health check
const health = await mangle.health();
```

## CDS Service Integration

```javascript
// srv/query-service.cds
service QueryService {
  action resolveQuery(query: String, correlationId: String) returns {
    answer: String; path: String; confidence: Decimal; latencyMs: Integer;
  };
}
```

```javascript
// srv/query-service.js
const { MangleClient } = require('@sap-oss/mangle-query-client');
const mangle = new MangleClient({ address: process.env.MQS_ADDRESS || 'localhost:50051' });

module.exports = (srv) => {
  srv.on('resolveQuery', async (req) => {
    const { query, correlationId } = req.data;
    return mangle.resolve(query, [], correlationId);
  });
};
```
