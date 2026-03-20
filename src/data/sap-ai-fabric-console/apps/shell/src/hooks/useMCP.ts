/**
 * MCP Hooks for SAP AI Fabric Console
 * 
 * React hooks for connecting to backend MCP services:
 * - LangChain HANA MCP (port 9140)
 * - AI Core Streaming MCP (port 9190)
 */

import { useState, useEffect, useCallback, useRef } from 'react';

// =============================================================================
// Configuration
// =============================================================================

const MCP_CONFIG = {
  langchain: import.meta.env.VITE_LANGCHAIN_MCP_URL || 'http://localhost:9140/mcp',
  streaming: import.meta.env.VITE_STREAMING_MCP_URL || 'http://localhost:9190/mcp',
  authToken: import.meta.env.VITE_MCP_AUTH_TOKEN || '',
};

// =============================================================================
// Types
// =============================================================================

interface MCPRequest {
  jsonrpc: '2.0';
  id: number;
  method: string;
  params: Record<string, unknown>;
}

interface MCPToolResult {
  content: Array<{ type: string; text: string }>;
}

export interface ServiceHealth {
  status: 'healthy' | 'degraded' | 'error';
  service: string;
  timestamp?: string;
  config_ready?: boolean;
  error?: string;
}

export interface Deployment {
  id: string;
  status: string;
  details?: Record<string, unknown>;
  targetStatus?: string;
  scenarioId?: string;
  creationTime?: string;
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

export interface VectorStore {
  table_name: string;
  embedding_model: string;
  documents_added: number;
  status?: string;
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

// =============================================================================
// Helper Functions
// =============================================================================

let requestId = 0;

async function mcpRequest<T>(
  endpoint: string,
  method: string,
  params: Record<string, unknown> = {}
): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  if (MCP_CONFIG.authToken) {
    headers['Authorization'] = `Bearer ${MCP_CONFIG.authToken}`;
  }

  const request: MCPRequest = {
    jsonrpc: '2.0',
    id: ++requestId,
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

  const data = await response.json();

  if (data.error) {
    throw new Error(`MCP Error ${data.error.code}: ${data.error.message}`);
  }

  return data.result;
}

async function callTool<T>(endpoint: string, toolName: string, args: Record<string, unknown>): Promise<T> {
  const result = await mcpRequest<MCPToolResult>(endpoint, 'tools/call', {
    name: toolName,
    arguments: args,
  });
  const text = result.content?.[0]?.text;
  return text ? JSON.parse(text) : result;
}

// =============================================================================
// Health Check Hook
// =============================================================================

export function useMCPHealth(pollInterval = 30000) {
  const [health, setHealth] = useState<{
    langchain: ServiceHealth | null;
    streaming: ServiceHealth | null;
    overall: 'healthy' | 'degraded' | 'error' | 'unknown';
  }>({
    langchain: null,
    streaming: null,
    overall: 'unknown',
  });
  const [loading, setLoading] = useState(true);

  const checkHealth = useCallback(async () => {
    const results: {
      langchain: ServiceHealth | null;
      streaming: ServiceHealth | null;
    } = { langchain: null, streaming: null };

    // Check LangChain MCP
    try {
      const lcEndpoint = MCP_CONFIG.langchain.replace('/mcp', '/health');
      const lcResponse = await fetch(lcEndpoint);
      results.langchain = await lcResponse.json();
    } catch (err) {
      results.langchain = {
        status: 'error',
        service: 'langchain-hana-mcp',
        error: err instanceof Error ? err.message : 'Connection failed',
      };
    }

    // Check Streaming MCP
    try {
      const stEndpoint = MCP_CONFIG.streaming.replace('/mcp', '/health');
      const stResponse = await fetch(stEndpoint);
      results.streaming = await stResponse.json();
    } catch (err) {
      results.streaming = {
        status: 'error',
        service: 'ai-core-streaming-mcp',
        error: err instanceof Error ? err.message : 'Connection failed',
      };
    }

    // Calculate overall status
    let overall: 'healthy' | 'degraded' | 'error' | 'unknown' = 'unknown';
    if (results.langchain?.status === 'healthy' && results.streaming?.status === 'healthy') {
      overall = 'healthy';
    } else if (results.langchain?.status === 'error' && results.streaming?.status === 'error') {
      overall = 'error';
    } else if (results.langchain || results.streaming) {
      overall = 'degraded';
    }

    setHealth({ ...results, overall });
    setLoading(false);
  }, []);

  useEffect(() => {
    checkHealth();
    const interval = setInterval(checkHealth, pollInterval);
    return () => clearInterval(interval);
  }, [checkHealth, pollInterval]);

  return { health, loading, refresh: checkHealth };
}

// =============================================================================
// Deployments Hook
// =============================================================================

export function useDeployments() {
  const [deployments, setDeployments] = useState<Deployment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchDeployments = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await callTool<{ resources?: Deployment[]; error?: string }>(
        MCP_CONFIG.streaming,
        'list_deployments',
        {}
      );
      if (result.error) {
        setError(result.error);
        setDeployments([]);
      } else {
        setDeployments(result.resources || []);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch deployments');
      setDeployments([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchDeployments();
  }, [fetchDeployments]);

  return { deployments, loading, error, refresh: fetchDeployments };
}

// =============================================================================
// Streams Hook
// =============================================================================

export function useStreams() {
  const [streams, setStreams] = useState<StreamSession[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchStreams = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await callTool<{ active_streams?: StreamSession[]; count?: number; error?: string }>(
        MCP_CONFIG.streaming,
        'stream_status',
        {}
      );
      if (result.error) {
        setError(result.error);
        setStreams([]);
      } else {
        setStreams(result.active_streams || []);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch streams');
      setStreams([]);
    } finally {
      setLoading(false);
    }
  }, []);

  const startStream = useCallback(async (deploymentId: string, config: Record<string, unknown> = {}) => {
    try {
      const result = await callTool<{ stream_id: string; status: string }>(
        MCP_CONFIG.streaming,
        'start_stream',
        { deployment_id: deploymentId, config: JSON.stringify(config) }
      );
      await fetchStreams();
      return result;
    } catch (err) {
      throw err;
    }
  }, [fetchStreams]);

  const stopStream = useCallback(async (streamId: string) => {
    try {
      const result = await callTool<{ stream_id: string; status: string }>(
        MCP_CONFIG.streaming,
        'stop_stream',
        { stream_id: streamId }
      );
      await fetchStreams();
      return result;
    } catch (err) {
      throw err;
    }
  }, [fetchStreams]);

  useEffect(() => {
    fetchStreams();
  }, [fetchStreams]);

  return { streams, loading, error, refresh: fetchStreams, startStream, stopStream };
}

// =============================================================================
// Vector Stores Hook
// =============================================================================

export function useVectorStores() {
  const [stores, setStores] = useState<VectorStore[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchStores = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      // Query Mangle for vector store facts
      const result = await callTool<{ predicate: string; results: VectorStore[] }>(
        MCP_CONFIG.langchain,
        'mangle_query',
        { predicate: 'vector_stores', args: '[]' }
      );
      setStores(result.results || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch vector stores');
      setStores([]);
    } finally {
      setLoading(false);
    }
  }, []);

