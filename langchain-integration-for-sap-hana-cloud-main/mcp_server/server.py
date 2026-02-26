"""
LangChain HANA Integration MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for LangChain + HANA Cloud operations.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
import urllib.error

# =============================================================================
# Types
# =============================================================================

class MCPRequest:
    def __init__(self, data: dict):
        self.jsonrpc = data.get("jsonrpc", "2.0")
        self.id = data.get("id")
        self.method = data.get("method", "")
        self.params = data.get("params", {})


class MCPResponse:
    def __init__(self, id: Any, result: Any = None, error: dict = None):
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error

    def to_dict(self) -> dict:
        d = {"jsonrpc": self.jsonrpc, "id": self.id}
        if self.error:
            d["error"] = self.error
        else:
            d["result"] = self.result
        return d


# =============================================================================
# AI Core Configuration
# =============================================================================

def get_config() -> dict:
    return {
        "client_id": os.environ.get("AICORE_CLIENT_ID", ""),
        "client_secret": os.environ.get("AICORE_CLIENT_SECRET", ""),
        "auth_url": os.environ.get("AICORE_AUTH_URL", ""),
        "base_url": os.environ.get("AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")),
        "resource_group": os.environ.get("AICORE_RESOURCE_GROUP", "default"),
    }


_cached_token = {"token": None, "expires_at": 0}


def get_access_token(config: dict) -> str:
    import time
    import base64
    if _cached_token["token"] and time.time() < _cached_token["expires_at"]:
        return _cached_token["token"]
    if not config["auth_url"]:
        return ""
    auth = base64.b64encode(f"{config['client_id']}:{config['client_secret']}".encode()).decode()
    req = urllib.request.Request(
        config["auth_url"],
        data=b"grant_type=client_credentials",
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode())
            _cached_token["token"] = result["access_token"]
            _cached_token["expires_at"] = time.time() + result.get("expires_in", 3600) - 60
            return result["access_token"]
    except:
        return ""


def aicore_request(config: dict, method: str, path: str, body: dict = None) -> Any:
    token = get_access_token(config)
    if not token:
        return {"error": "No AI Core token"}
    url = f"{config['base_url']}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Bearer {token}", "AI-Resource-Group": config["resource_group"], "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}


# =============================================================================
# MCP Server Implementation
# =============================================================================

class MCPServer:
    def __init__(self):
        self.tools = {}
        self.resources = {}
        self.facts = {}
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    def _register_tools(self):
        # LLM Chat
        self.tools["langchain_chat"] = {
            "name": "langchain_chat",
            "description": "Chat completion via LangChain + HANA",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "string", "description": "JSON array of messages [{role, content}]"},
                    "model": {"type": "string", "description": "Model ID"},
                    "max_tokens": {"type": "number", "description": "Maximum tokens"},
                },
                "required": ["messages"],
            },
        }

        # Vector Store
        self.tools["langchain_vector_store"] = {
            "name": "langchain_vector_store",
            "description": "Create or get HANA vector store for LangChain",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "embedding_model": {"type": "string", "description": "Embedding model to use"},
                },
                "required": ["table_name"],
            },
        }

        # Add Documents
        self.tools["langchain_add_documents"] = {
            "name": "langchain_add_documents",
            "description": "Add documents to HANA vector store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "documents": {"type": "string", "description": "JSON array of documents"},
                    "metadatas": {"type": "string", "description": "JSON array of metadata (optional)"},
                },
                "required": ["table_name", "documents"],
            },
        }

        # Similarity Search
        self.tools["langchain_similarity_search"] = {
            "name": "langchain_similarity_search",
            "description": "Similarity search in HANA vector store",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string", "description": "Vector table name"},
                    "query": {"type": "string", "description": "Search query"},
                    "k": {"type": "number", "description": "Number of results"},
                    "filter": {"type": "string", "description": "Metadata filter (JSON)"},
                },
                "required": ["table_name", "query"],
            },
        }

        # RAG Chain
        self.tools["langchain_rag_chain"] = {
            "name": "langchain_rag_chain",
            "description": "Run RAG chain with HANA retriever",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "User query"},
                    "table_name": {"type": "string", "description": "Vector table for retrieval"},
                    "k": {"type": "number", "description": "Number of context docs"},
                },
                "required": ["query", "table_name"],
            },
        }

        # Embeddings
        self.tools["langchain_embeddings"] = {
            "name": "langchain_embeddings",
            "description": "Generate embeddings using LangChain",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "texts": {"type": "string", "description": "JSON array of texts"},
                    "model": {"type": "string", "description": "Embedding model"},
                },
                "required": ["texts"],
            },
        }

        # Document Loader
        self.tools["langchain_load_documents"] = {
            "name": "langchain_load_documents",
            "description": "Load documents using LangChain loaders",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Document source (file path, URL)"},
                    "loader_type": {"type": "string", "description": "Loader type (pdf, web, text)"},
                },
                "required": ["source"],
            },
        }

        # Text Splitter
        self.tools["langchain_split_text"] = {
            "name": "langchain_split_text",
            "description": "Split text using LangChain text splitters",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to split"},
                    "chunk_size": {"type": "number", "description": "Chunk size"},
                    "chunk_overlap": {"type": "number", "description": "Overlap between chunks"},
                },
                "required": ["text"],
            },
        }

        # Mangle Query
        self.tools["mangle_query"] = {
            "name": "mangle_query",
            "description": "Query the Mangle reasoning engine",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "predicate": {"type": "string", "description": "Predicate to query"},
                    "args": {"type": "string", "description": "Arguments as JSON array"},
                },
                "required": ["predicate"],
            },
        }

    def _register_resources(self):
        self.resources["langchain://vectorstores"] = {
            "uri": "langchain://vectorstores",
            "name": "Vector Stores",
            "description": "Available HANA vector stores",
            "mimeType": "application/json",
        }
        self.resources["langchain://chains"] = {
            "uri": "langchain://chains",
            "name": "Chains",
            "description": "Available LangChain chains",
            "mimeType": "application/json",
        }
        self.resources["mangle://facts"] = {
            "uri": "mangle://facts",
            "name": "Mangle Facts",
            "description": "Mangle fact store",
            "mimeType": "application/json",
        }

    def _initialize_facts(self):
        self.facts["service_registry"] = [
            {"name": "langchain-chat", "endpoint": "lc://chat", "model": "claude-3.5-sonnet"},
            {"name": "langchain-vector", "endpoint": "lc://vector", "model": "hana-vector"},
            {"name": "langchain-rag", "endpoint": "lc://rag", "model": "rag-chain"},
            {"name": "langchain-embed", "endpoint": "lc://embed", "model": "text-embedding"},
        ]
        self.facts["tool_invocation"] = []
        self.facts["vector_stores"] = []

    # Tool Handlers
    def _handle_langchain_chat(self, args: dict) -> dict:
        config = get_config()
        messages = json.loads(args.get("messages", "[]"))
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        if not resources:
            return {"error": "No deployment available"}
        deployment = resources[0]
        is_anthropic = "anthropic" in str(deployment.get("details", {})).lower()
        self.facts["tool_invocation"].append({"tool": "langchain_chat", "deployment": deployment["id"], "timestamp": __import__("time").time()})
        if is_anthropic:
            result = aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/invoke", {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": args.get("max_tokens", 1024),
                "messages": messages,
            })
            return {"content": result.get("content", [{}])[0].get("text", ""), "model": deployment["id"]}
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/chat/completions", {"messages": messages, "max_tokens": args.get("max_tokens")})

    def _handle_langchain_vector_store(self, args: dict) -> dict:
        table_name = args.get("table_name", "")
        self.facts["vector_stores"].append({"table_name": table_name, "embedding_model": args.get("embedding_model", "default")})
        return {"table_name": table_name, "status": "created/retrieved", "note": "Connect to HANA Cloud for actual store"}

    def _handle_langchain_add_documents(self, args: dict) -> dict:
        docs = json.loads(args.get("documents", "[]"))
        return {"table_name": args.get("table_name", ""), "documents_added": len(docs), "status": "placeholder"}

    def _handle_langchain_similarity_search(self, args: dict) -> dict:
        return {"table_name": args.get("table_name", ""), "query": args.get("query", ""), "k": args.get("k", 4), "results": [], "status": "Connect to HANA Cloud"}

    def _handle_langchain_rag_chain(self, args: dict) -> dict:
        return {"query": args.get("query", ""), "table_name": args.get("table_name", ""), "context_docs": [], "answer": "RAG chain placeholder", "status": "Connect to HANA Cloud + LLM"}

    def _handle_langchain_embeddings(self, args: dict) -> dict:
        config = get_config()
        texts = json.loads(args.get("texts", "[]"))
        deployments = aicore_request(config, "GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        deployment = next((d for d in resources if "embed" in str(d.get("details", {})).lower()), resources[0] if resources else None)
        if not deployment:
            return {"error": "No embedding deployment"}
        return aicore_request(config, "POST", f"/v2/inference/deployments/{deployment['id']}/embeddings", {"input": texts})

    def _handle_langchain_load_documents(self, args: dict) -> dict:
        return {"source": args.get("source", ""), "loader_type": args.get("loader_type", "auto"), "documents": [], "status": "Document loading placeholder"}

    def _handle_langchain_split_text(self, args: dict) -> dict:
        text = args.get("text", "")
        chunk_size = args.get("chunk_size", 1000)
        overlap = args.get("chunk_overlap", 200)
        # Simple splitting placeholder
        chunks = [text[i:i+chunk_size] for i in range(0, len(text), chunk_size - overlap)] if text else []
        return {"chunks": len(chunks), "chunk_size": chunk_size, "overlap": overlap}

    def _handle_mangle_query(self, args: dict) -> dict:
        predicate = args.get("predicate", "")
        facts = self.facts.get(predicate)
        if facts:
            return {"predicate": predicate, "results": facts}
        return {"predicate": predicate, "results": [], "message": "Unknown predicate"}

    def handle_request(self, request: MCPRequest) -> MCPResponse:
        method = request.method
        params = request.params
        id = request.id

        try:
            if method == "initialize":
                return MCPResponse(id, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}, "prompts": {"listChanged": True}},
                    "serverInfo": {"name": "langchain-hana-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                handlers = {
                    "langchain_chat": self._handle_langchain_chat,
                    "langchain_vector_store": self._handle_langchain_vector_store,
                    "langchain_add_documents": self._handle_langchain_add_documents,
                    "langchain_similarity_search": self._handle_langchain_similarity_search,
                    "langchain_rag_chain": self._handle_langchain_rag_chain,
                    "langchain_embeddings": self._handle_langchain_embeddings,
                    "langchain_load_documents": self._handle_langchain_load_documents,
                    "langchain_split_text": self._handle_langchain_split_text,
                    "mangle_query": self._handle_mangle_query,
                }
                handler = handlers.get(tool_name)
                if not handler:
                    return MCPResponse(id, error={"code": -32602, "message": f"Unknown tool: {tool_name}"})
                result = handler(args)
                return MCPResponse(id, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]})

            elif method == "resources/list":
                return MCPResponse(id, {"resources": list(self.resources.values())})

            elif method == "resources/read":
                uri = params.get("uri", "")
                if uri == "mangle://facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts, indent=2)}]})
                if uri == "langchain://vectorstores":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts.get("vector_stores", []), indent=2)}]})
                return MCPResponse(id, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(id, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as e:
            return MCPResponse(id, error={"code": -32603, "message": str(e)})


# =============================================================================
# HTTP Server
# =============================================================================

mcp_server = MCPServer()


class MCPHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            from datetime import datetime, timezone
            response = {"status": "healthy", "service": "langchain-hana-mcp", "timestamp": datetime.now(timezone.utc).isoformat()}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Not found"}).encode())

    def do_POST(self):
        if self.path == "/mcp":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode()
            try:
                data = json.loads(body)
                request = MCPRequest(data)
                response = mcp_server.handle_request(request)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps(response.to_dict()).encode())
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Not found"}).encode())

    def log_message(self, format, *args):
        pass


def main():
    import sys
    port = 9140
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   LangChain HANA Integration MCP Server                  ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: langchain_chat, langchain_vector_store, langchain_add_documents,
       langchain_similarity_search, langchain_rag_chain, langchain_embeddings,
       langchain_load_documents, langchain_split_text, mangle_query

Resources: langchain://vectorstores, langchain://chains, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()