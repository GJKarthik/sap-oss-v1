"""
OData Vocabularies Agent with ODPS + Regulations Integration

Public documentation service - AI Core OK for most queries.
Routes to vLLM only when actual entity data is involved.

Self-contained agent with no external dependencies.
"""

import asyncio
import hashlib
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
            ("odata-vocab-agent", "autonomy_level"): "L3",
            ("odata-vocab-agent", "service_name"): "odata-vocabularies",
            ("odata-vocab-agent", "mcp_endpoint"): "http://localhost:9150/mcp",
            ("odata-vocab-agent", "default_backend"): "aicore",
        }
        
        self.facts["agent_can_use"] = {
            "lookup_vocabulary", "lookup_term", "generate_annotation",
            "validate_annotation", "list_vocabularies", "mangle_query"
        }
        
        # No approval required for public docs
        self.facts["agent_requires_approval"] = set()
        
        # Keywords indicating actual data (route to vLLM)
        self.facts["data_keywords"] = {
            "customer data", "real example", "production data",
            "actual values", "trading", "financial"
        }
        
        self.facts["prompting_policy"] = {
            "odata-vocabulary-service-v1": {
                "max_tokens": 2048,
                "temperature": 0.5,
                "system_prompt": (
                    "You are an OData vocabulary expert assistant. "
                    "Help users understand OData annotations, terms, and vocabulary usage. "
                    "Provide examples and best practices for OData API design. "
                    "Reference SAP vocabulary extensions when appropriate."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Check for actual data keywords
            for keyword in self.facts["data_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Contains actual data: '{keyword}'"}]
            return []
        
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            # Default to AI Core for vocabulary queries
            if not self.query("route_to_vllm", request):
                return [{"result": True, "reason": "Public documentation query"}]
            return []
        
        if predicate == "requires_human_review":
            # No human review for public docs
            return []
        
        if predicate == "safety_check_passed":
            tool = args[0] if args else ""
            if tool in self.facts["agent_can_use"]:
                return [{"result": True, "tool": tool}]
            return []
        
        if predicate == "get_prompting_policy":
            product_id = args[0] if args else "odata-vocabulary-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L3"}]
        
        return []


class ODataVocabAgent:
    """
    OData Vocabularies Agent - AI Core OK for public documentation.
    
    Higher autonomy (L3) for public documentation queries.
    Routes to vLLM only when actual entity data is involved.
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9150/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "lookup_vocabulary")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check routing - default to AI Core for public docs
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = routing_result[0].get("reason", "Contains actual data")
        else:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = "Public documentation - AI Core OK"
        
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
        prompting = self.mangle.query("get_prompting_policy", "odata-vocabulary-service-v1")
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
                "max_tokens": prompting_policy.get("max_tokens", 2048),
                "temperature": prompting_policy.get("temperature", 0.5)
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
        """Call MCP endpoint asynchronously without blocking the event loop."""
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        }
        
        def _sync_request() -> Any:
            req = urllib.request.Request(
                endpoint,
                data=json.dumps(request_data).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode())
        
        # Run the blocking request in a thread pool to avoid blocking the event loop
        return await asyncio.to_thread(_sync_request)
    
    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None):
        """Log audit entry with deterministic SHA-256 hash for forensic reproducibility."""
        # Use SHA-256 instead of hash() for deterministic, reproducible content identifiers
        prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:16]
        
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "odata-vocab-agent",
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": prompt_hash,
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
            reason = routing_result[0].get("reason", "Contains actual data")
        else:
            backend = "aicore"
            reason = "Public documentation - AI Core OK"
        
        prompting = self.mangle.query("get_prompting_policy", "odata-vocabulary-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L3",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "odata-vocabulary-service-v1",
            "requires_human_oversight": False
        }


def main():
    import asyncio
    
    agent = ODataVocabAgent()
    
    print("=" * 60)
    print("OData Vocabularies Agent - Public Documentation")
    print("=" * 60)
    
    # Test 1: Vocabulary lookup (AI Core OK)
    print("\n--- Test 1: Vocabulary Lookup ---")
    governance = agent.check_governance("What is the Common vocabulary in OData?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Annotation help (AI Core OK)
    print("\n--- Test 2: Annotation Help ---")
    governance = agent.check_governance("How do I annotate a field as required?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: CSDL question (AI Core OK)
    print("\n--- Test 3: CSDL Question ---")
    governance = agent.check_governance("What is the EDM type for decimal?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: With actual data (vLLM)
    print("\n--- Test 4: With Customer Data ---")
    governance = agent.check_governance("Annotate this customer data example")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: With financial data (vLLM)
    print("\n--- Test 5: Financial Example ---")
    governance = agent.check_governance("Show annotations for our financial trading entity")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()
