/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_LANGCHAIN_MCP_URL: string;
  readonly VITE_STREAMING_MCP_URL: string;
  readonly VITE_MCP_AUTH_TOKEN: string;
  readonly VITE_HANA_HOST: string;
  readonly VITE_HANA_PORT: string;
  readonly VITE_HANA_USER: string;
  readonly VITE_HANA_PASSWORD: string;
  readonly VITE_AICORE_BASE_URL: string;
  readonly VITE_AICORE_RESOURCE_GROUP: string;
  readonly VITE_ENABLE_RAG: string;
  readonly VITE_ENABLE_STREAMING: string;
  readonly VITE_ENABLE_KUZU_GRAPH: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}