"""
MCP Server exposing LangChain HANA tools.

Addresses Gap #3: No MCP Bridge - langchain-hana agent calls MCP but
mangle doesn't expose langchain tools.

This MCP server exposes langchain-hana capabilities to mangle-query-service:
- Vector search
- MMR search
- Embedding generation
- Analytical queries

Usage:
    # Start the MCP server
    python -m mcp_server.langchain_hana_mcp
    
    # Use from Mangle rules
    hana_vector_search(Query, 5, "", Results, Score).
"""

import asyncio
import json
import logging
import os
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# Configuration
MCP_HOST = os.getenv("MCP_HOST", "localhost")
MCP_PORT = int(os.getenv("MCP_PORT", "9150"))


class LangChainHanaMCPServer:
    """
    MCP Server exposing LangChain HANA tools.
    
    Implements JSON-RPC 2.0 protocol for MCP tool invocation.
    """
    
    def __init__(self):
        self._bridge = None
        self._analytical = None
        self._initialized = False
    
    async def initialize(self) -> bool:
        """Initialize the server with langchain-hana components."""
        if self._initialized:
            return True
        
        try:
            # Import bridge from connectors
            from connectors.langchain_hana_bridge import (
                LangChainHanaBridge,
                initialize_bridge,
            )
            
            self._bridge = LangChainHanaBridge()
            await self._bridge.initialize()
            
            # Try to import analytical module
            try:
                from langchain_hana.analytical import HanaAnalytical
                # Analytical requires direct connection
                # Will be initialized on first use
                self._analytical = None
            except ImportError:
                logger.warning("langchain_hana.analytical not available")
            
            self._initialized = True
            logger.info("LangChain HANA MCP Server initialized")
            return True
            
        except Exception as e:
            logger.error(f"Failed to initialize MCP server: {e}")
            return False
    
    # =========================================================================
    # MCP Tool Definitions
    # =========================================================================
    
    def get_tools(self) -> List[Dict[str, Any]]:
        """Return list of available MCP tools."""
        return [
            {
                "name": "hana_vector_search",
                "description": "Perform vector similarity search in HANA Cloud",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query text"
                        },
                        "k": {
                            "type": "integer",
                            "description": "Number of results to return",
                            "default": 5
                        },
                        "filter": {
                            "type": "object",
                            "description": "Optional metadata filter"
                        }
                    },
                    "required": ["query"]
                }
            },
            {
                "name": "hana_mmr_search",
                "description": "Perform MMR (Maximal Marginal Relevance) search for diverse results",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query text"
                        },
                        "k": {
                            "type": "integer",
                            "description": "Number of results to return",
                            "default": 5
                        },
                        "fetch_k": {
                            "type": "integer",
                            "description": "Number of candidates to fetch",
                            "default": 20
                        },
                        "lambda_mult": {
                            "type": "number",
                            "description": "Diversity factor (0=max diversity, 1=max relevance)",
                            "default": 0.5
                        }
                    },
                    "required": ["query"]
                }
            },
            {
                "name": "hana_embed",
                "description": "Generate embedding using HANA's internal VECTOR_EMBEDDING function",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "text": {
                            "type": "string",
                            "description": "Text to embed"
                        }
                    },
                    "required": ["text"]
                }
            },
            {
                "name": "hana_add_texts",
                "description": "Add texts to the HANA vector store",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "texts": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "List of texts to add"
                        },
                        "metadatas": {
                            "type": "array",
                            "items": {"type": "object"},
                            "description": "Optional metadata for each text"
                        }
                    },
                    "required": ["texts"]
                }
            },
            {
                "name": "hana_aggregate",
                "description": "Execute analytical aggregation query on HANA calculation view",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "view_name": {
                            "type": "string",
                            "description": "Name of the calculation view"
                        },
                        "dimensions": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Dimension columns to group by"
                        },
                        "measures": {
                            "type": "object",
                            "description": "Measure columns with aggregation types"
                        },
                        "filters": {
                            "type": "object",
                            "description": "Optional filter conditions"
                        },
                        "limit": {
                            "type": "integer",
                            "description": "Maximum rows to return",
                            "default": 1000
                        }
                    },
                    "required": ["view_name", "dimensions", "measures"]
                }
            },
            {
                "name": "hana_timeseries",
                "description": "Execute time-series aggregation query",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "view_name": {
                            "type": "string",
                            "description": "Name of the calculation view"
                        },
                        "time_column": {
                            "type": "string",
                            "description": "Date/time column for grouping"
                        },
                        "granularity": {
                            "type": "string",
                            "enum": ["YEAR", "QUARTER", "MONTH", "WEEK", "DAY", "HOUR"],
                            "description": "Time granularity"
                        },
                        "measures": {
                            "type": "object",
                            "description": "Measure columns with aggregation types"
                        },
                        "filters": {
                            "type": "object",
                            "description": "Optional filter conditions"
                        }
                    },
                    "required": ["view_name", "time_column", "granularity", "measures"]
                }
            },
            {
                "name": "hana_health",
                "description": "Check health of HANA connection",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
        ]
    
    # =========================================================================
    # Tool Handlers
    # =========================================================================
    
    async def handle_tool_call(
        self,
        tool_name: str,
        arguments: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Handle MCP tool call."""
        
        if not await self.initialize():
            return {"error": "Server not initialized"}
        
        handlers = {
            "hana_vector_search": self._handle_vector_search,
            "hana_mmr_search": self._handle_mmr_search,
            "hana_embed": self._handle_embed,
            "hana_add_texts": self._handle_add_texts,
            "hana_aggregate": self._handle_aggregate,
            "hana_timeseries": self._handle_timeseries,
            "hana_health": self._handle_health,
        }
        
        handler = handlers.get(tool_name)
        if handler is None:
            return {"error": f"Unknown tool: {tool_name}"}
        
        try:
            return await handler(arguments)
        except Exception as e:
            logger.error(f"Tool {tool_name} failed: {e}")
            return {"error": str(e)}
    
    async def _handle_vector_search(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_vector_search tool."""
        query = args.get("query", "")
        k = args.get("k", 5)
        filter_dict = args.get("filter")
        
        results = await self._bridge.similarity_search(query, k, filter_dict)
        
        return {
            "results": [
                {
                    "content": r.content,
                    "metadata": r.metadata,
                    "score": r.score,
                }
                for r in results
            ],
            "count": len(results),
            "source": "hana_vector",
        }
    
    async def _handle_mmr_search(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_mmr_search tool."""
        query = args.get("query", "")
        k = args.get("k", 5)
        fetch_k = args.get("fetch_k", 20)
        lambda_mult = args.get("lambda_mult", 0.5)
        filter_dict = args.get("filter")
        
        results = await self._bridge.mmr_search(
            query, k, fetch_k, lambda_mult, filter_dict
        )
        
        return {
            "results": [
                {
                    "content": r.content,
                    "metadata": r.metadata,
                    "score": r.score,
                }
                for r in results
            ],
            "count": len(results),
            "source": "hana_mmr",
        }
    
    async def _handle_embed(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_embed tool."""
        text = args.get("text", "")
        
        embedding = await self._bridge.embed_text(text)
        
        if embedding:
            return {
                "embedding": embedding,
                "dimensions": len(embedding),
                "source": "hana_internal",
            }
        return {"error": "Failed to generate embedding"}
    
    async def _handle_add_texts(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_add_texts tool."""
        texts = args.get("texts", [])
        metadatas = args.get("metadatas")
        
        success = await self._bridge.add_texts(texts, metadatas)
        
        return {
            "success": success,
            "count": len(texts),
        }
    
    async def _handle_aggregate(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_aggregate tool."""
        # Import analytical on demand
        try:
            from langchain_hana.analytical import HanaAnalytical
        except ImportError:
            return {"error": "langchain_hana.analytical not available"}
        
        # Create analytical instance if needed
        if self._analytical is None:
            # Need direct HANA connection
            if not self._bridge._hana_db:
                return {"error": "HANA connection not available"}
            self._analytical = HanaAnalytical(
                connection=self._bridge._hana_db.connection
            )
        
        view_name = args.get("view_name", "")
        dimensions = args.get("dimensions", [])
        measures = args.get("measures", {})
        filters = args.get("filters")
        limit = args.get("limit", 1000)
        
        try:
            result = self._analytical.aggregate(
                view_name=view_name,
                dimensions=dimensions,
                measures=measures,
                filters=filters,
                limit=limit,
            )
            
            return {
                "data": result.data,
                "sql": result.sql,
                "row_count": result.row_count,
                "dimensions": result.dimensions,
                "measures": result.measures,
            }
        except Exception as e:
            return {"error": str(e)}
    
    async def _handle_timeseries(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_timeseries tool."""
        try:
            from langchain_hana.analytical import HanaAnalytical
        except ImportError:
            return {"error": "langchain_hana.analytical not available"}
        
        if self._analytical is None:
            if not self._bridge._hana_db:
                return {"error": "HANA connection not available"}
            self._analytical = HanaAnalytical(
                connection=self._bridge._hana_db.connection
            )
        
        view_name = args.get("view_name", "")
        time_column = args.get("time_column", "")
        granularity = args.get("granularity", "MONTH")
        measures = args.get("measures", {})
        filters = args.get("filters")
        
        try:
            result = self._analytical.timeseries(
                view_name=view_name,
                time_column=time_column,
                granularity=granularity,
                measures=measures,
                filters=filters,
            )
            
            return {
                "data": result.data,
                "sql": result.sql,
                "row_count": result.row_count,
                "granularity": granularity,
            }
        except Exception as e:
            return {"error": str(e)}
    
    async def _handle_health(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Handle hana_health tool."""
        return await self._bridge.health_check()
    
    # =========================================================================
    # JSON-RPC Server
    # =========================================================================
    
    async def handle_request(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Handle JSON-RPC request."""
        method = request.get("method", "")
        params = request.get("params", {})
        request_id = request.get("id")
        
        result = None
        error = None
        
        if method == "tools/list":
            result = {"tools": self.get_tools()}
        
        elif method == "tools/call":
            tool_name = params.get("name", "")
            arguments = params.get("arguments", {})
            result = await self.handle_tool_call(tool_name, arguments)
            
            if "error" in result:
                error = {"code": -32000, "message": result["error"]}
                result = None
        
        elif method == "initialize":
            success = await self.initialize()
            result = {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {"listChanged": False}
                },
                "serverInfo": {
                    "name": "langchain-hana-mcp",
                    "version": "1.0.0"
                }
            }
        
        elif method == "notifications/initialized":
            # Notification, no response needed
            return None
        
        else:
            error = {"code": -32601, "message": f"Unknown method: {method}"}
        
        response = {"jsonrpc": "2.0", "id": request_id}
        if error:
            response["error"] = error
        else:
            response["result"] = result
        
        return response
    
    async def run_server(self, host: str = MCP_HOST, port: int = MCP_PORT):
        """Run the MCP server."""
        
        async def handle_client(reader, writer):
            """Handle individual client connection."""
            try:
                while True:
                    data = await reader.readline()
                    if not data:
                        break
                    
                    try:
                        request = json.loads(data.decode())
                        response = await self.handle_request(request)
                        
                        if response:
                            response_data = json.dumps(response) + "\n"
                            writer.write(response_data.encode())
                            await writer.drain()
                            
                    except json.JSONDecodeError as e:
                        error_response = {
                            "jsonrpc": "2.0",
                            "id": None,
                            "error": {"code": -32700, "message": "Parse error"}
                        }
                        writer.write((json.dumps(error_response) + "\n").encode())
                        await writer.drain()
                        
            except Exception as e:
                logger.error(f"Client handler error: {e}")
            finally:
                writer.close()
                await writer.wait_closed()
        
        server = await asyncio.start_server(handle_client, host, port)
        
        logger.info(f"LangChain HANA MCP Server listening on {host}:{port}")
        
        async with server:
            await server.serve_forever()


# Singleton server instance
_server: Optional[LangChainHanaMCPServer] = None


def get_server() -> LangChainHanaMCPServer:
    """Get or create the MCP server singleton."""
    global _server
    if _server is None:
        _server = LangChainHanaMCPServer()
    return _server


async def main():
    """Main entry point for the MCP server."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    
    server = get_server()
    await server.run_server()


if __name__ == "__main__":
    asyncio.run(main())