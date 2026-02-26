#!/usr/bin/env node
"use strict";
/**
 * SAP OpenAI-Compatible Server CLI
 *
 * Start the server with: npx sap-openai-server
 * Or: node dist/cli.js
 */
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
const server_1 = require("./server");
const dotenv = __importStar(require("dotenv"));
const path = __importStar(require("path"));
// Load environment variables
dotenv.config({ path: path.join(__dirname, '../../../tests/btp-integration/.env') });
dotenv.config({ path: path.join(__dirname, '../.env') });
dotenv.config();
const PORT = parseInt(process.env.PORT || '3000', 10);
const app = (0, server_1.createServer)({
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
//# sourceMappingURL=cli.js.map