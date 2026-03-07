# SAP OpenAI-Compatible Server for OData Vocabularies

A full OpenAI-compatible HTTP server for the OData vocabularies project.

## Quick Start

```bash
node sap_openai_server/server.js --port=8500
```

## Environment Variables

```bash
export AICORE_CLIENT_ID=your-client-id
export AICORE_CLIENT_SECRET=your-client-secret
export AICORE_AUTH_URL=https://xxx.authentication.xxx.hana.ondemand.com/oauth/token
export AICORE_BASE_URL=https://api.ai.xxx.aws.ml.hana.ondemand.com
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/models` | GET | List models |
| `/v1/chat/completions` | POST | Chat completions |
| `/v1/embeddings` | POST | Embeddings |
| `/v1/files` | GET/POST | Files |
| `/v1/moderations` | POST | Moderation |
| `/v1/assistants` | GET/POST | Assistants |
| `/v1/threads` | POST | Threads |
| `/v1/batches` | GET/POST | Batches |
| `/v1/hana/tables` | GET | Vector tables |
| `/v1/hana/vectors` | POST | Store vectors |
| `/v1/hana/search` | POST | Search vectors |

## License

Apache-2.0