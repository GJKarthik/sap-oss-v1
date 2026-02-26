#!/usr/bin/env node
/**
 * SAP OpenAI-Compatible Server CLI
 * 
 * Start the server with: npx sap-openai-server
 * Or: node dist/cli.js
 */

import { createServer } from './server';
import * as dotenv from 'dotenv';
import * as path from 'path';

// Load environment variables
dotenv.config({ path: path.join(__dirname, '../../../tests/btp-integration/.env') });
dotenv.config({ path: path.join(__dirname, '../.env') });
dotenv.config();

const PORT = parseInt(process.env.PORT || '3000', 10);

const app = createServer({
  port: PORT,
  defaultChatModel: process.env.AICORE_CHAT_DEPLOYMENT_ID,
  apiKey: process.env.OPENAI_API_KEY,
});

app.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║       SAP OpenAI-Compatible Server                       ║
║       Powered by SAP AI Core                             ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://localhost:${PORT}

Endpoints:
  GET  /health              - Health check
  GET  /v1/models           - List available models
  GET  /v1/models/:id       - Get model details
  POST /v1/chat/completions - Chat completions (streaming supported)
  POST /v1/embeddings       - Generate embeddings
  POST /v1/completions      - Legacy completions

Example usage with curl:
  curl http://localhost:${PORT}/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -d '{"model": "claude-3.5-sonnet", "messages": [{"role": "user", "content": "Hello!"}]}'

Example usage with OpenAI Python SDK:
  from openai import OpenAI
  client = OpenAI(base_url="http://localhost:${PORT}/v1", api_key="any")
  response = client.chat.completions.create(
      model="claude-3.5-sonnet",
      messages=[{"role": "user", "content": "Hello!"}]
  )
`);
});