  const createStore = useCallback(async (tableName: string, embeddingModel = 'default') => {
    try {
      const result = await callTool<VectorStore>(
        MCP_CONFIG.langchain,
        'langchain_vector_store',
        { table_name: tableName, embedding_model: embeddingModel }
      );
      await fetchStores();
      return result;
    } catch (err) {
      throw err;
    }
  }, [fetchStores]);

  useEffect(() => {
    fetchStores();
  }, [fetchStores]);

  return { stores, loading, error, refresh: fetchStores, createStore };
}

// =============================================================================
// RAG Hook
// =============================================================================

export function useRAG(tableName?: string) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<RAGResult | null>(null);

  const query = useCallback(async (queryText: string, k = 4, table?: string) => {
    const targetTable = table || tableName;
    if (!targetTable) {
      setError('No table name specified');
      return null;
    }

    setLoading(true);
    setError(null);
    try {
      const ragResult = await callTool<RAGResult>(
        MCP_CONFIG.langchain,
        'langchain_rag_chain',
        { query: queryText, table_name: targetTable, k }
      );
      setResult(ragResult);
      return ragResult;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'RAG query failed');
      return null;
    } finally {
      setLoading(false);
    }
  }, [tableName]);

  const search = useCallback(async (queryText: string, k = 4, table?: string) => {
    const targetTable = table || tableName;
    if (!targetTable) {
      setError('No table name specified');
      return null;
    }

    setLoading(true);
    setError(null);
    try {
      const searchResult = await callTool<{ results: unknown[]; status: string }>(
        MCP_CONFIG.langchain,
        'langchain_similarity_search',
        { table_name: targetTable, query: queryText, k }
      );
      return searchResult;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Similarity search failed');
      return null;
    } finally {
      setLoading(false);
    }
  }, [tableName]);

  const addDocuments = useCallback(async (documents: string[], metadatas?: Record<string, unknown>[], table?: string) => {
    const targetTable = table || tableName;
    if (!targetTable) {
      setError('No table name specified');
      return false;
    }

    setLoading(true);
    setError(null);
    try {
      await callTool(
        MCP_CONFIG.langchain,
        'langchain_add_documents',
        {
          table_name: targetTable,
          documents: JSON.stringify(documents),
          metadatas: metadatas ? JSON.stringify(metadatas) : undefined,
        }
      );
      return true;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Add documents failed');
      return false;
    } finally {
      setLoading(false);
    }
  }, [tableName]);

  return { query, search, addDocuments, loading, error, result };
}

