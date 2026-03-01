"""
Elasticsearch MCP Server

Model Context Protocol server with Mangle reasoning integration.
Provides tools for Elasticsearch search, indexing, and cluster management.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any
import urllib.request
import urllib.error

CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",")
    if o.strip()
]


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return CORS_ALLOWED_ORIGINS[0] if CORS_ALLOWED_ORIGINS else None


MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_SEARCH_SIZE = int(os.environ.get("MCP_MAX_SEARCH_SIZE", "100"))
MAX_KNN_K = int(os.environ.get("MCP_MAX_KNN_K", "100"))


def clamp_int(value: Any, default: int, min_value: int, max_value: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed < min_value:
        return min_value
    if parsed > max_value:
        return max_value
    return parsed


def parse_json_arg(value: Any, default: Any):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return default
    return value if value is not None else default

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
# Elasticsearch Configuration
# =============================================================================

def get_es_config() -> dict:
    return {
        "host": os.environ.get("ES_HOST", "http://localhost:9200"),
        "username": os.environ.get("ES_USERNAME", "elastic"),
        "password": os.environ.get("ES_PASSWORD", ""),
        "api_key": os.environ.get("ES_API_KEY", ""),
    }


def es_request(method: str, path: str, body: dict = None) -> Any:
    config = get_es_config()
    url = f"{config['host']}{path}"
    data = json.dumps(body).encode() if body else None
    
    headers = {"Content-Type": "application/json"}
    if config["api_key"]:
        headers["Authorization"] = f"ApiKey {config['api_key']}"
    elif config["password"]:
        import base64
        auth = base64.b64encode(f"{config['username']}:{config['password']}".encode()).decode()
        headers["Authorization"] = f"Basic {auth}"
    
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.reason}", "status_code": e.code}
    except Exception as e:
        return {"error": str(e)}


# =============================================================================
# AI Core Integration
# =============================================================================

def get_aicore_config() -> dict:
    return {
        "client_id": os.environ.get("AICORE_CLIENT_ID", ""),
        "client_secret": os.environ.get("AICORE_CLIENT_SECRET", ""),
        "auth_url": os.environ.get("AICORE_AUTH_URL", ""),
        "base_url": os.environ.get("AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")),
        "resource_group": os.environ.get("AICORE_RESOURCE_GROUP", "default"),
    }


def aicore_config_ready(config: dict) -> bool:
    return all(config.get(k) for k in ("client_id", "client_secret", "auth_url", "base_url"))


_cached_token = {"token": None, "expires_at": 0}


def get_aicore_token(config: dict) -> str:
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


def aicore_request(method: str, path: str, body: dict = None) -> Any:
    config = get_aicore_config()
    token = get_aicore_token(config)
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
        # Search
        self.tools["es_search"] = {
            "name": "es_search",
            "description": "Search Elasticsearch indices",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name or pattern"},
                    "query": {"type": "string", "description": "Query DSL as JSON"},
                    "size": {"type": "number", "description": "Number of results"},
                },
                "required": ["index"],
            },
        }

        # Vector Search (kNN)
        self.tools["es_vector_search"] = {
            "name": "es_vector_search",
            "description": "Perform kNN vector similarity search",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name"},
                    "field": {"type": "string", "description": "Vector field name"},
                    "query_vector": {"type": "string", "description": "Query vector as JSON array"},
                    "k": {"type": "number", "description": "Number of nearest neighbors"},
                },
                "required": ["index", "field", "query_vector"],
            },
        }

        # Index Document
        self.tools["es_index"] = {
            "name": "es_index",
            "description": "Index a document into Elasticsearch",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Target index"},
                    "document": {"type": "string", "description": "Document as JSON"},
                    "id": {"type": "string", "description": "Document ID (optional)"},
                },
                "required": ["index", "document"],
            },
        }

        # Cluster Health
        self.tools["es_cluster_health"] = {
            "name": "es_cluster_health",
            "description": "Get Elasticsearch cluster health",
            "inputSchema": {
                "type": "object",
                "properties": {},
            },
        }

        # Index Info
        self.tools["es_index_info"] = {
            "name": "es_index_info",
            "description": "Get information about indices",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name or pattern"},
                },
                "required": ["index"],
            },
        }

        # Generate Embedding
        self.tools["generate_embedding"] = {
            "name": "generate_embedding",
            "description": "Generate embedding vector using AI Core",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to embed"},
                },
                "required": ["text"],
            },
        }

        # AI Search (semantic)
        self.tools["ai_semantic_search"] = {
            "name": "ai_semantic_search",
            "description": "Semantic search using AI embeddings + Elasticsearch kNN",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "index": {"type": "string", "description": "Index name"},
                    "query": {"type": "string", "description": "Natural language query"},
                    "vector_field": {"type": "string", "description": "Vector field name"},
                    "k": {"type": "number", "description": "Number of results"},
                },
                "required": ["index", "query", "vector_field"],
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
        self.resources["es://cluster"] = {
            "uri": "es://cluster",
            "name": "Cluster Info",
            "description": "Elasticsearch cluster information",
            "mimeType": "application/json",
        }
        self.resources["es://indices"] = {
            "uri": "es://indices",
            "name": "Indices List",
            "description": "List of all indices",
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
            {"name": "es-search", "endpoint": "es://search", "model": "elasticsearch"},
            {"name": "es-vector", "endpoint": "es://vector", "model": "knn-search"},
            {"name": "ai-embed", "endpoint": "aicore://embed", "model": "text-embedding"},
        ]
        self.facts["tool_invocation"] = []

    # Tool Handlers
    def _handle_es_search(self, args: dict) -> dict:
        index = args.get("index", "*")
        query = parse_json_arg(args.get("query", '{"match_all": {}}'), {"match_all": {}})
        if not isinstance(query, dict):
            query = {"match_all": {}}
        size = clamp_int(args.get("size", 10), 10, 1, MAX_SEARCH_SIZE)
        body = {"query": query, "size": size}
        result = es_request("POST", f"/{index}/_search", body)
        self.facts["tool_invocation"].append({"tool": "es_search", "index": index, "timestamp": __import__("time").time()})
        return result

    def _handle_es_vector_search(self, args: dict) -> dict:
        index = args.get("index", "")
        field = args.get("field", "vector")
        query_vector = parse_json_arg(args.get("query_vector", "[]"), [])
        if not isinstance(query_vector, list):
            return {"error": "query_vector must be a JSON array"}
        k = clamp_int(args.get("k", 10), 10, 1, MAX_KNN_K)
        body = {"knn": {"field": field, "query_vector": query_vector, "k": k, "num_candidates": k * 2}}
        return es_request("POST", f"/{index}/_search", body)

    def _handle_es_index(self, args: dict) -> dict:
        index = args.get("index", "")
        document = parse_json_arg(args.get("document", "{}"), {})
        if not isinstance(document, dict):
            return {"error": "document must be a JSON object"}
        doc_id = args.get("id")
        if doc_id:
            return es_request("PUT", f"/{index}/_doc/{doc_id}", document)
        return es_request("POST", f"/{index}/_doc", document)

    def _handle_es_cluster_health(self, args: dict) -> dict:
        return es_request("GET", "/_cluster/health")

    def _handle_es_index_info(self, args: dict) -> dict:
        index = args.get("index", "*")
        return es_request("GET", f"/{index}")

    def _handle_generate_embedding(self, args: dict) -> dict:
        text = str(args.get("text", "") or "")
        if text.strip() == "":
            return {"error": "text is required"}
        deployments = aicore_request("GET", "/v2/lm/deployments")
        resources = deployments.get("resources", [])
        deployment = next((d for d in resources if "embed" in str(d.get("details", {})).lower()), resources[0] if resources else None)
        if not deployment:
            return {"error": "No embedding deployment"}
        result = aicore_request("POST", f"/v2/inference/deployments/{deployment['id']}/embeddings", {"input": [text]})
        return result

    def _handle_ai_semantic_search(self, args: dict) -> dict:
        index = args.get("index", "")
        query = args.get("query", "")
        vector_field = args.get("vector_field", "embedding")
        k = clamp_int(args.get("k", 10), 10, 1, MAX_KNN_K)
        
        # Generate embedding for query
        embed_result = self._handle_generate_embedding({"text": query})
        if "error" in embed_result:
            return embed_result
        
        embedding = embed_result.get("data", [{}])[0].get("embedding", [])
        if not embedding:
            return {"error": "Failed to generate embedding"}
        
        # kNN search
        body = {"knn": {"field": vector_field, "query_vector": embedding, "k": k, "num_candidates": k * 2}}
        return es_request("POST", f"/{index}/_search", body)

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
            if request.jsonrpc != "2.0":
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: jsonrpc must be '2.0'"})
            if not isinstance(params, dict):
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: params must be an object"})

            if method == "initialize":
                return MCPResponse(id, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}, "prompts": {"listChanged": True}},
                    "serverInfo": {"name": "elasticsearch-mcp", "version": "1.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                if args is None:
                    args = {}
                if not isinstance(args, dict):
                    return MCPResponse(id, error={"code": -32602, "message": "Invalid params: arguments must be an object"})
                handlers = {
                    "es_search": self._handle_es_search,
                    "es_vector_search": self._handle_es_vector_search,
                    "es_index": self._handle_es_index,
                    "es_cluster_health": self._handle_es_cluster_health,
                    "es_index_info": self._handle_es_index_info,
                    "generate_embedding": self._handle_generate_embedding,
                    "ai_semantic_search": self._handle_ai_semantic_search,
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
                if uri == "es://cluster":
                    result = es_request("GET", "/_cluster/health")
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(result, indent=2)}]})
                if uri == "es://indices":
                    result = es_request("GET", "/_cat/indices?format=json")
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(result, indent=2)}]})
                if uri == "mangle://facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(self.facts, indent=2)}]})
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
    def _write_json(self, status_code: int, payload: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            from datetime import datetime, timezone
            aicore_cfg = get_aicore_config()
            response = {
                "status": "healthy",
                "service": "elasticsearch-mcp",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "es_host": get_es_config().get("host"),
                "aicore_config_ready": aicore_config_ready(aicore_cfg),
            }
            self._write_json(200, response)
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path == "/mcp":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length <= 0:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request: empty body"}})
                return
            if content_length > MAX_REQUEST_BYTES:
                self._write_json(413, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Request too large"}})
                return

            raw_body = self.rfile.read(content_length)
            try:
                body = raw_body.decode("utf-8")
                data = json.loads(body)
                if not isinstance(data, dict):
                    self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}})
                    return
                request = MCPRequest(data)
                response = mcp_server.handle_request(request)
                self._write_json(200, response.to_dict())
            except UnicodeDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid UTF-8 body"}})
            except json.JSONDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        else:
            self._write_json(404, {"error": "Not found"})

    def log_message(self, format, *args):
        pass


def main():
    import sys
    port = 9120
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║   Elasticsearch MCP Server with Mangle Reasoning         ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Tools: es_search, es_vector_search, es_index, es_cluster_health,
       es_index_info, generate_embedding, ai_semantic_search, mangle_query

Resources: es://cluster, es://indices, mangle://facts
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
