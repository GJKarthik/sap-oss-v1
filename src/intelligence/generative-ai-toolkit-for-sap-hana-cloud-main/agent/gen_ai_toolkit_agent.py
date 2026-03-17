# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Generative AI Toolkit for HANA Cloud Agent

ALWAYS routes to vLLM - HANA data is confidential.
Provides RAG, embeddings, and text generation with governance.
"""

import json
import os
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone


def _get_mangle_config(predicate: str, key: str, default=None):
    """Query Mangle for configuration, with fallback to default."""
    try:
        from hana_ai.mangle.client import get_config_value
        return get_config_value(predicate, key, default)
    except ImportError:
        return default


class MangleEngine:
    """Mangle query interface for governance rules."""
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_rules()
    
    def _load_rules(self):
        self.facts["agent_config"] = {
            ("gen-ai-hana-agent", "autonomy_level"): "L2",
            ("gen-ai-hana-agent", "service_name"): "gen-ai-toolkit-hana",
            ("gen-ai-hana-agent", "mcp_endpoint"): os.environ.get(
                "MCP_ENDPOINT",
                f"http://localhost:{_get_mangle_config('service_port', 'mcp_server', 9130)}/mcp"
            ),
            ("gen-ai-hana-agent", "default_backend"): "vllm",
        }
        
        self.facts["agent_can_use"] = {
            "rag_query", "generate_text", "create_embeddings",
            "semantic_search", "summarize", "mangle_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "index_documents", "delete_embeddings", "update_vector_store", "export_data"
        }
        
        self.facts["prompting_policy"] = {
            "gen-ai-hana-service-v1": {
                "max_tokens": _get_mangle_config("prompting_policy", "max_tokens", 4096),
                "temperature": _get_mangle_config("prompting_policy", "temperature", 0.7),
                "system_prompt": (
                    "You are a generative AI assistant integrated with SAP HANA Cloud. "
                    "Generate responses using RAG patterns with HANA vector store. "
                    "Never expose raw data values from HANA tables. "
                    "All processing must remain on-premise for data protection. "
                    "Follow enterprise governance and compliance requirements."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        # ALWAYS vLLM for HANA generative AI
        if predicate == "route_to_vllm":
            return [{"result": True, "reason": "HANA generative AI always uses vLLM"}]
        
        if predicate == "route_to_aicore":
            return []  # Never route to external AI Core
        
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
            product_id = args[0] if args else "gen-ai-hana-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class GenAiToolkitAgent:
    """
    Generative AI Toolkit Agent - ALWAYS uses vLLM.
    
    Provides RAG, embeddings, and text generation for HANA Cloud data.
    All operations stay on-premise for data protection.
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        # Always use vLLM for HANA generative AI
        _vllm_port = _get_mangle_config("service_port", "vllm", 9180)
        self.vllm_endpoint = os.environ.get("VLLM_ENDPOINT", f"http://localhost:{_vllm_port}/mcp")
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "rag_query")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # ALWAYS route to vLLM
        backend = "vllm"
        endpoint = self.vllm_endpoint
        routing_reason = "HANA generative AI always uses vLLM (on-premise)"
        
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
        prompting = self.mangle.query("get_prompting_policy", "gen-ai-hana-service-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Execute via vLLM MCP
        try:
            result = await self._call_mcp(endpoint, tool, {
                "messages": json.dumps([{
                    "role": "system", 
                    "content": prompting_policy.get("system_prompt", "")
                }, {
                    "role": "user", 
                    "content": prompt
                }]),
                "max_tokens": prompting_policy.get("max_tokens", _get_mangle_config("prompting_policy", "max_tokens", 4096)),
                "temperature": prompting_policy.get("temperature", _get_mangle_config("prompting_policy", "temperature", 0.7))
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
            "agent": "gen-ai-hana-agent",
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
        # Always vLLM for HANA generative AI
        prompting = self.mangle.query("get_prompting_policy", "gen-ai-hana-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {
                "backend": "vllm",
                "reason": "HANA generative AI ALWAYS uses vLLM (on-premise)"
            },
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "gen-ai-hana-service-v1",
            "requires_human_oversight": True
        }


def main():
    import asyncio
    
    agent = GenAiToolkitAgent()
    
    print("=" * 60)
    print("Generative AI Toolkit Agent - ALWAYS vLLM (On-Premise)")
    print("=" * 60)
    
    # Test 1: RAG query (always vLLM)
    print("\n--- Test 1: RAG Query ---")
    governance = agent.check_governance("Find documents similar to this query")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Text generation (always vLLM)
    print("\n--- Test 2: Text Generation ---")
    governance = agent.check_governance("Generate a summary of the financial report")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: Semantic search (always vLLM)
    print("\n--- Test 3: Semantic Search ---")
    governance = agent.check_governance("Search for related customer records")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Index documents (requires approval)
    print("\n--- Test 4: Index Documents ---")
    result = asyncio.run(agent.invoke(
        "Index all new documents from HANA",
        {"tool": "index_documents"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 5: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()