// =============================================================================
// Chat Hook
// =============================================================================

export function useChat() {
  const [messages, setMessages] = useState<Array<{ role: string; content: string }>>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const sendMessage = useCallback(async (content: string, maxTokens = 1024) => {
    const userMessage = { role: 'user', content };
    const newMessages = [...messages, userMessage];
    setMessages(newMessages);
    setLoading(true);
    setError(null);

    try {
      const result = await callTool<{ content: string; model: string }>(
        MCP_CONFIG.langchain,
        'langchain_chat',
        { messages: JSON.stringify(newMessages), max_tokens: maxTokens }
      );
      
      const assistantMessage = { role: 'assistant', content: result.content };
      setMessages([...newMessages, assistantMessage]);
      return result;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Chat failed');
      return null;
    } finally {
      setLoading(false);
    }
  }, [messages]);

  const streamingChat = useCallback(async (content: string, maxTokens = 1024) => {
    const userMessage = { role: 'user', content };
    const newMessages = [...messages, userMessage];
    setMessages(newMessages);
    setLoading(true);
    setError(null);

    try {
      const result = await callTool<{ content: string; model: string; streaming: boolean }>(
        MCP_CONFIG.streaming,
        'streaming_chat',
        { messages: JSON.stringify(newMessages), max_tokens: maxTokens }
      );
      
      const assistantMessage = { role: 'assistant', content: result.content };
      setMessages([...newMessages, assistantMessage]);
      return result;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Streaming chat failed');
      return null;
    } finally {
      setLoading(false);
    }
  }, [messages]);

  const clearHistory = useCallback(() => {
    setMessages([]);
    setError(null);
  }, []);

  return { messages, sendMessage, streamingChat, clearHistory, loading, error };
}

// =============================================================================
// KùzuDB Graph Hook
// =============================================================================

export function useKuzuGraph() {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const query = useCallback(async (cypher: string, params?: Record<string, unknown>) => {
    setLoading(true);
    setError(null);
    try {
      const result = await callTool<{ rows: unknown[]; rowCount: number }>(
        MCP_CONFIG.langchain,
        'kuzu_query',
        { cypher, params: params ? JSON.stringify(params) : undefined }
      );
      return result;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Graph query failed');
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  const index = useCallback(async (entities: {
    vector_stores?: unknown[];
    deployments?: unknown[];
    schemas?: unknown[];
  }) => {
    setLoading(true);
    setError(null);
    try {
      const result = await callTool<{ stores_indexed: number; deployments_indexed: number; schemas_indexed: number }>(
        MCP_CONFIG.langchain,
        'kuzu_index',
        {
          vector_stores: JSON.stringify(entities.vector_stores || []),
          deployments: JSON.stringify(entities.deployments || []),
          schemas: JSON.stringify(entities.schemas || []),
        }
      );
      return result;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Graph index failed');
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  return { query, index, loading, error };
}

// =============================================================================
// Dashboard Stats Hook (Combines multiple sources)
// =============================================================================

export function useDashboardStats() {
  const { health } = useMCPHealth(60000);
  const { deployments, loading: deploymentsLoading } = useDeployments();
  const { streams, loading: streamsLoading } = useStreams();
  const { stores, loading: storesLoading } = useVectorStores();

  const stats = {
    // Service health
    servicesHealthy: (health.langchain?.status === 'healthy' ? 1 : 0) + 
                     (health.streaming?.status === 'healthy' ? 1 : 0),
    totalServices: 2,
    
    // Deployments
    activeDeployments: deployments.filter(d => d.status === 'RUNNING' || d.status === 'active').length,
    totalDeployments: deployments.length,
    
    // Streams
    activeStreams: streams.filter(s => s.status === 'active').length,
    totalStreams: streams.length,
    
    // Vector stores
    vectorStores: stores.length,
    documentsIndexed: stores.reduce((sum, s) => sum + (s.documents_added || 0), 0),
    
    // Overall status
    overallHealth: health.overall,
  };

  const loading = deploymentsLoading || streamsLoading || storesLoading;

  return { stats, loading, health };
}