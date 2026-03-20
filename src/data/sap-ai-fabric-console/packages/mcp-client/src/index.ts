/**
 * SAP AI Fabric Console - MCP Client
 * 
 * Unified client for connecting to existing MCP backend services:
 * - LangChain HANA MCP (port 9140) - Vector store, RAG, embeddings
 * - AI Core Streaming MCP (port 9190) - Streaming inference
 */

// =============================================================================
// Configuration
// =============================================================================

export interface MCPConfig {
  langchainEndpoint: string;
  streamingEndpoint: string;
  authToken?: string;
}

const defaultConfig: MCPConfig = {
  langchainEndpoint: import.meta.env.VITE_LANGCHAIN_MCP_URL || 'http://localhost:9140/mcp',
  streamingEndpoint: import.meta.env.VITE_STREAMING_MCP_URL || 'http://localhost:9190/mcp',
  authToken: import.meta.env.VITE_MCP_AUTH_TOKEN,
};

// =============================================================================
// Types
// =============================================================================

export interface MCPRequest {
  jsonrpc: '2.0';
  id: number | string;
  method: string;
  params: Record<string, unknown>;
}

export interface MCPResponse<T = unknown> {
  jsonrpc: '2.0';
  id: number | string;
  result?: T;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export interface Tool {
  name: string;
  description: string;
  inputSchema: {
    type: 'object';
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export interface Resource {
  uri: string;
  name: string;
  description: string;
  mimeType: string;
}

// LangChain HANA Types
export interface VectorStore {
  table_name: string;
  embedding_model: string;
  documents_added: number;
}

export interface RAGResult {
  query: string;
  table_name: string;
  context_docs: unknown[];
  answer: string;
  status: string;
  source?: string;
  graphContext?: unknown;
}

export interface SimilaritySearchResult {
  table_name: string;
  query: string;
  k: number;
  results: unknown[];
  status: string;
}

// Streaming Types
export interface Deployment {
  id: string;
  details: Record<string, unknown>;
  status: string;
}

export interface StreamSession {
  stream_id: string;
  deployment_id: string;
  status: string;
  config: Record<string, unknown>;
  events: unknown[];
  started_at: number;
  graph_context?: unknown;
}

// =============================================================================
// MCP Client Class
// =============================================================================

export class MCPClient {
  private config: MCPConfig;
  private requestId = 0;

  constructor(config: Partial<MCPConfig> = {}) {
    this.config = { ...defaultConfig, ...config };
  }

  /**
   * Make a JSON-RPC request to an MCP endpoint
   */
  private async request<T>(
    endpoint: string,
    method: string,
    params: Record<string, unknown> = {}
  ): Promise<T> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    if (this.config.authToken) {
      headers['Authorization'] = `Bearer ${this.config.authToken}`;
    }

    const request: MCPRequest = {
      jsonrpc: '2.0',
      id: ++this.requestId,
      method,
      params,
    };

    const response = await fetch(endpoint, {
      method: 'POST',
      headers,
      body: JSON.stringify(request),
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const data = (await response.json()) as MCPResponse<T>;

    if (data.error) {
      throw new Error(`MCP Error ${data.error.code}: ${data.error.message}`);
    }

    return data.result as T;
  }

  // ===========================================================================
  // LangChain HANA MCP Methods
  // ===========================================================================

  /**
   * List available tools from LangChain MCP
   */
  async listLangchainTools(): Promise<Tool[]> {
    const result = await this.request<{ tools: Tool[] }>(
      this.config.langchainEndpoint,
      'tools/list'
    );
    return result.tools;
  }

  /**
   * Create or get a HANA vector store
   */
  async createVectorStore(tableName: string, embeddingModel = 'default'): Promise<VectorStore> {
    return this.callLangchainTool('langchain_vector_store', {
      table_name: tableName,
      embedding_model: embeddingModel,
    });
  }

  /**
   * Add documents to a vector store
   */
  async addDocuments(
    tableName: string,
    documents: string[],
    metadatas?: Record<string, unknown>[]
  ): Promise<{ documents_added: number; status: string }> {
    return this.callLangchainTool('langchain_add_documents', {
      table_name: tableName,
      documents: JSON.stringify(documents),
      metadatas: metadatas ? JSON.stringify(metadatas) : undefined,
    });
  }

  /**
   * Similarity search in a vector store
   */
  async similaritySearch(
    tableName: string,
    query: string,
    k = 4,
    filter?: Record<string, unknown>
  ): Promise<SimilaritySearchResult> {
    return this.callLangchainTool('langchain_similarity_search', {
      table_name: tableName,
      query,
      k,
      filter: filter ? JSON.stringify(filter) : undefined,
    });
  }

  /**
   * Run RAG chain with HANA retriever
   */
  async runRAGChain(query: string, tableName: string, k = 4): Promise<RAGResult> {
    return this.callLangchainTool('langchain_rag_chain', {
      query,
      table_name: tableName,
      k,
    });
  }

  /**
   * Generate embeddings
   */
  async generateEmbeddings(texts: string[], model?: string): Promise<unknown> {
    return this.callLangchainTool('langchain_embeddings', {
      texts: JSON.stringify(texts),
      model,
    });
  }

  /**
   * Chat completion via LangChain
   */
  async chat(
    messages: Array<{ role: string; content: string }>,
    maxTokens = 1024
  ): Promise<{ content: string; model: string }> {
    return this.callLangchainTool('langchain_chat', {
      messages: JSON.stringify(messages),
      max_tokens: maxTokens,
    });
  }

  /**
   * Query Mangle reasoning engine (LangChain)
   */
  async mangleQuery(
    predicate: string,
    args: unknown[] = []
  ): Promise<{ predicate: string; results: unknown[] }> {
    return this.callLangchainTool('mangle_query', {
      predicate,
      args: JSON.stringify(args),
    });
  }

  /**
   * Index entities into KùzuDB (LangChain)
   */
  async kuzuIndex(params: {
    vector_stores?: unknown[];
    deployments?: unknown[];
    schemas?: unknown[];
  }): Promise<{ stores_indexed: number; deployments_indexed: number; schemas_indexed: number }> {
    return this.callLangchainTool('kuzu_index', {
      vector_stores: JSON.stringify(params.vector_stores || []),
      deployments: JSON.stringify(params.deployments || []),
      schemas: JSON.stringify(params.schemas || []),
    });
  }

  /**
   * Query KùzuDB graph (LangChain)
   */
  async kuzuQuery(
    cypher: string,
    params?: Record<string, unknown>
  ): Promise<{ rows: unknown[]; rowCount: number }> {
    return this.callLangchainTool('kuzu_query', {
      cypher,
      params: params ? JSON.stringify(params) : undefined,
    });
  }

  private async callLangchainTool<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const result = await this.request<{ content: Array<{ type: string; text: string }> }>(
      this.config.langchainEndpoint,
      'tools/call',
      { name, arguments: args }
    );
    const text = result.content?.[0]?.text;
    return text ? JSON.parse(text) : result;
  }

  // ===========================================================================
  // AI Core Streaming MCP Methods
  // ===========================================================================

  /**
   * List available tools from Streaming MCP
   */
  async listStreamingTools(): Promise<Tool[]> {
    const result = await this.request<{ tools: Tool[] }>(
      this.config.streamingEndpoint,
      'tools/list'
    );
    return result.tools;
  }

  /**
   * List AI Core deployments
   */
  async listDeployments(): Promise<{ resources: Deployment[] }> {
    return this.callStreamingTool('list_deployments', {});
  }

  /**
   * Streaming chat completion
   */
  async streamingChat(
    messages: Array<{ role: string; content: string }>,
    maxTokens = 1024
  ): Promise<{ content: string; model: string; streaming: boolean }> {
    return this.callStreamingTool('streaming_chat', {
      messages: JSON.stringify(messages),
      max_tokens: maxTokens,
    });
  }

  /**
   * Streaming text generation
   */
  async streamingGenerate(
    prompt: string,
    maxTokens = 256
  ): Promise<unknown> {
    return this.callStreamingTool('streaming_generate', {
      prompt,
      max_tokens: maxTokens,
    });
  }

  /**
   * Start a streaming session
   */
  async startStream(
    deploymentId: string,
    config: Record<string, unknown> = {}
  ): Promise<{ stream_id: string; status: string }> {
    return this.callStreamingTool('start_stream', {
      deployment_id: deploymentId,
      config: JSON.stringify(config),
    });
  }

  /**
   * Stop a streaming session
   */
  async stopStream(streamId: string): Promise<{ stream_id: string; status: string }> {
    return this.callStreamingTool('stop_stream', {
      stream_id: streamId,
    });
  }

  /**
   * Get stream status
   */
  async getStreamStatus(streamId?: string): Promise<StreamSession | { active_streams: StreamSession[]; count: number }> {
    return this.callStreamingTool('stream_status', {
      stream_id: streamId,
    });
  }

  /**
   * Publish event to stream
   */
  async publishEvent(
    streamId: string,
    eventType: string,
    data: Record<string, unknown>
  ): Promise<{ stream_id: string; event: unknown; status: string }> {
    return this.callStreamingTool('publish_event', {
      stream_id: streamId,
      event_type: eventType,
      data: JSON.stringify(data),
    });
  }

  /**
   * Index streaming entities into KùzuDB
   */
  async streamingKuzuIndex(params: {
    deployments?: unknown[];
    streams?: unknown[];
    routing_decisions?: unknown[];
  }): Promise<{ deployments_indexed: number; streams_indexed: number; decisions_indexed: number }> {
    return this.callStreamingTool('kuzu_index', {
      deployments: JSON.stringify(params.deployments || []),
      streams: JSON.stringify(params.streams || []),
      routing_decisions: JSON.stringify(params.routing_decisions || []),
    });
  }

  private async callStreamingTool<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const result = await this.request<{ content: Array<{ type: string; text: string }> }>(
      this.config.streamingEndpoint,
      'tools/call',
      { name, arguments: args }
    );
    const text = result.content?.[0]?.text;
    return text ? JSON.parse(text) : result;
  }

  // ===========================================================================
  // Health Checks
  // ===========================================================================

  /**
   * Check LangChain MCP health
   */
  async checkLangchainHealth(): Promise<{ status: string; service: string }> {
    const endpoint = this.config.langchainEndpoint.replace('/mcp', '/health');
    const response = await fetch(endpoint);
    return response.json();
  }

  /**
   * Check Streaming MCP health
   */
  async checkStreamingHealth(): Promise<{ status: string; service: string }> {
    const endpoint = this.config.streamingEndpoint.replace('/mcp', '/health');
    const response = await fetch(endpoint);
    return response.json();
  }

  /**
   * Check all services health
   */
  async checkAllHealth(): Promise<{
    langchain: { status: string; error?: string };
    streaming: { status: string; error?: string };
  }> {
    const [langchain, streaming] = await Promise.allSettled([
      this.checkLangchainHealth(),
      this.checkStreamingHealth(),
    ]);

    return {
      langchain:
        langchain.status === 'fulfilled'
          ? { status: langchain.value.status }
          : { status: 'error', error: (langchain as PromiseRejectedResult).reason?.message },
      streaming:
        streaming.status === 'fulfilled'
          ? { status: streaming.value.status }
          : { status: 'error', error: (streaming as PromiseRejectedResult).reason?.message },
    };
  }
}

// =============================================================================
// Singleton Instance
// =============================================================================

export const mcpClient = new MCPClient();

// =============================================================================
// React Hooks
// =============================================================================

import { useState, useEffect, useCallback } from 'react';

/**
 * Hook for using the MCP client
 */
export function useMCPClient(config?: Partial<MCPConfig>) {
  const [client] = useState(() => config ? new MCPClient(config) : mcpClient);
  return client;
}

/**
 * Hook for checking service health
 */
export function useMCPHealth() {
  const client = useMCPClient();
  const [health, setHealth] = useState<{
    langchain: { status: string; error?: string };
    streaming: { status: string; error?: string };
  } | null>(null);
  const [loading, setLoading] = useState(true);

  const checkHealth = useCallback(async () => {
    setLoading(true);
    try {
      const result = await client.checkAllHealth();
      setHealth(result);
    } catch (error) {
      setHealth({
        langchain: { status: 'error', error: 'Failed to check' },
        streaming: { status: 'error', error: 'Failed to check' },
      });
    } finally {
      setLoading(false);
    }
  }, [client]);

  useEffect(() => {
    checkHealth();
    const interval = setInterval(checkHealth, 30000); // Check every 30s
    return () => clearInterval(interval);
  }, [checkHealth]);

  return { health, loading, refresh: checkHealth };
}

/**
 * Hook for RAG operations
 */
export function useRAG(tableName: string) {
  const client = useMCPClient();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const query = useCallback(
    async (queryText: string, k = 4): Promise<RAGResult | null> => {
      setLoading(true);
      setError(null);
      try {
        const result = await client.runRAGChain(queryText, tableName, k);
        return result;
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Query failed');
        return null;
      } finally {
        setLoading(false);
      }
    },
    [client, tableName]
  );

  const search = useCallback(
    async (queryText: string, k = 4): Promise<SimilaritySearchResult | null> => {
      setLoading(true);
      setError(null);
      try {
        const result = await client.similaritySearch(tableName, queryText, k);
        return result;
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Search failed');
        return null;
      } finally {
        setLoading(false);
      }
    },
    [client, tableName]
  );

  const addDocs = useCallback(
    async (documents: string[], metadatas?: Record<string, unknown>[]): Promise<boolean> => {
      setLoading(true);
      setError(null);
      try {
        await client.addDocuments(tableName, documents, metadatas);
        return true;
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Add documents failed');
        return false;
      } finally {
        setLoading(false);
      }
    },
    [client, tableName]
  );

  return { query, search, addDocs, loading, error };
}

/**
 * Hook for streaming chat
 */
export function useStreamingChat() {
  const client = useMCPClient();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const chat = useCallback(
    async (messages: Array<{ role: string; content: string }>, maxTokens = 1024) => {
      setLoading(true);
      setError(null);
      try {
        const result = await client.streamingChat(messages, maxTokens);
        return result;
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Chat failed');
        return null;
      } finally {
        setLoading(false);
      }
    },
    [client]
  );

  return { chat, loading, error };
}

/**
 * Hook for deployments
 */
export function useDeployments() {
  const client = useMCPClient();
  const [deployments, setDeployments] = useState<Deployment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchDeployments = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await client.listDeployments();
      setDeployments(result.resources || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch deployments');
    } finally {
      setLoading(false);
    }
  }, [client]);

  useEffect(() => {
    fetchDeployments();
  }, [fetchDeployments]);

  return { deployments, loading, error, refresh: fetchDeployments };
}

export default MCPClient;