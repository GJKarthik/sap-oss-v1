# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2023 SAP SE
"""
LangChain HANA Cloud Agent with ODPS + Regulations Integration

Routes based on HANA schema classification:
- Confidential schemas (TRADING, RISK, etc.) → vLLM (on-premise)
- Public schemas → Can use AI Core
- Vector search → Always vLLM (embeddings contain business data)
"""

import json
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone


class MangleEngine:
    """Mangle query interface for governance rules."""
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_rules()
    
    def _load_rules(self):
        self.facts["agent_config"] = {
            ("langchain-hana-agent", "autonomy_level"): "L2",
            ("langchain-hana-agent", "service_name"): "langchain-hana",
            ("langchain-hana-agent", "mcp_endpoint"): "http://localhost:9140/mcp",
            ("langchain-hana-agent", "default_backend"): "vllm",
        }
        
        self.facts["agent_can_use"] = {
            "hana_vector_search", "hana_similarity_search", "hana_query",
            "get_schema_info", "list_tables", "mangle_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "execute_sql", "insert_embeddings", "delete_embeddings", "modify_table"
        }
        
        # HANA schema classification
        self.facts["confidential_schemas"] = {
            "trading", "risk", "treasury", "customer", "financial", "internal"
        }
        
        self.facts["public_schemas"] = {"public", "reference", "metadata"}
        
        # Keywords that indicate HANA data access
        self.facts["hana_data_keywords"] = {
            "select", "from", "table", "column", "trading", "risk",
            "treasury", "customer", "vector", "embedding", "similarity"
        }
        
        self.facts["prompting_policy"] = {
            "hana-vector-store-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are an AI assistant with access to SAP HANA Cloud data. "
                    "Use the vector store for semantic search when appropriate. "
                    "Never expose raw database values in responses. "
                    "All data queries must be executed on-premise. "
                    "Follow enterprise data governance policies."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Check for HANA data keywords
            for keyword in self.facts["hana_data_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"HANA data access: '{keyword}'"}]
            
            # Check for confidential schema mentions
            for schema in self.facts["confidential_schemas"]:
                if schema in request_lower:
                    return [{"result": True, "reason": f"Confidential schema: '{schema}'"}]
            
            return []
        
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            if not self.query("route_to_vllm", request):
                return [{"result": True, "reason": "Metadata-only query"}]
            return []
        
        if predicate == "requires_human_review":
            action = args[0] if args else ""
            if action in self.facts["agent_requires_approval"]:
                return [{"result": True, "action": action}]
            return []
        
        if predicate == "safety_check_passed":
            tool = args[0] if args else ""
            if tool in self.facts["agent_can_use"]:
                return [{"result": True, "tool": tool}]
            return []
        
        if predicate == "get_prompting_policy":
            product_id = args[0] if args else "hana-vector-store-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "is_confidential_schema":
            schema = (args[0] if args else "").lower()
            if schema in self.facts["confidential_schemas"]:
                return [{"result": True, "schema": schema}]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class LangChainHanaAgent:
    """
    LangChain HANA Agent with schema-based routing.
    
    Routes based on HANA schema classification:
    - Confidential schemas → vLLM
    - Vector search → vLLM (embeddings contain business data)
    - Metadata only → Can use AI Core
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9140/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "hana_vector_search")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check routing based on HANA schema/data
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = routing_result[0].get("reason", "HANA data access")
        else:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = "Metadata-only query"
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review before execution",
                "tool": tool,
                "backend": backend,
                "timestamp": timestamp
            }
        
        # Safety check
        if not self.mangle.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, backend, prompt)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Get prompting policy
        prompting = self.mangle.query("get_prompting_policy", "hana-vector-store-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Execute via MCP
        try:
            result = await self._call_mcp(endpoint, tool, {
                "messages": json.dumps([{
                    "role": "system", 
                    "content": prompting_policy.get("system_prompt", "")
                }, {
                    "role": "user", 
                    "content": prompt
                }]),
                "max_tokens": prompting_policy.get("max_tokens", 4096),
                "temperature": prompting_policy.get("temperature", 0.3)
            })
            
            self._log_audit("success", tool, backend, prompt)
            
            return {
                "status": "success",
                "backend": backend,
                "routing_reason": routing_reason,
                "result": result,
                "timestamp": timestamp
            }
            
        except Exception as e:
            self._log_audit("error", tool, backend, prompt, str(e))
            return {
                "status": "error",
                "message": str(e),
                "backend": backend,
                "timestamp": timestamp
            }
    
    async def _call_mcp(self, endpoint: str, tool: str, args: Dict) -> Any:
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        }
        
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(request_data).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    
    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "langchain-hana-agent",
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hash(prompt),
            "prompt_length": len(prompt)
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
    
    def get_audit_log(self) -> List[Dict]:
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            reason = routing_result[0].get("reason", "HANA data access")
        else:
            backend = "aicore"
            reason = "Metadata-only - can use external LLM"
        
        prompting = self.mangle.query("get_prompting_policy", "hana-vector-store-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "hana-vector-store-v1",
            "requires_human_oversight": True
        }


def main():
    import asyncio
    
    agent = LangChainHanaAgent()
    
    print("=" * 60)
    print("LangChain HANA Agent - Schema-Based Routing")
    print("=" * 60)
    
    # Test 1: Vector search (always vLLM)
    print("\n--- Test 1: Vector Search ---")
    governance = agent.check_governance("Find similar documents using vector search")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: TRADING schema query (confidential)
    print("\n--- Test 2: TRADING Schema Query ---")
    governance = agent.check_governance("SELECT * FROM TRADING.POSITIONS")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: RISK data (confidential)
    print("\n--- Test 3: RISK Data Query ---")
    governance = agent.check_governance("Query the risk exposure table")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Metadata only (can use AI Core)
    print("\n--- Test 4: Schema Metadata ---")
    governance = agent.check_governance("What are the best practices for HANA?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: Execute SQL (requires approval)
    print("\n--- Test 5: Execute SQL ---")
    result = asyncio.run(agent.invoke(
        "Run this query on production",
        {"tool": "execute_sql"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()