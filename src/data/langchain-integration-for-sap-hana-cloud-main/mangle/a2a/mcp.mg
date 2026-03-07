# ============================================================================
# LangChain HANA Integration - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for LangChain + HANA MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("langchain-chat",      "http://localhost:9140/mcp",  "claude-3.5-sonnet").
service_registry("langchain-vector",    "http://localhost:9140/mcp",  "hana-vector").
service_registry("langchain-rag",       "http://localhost:9140/mcp",  "rag-chain").
service_registry("langchain-embed",     "http://localhost:9140/mcp",  "text-embedding").

# 2. Intent Routing
resolve_service_for_intent(/chat, URL) :-
    service_registry("langchain-chat", URL, _).

resolve_service_for_intent(/vector, URL) :-
    service_registry("langchain-vector", URL, _).

resolve_service_for_intent(/rag, URL) :-
    service_registry("langchain-rag", URL, _).

resolve_service_for_intent(/embed, URL) :-
    service_registry("langchain-embed", URL, _).

# 3. Tool Routing
tool_service("langchain_chat", "langchain-chat").
tool_service("langchain_vector_store", "langchain-vector").
tool_service("langchain_add_documents", "langchain-vector").
tool_service("langchain_similarity_search", "langchain-vector").
tool_service("langchain_rag_chain", "langchain-rag").
tool_service("langchain_embeddings", "langchain-embed").
tool_service("langchain_load_documents", "langchain-rag").
tool_service("langchain_split_text", "langchain-rag").
tool_service("mangle_query", "langchain-chat").

# 4. Chain Configuration
chain_type("rag", "retrieval-augmented-generation").
chain_type("qa", "question-answering").
chain_type("summarize", "summarization").