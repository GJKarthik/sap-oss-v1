"""
AI Core Streaming Agent with ODPS + Regulations Integration

External AI Core backend for public/internal data with streaming.
- Public/Internal data → AI Core
- Confidential data → vLLM (fallback)
- Restricted data → Blocked
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
            ("aicore-streaming-agent", "autonomy_level"): "L2",
            ("aicore-streaming-agent", "service_name"): "aicore-streaming",
            ("aicore-streaming-agent", "mcp_endpoint"): "http://localhost:9190/mcp",
            ("aicore-streaming-agent", "default_backend"): "aicore",
        }
        
        self.facts["agent_can_use"] = {
            "stream_complete", "batch_complete", "health_check",
            "list_models", "mangle_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "change_config", "update_credentials"
        }
        
        # Confidential keywords (route to vLLM)
        self.facts["confidential_keywords"] = {
            "confidential", "customer", "personal", "private"
        }
        
        # Restricted keywords (block entirely)
        self.facts["restricted_keywords"] = {"restricted", "classified", "secret"}
        
        self.facts["prompting_policy"] = {
            "aicore-streaming-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.7,
                "streaming": True,
                "system_prompt": (
                    "You are an AI assistant powered by SAP AI Core. "
                    "Process queries efficiently with streaming responses. "
                    "Only handle public and internal data through this service. "
                    "Confidential data must be redirected to on-premise systems."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Block if restricted
            for keyword in self.facts["restricted_keywords"]:
                if keyword in request_lower:
                    return []
            
            # Redirect if confidential
            for keyword in self.facts["confidential_keywords"]:
                if keyword in request_lower:
                    return []
            
            # OK for public/internal
            return [{"result": True, "reason": "Public/internal data - AI Core OK"}]
        
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Block if restricted
            for keyword in self.facts["restricted_keywords"]:
                if keyword in request_lower:
                    return []
            
            # Route to vLLM if confidential
            for keyword in self.facts["confidential_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Confidential data: '{keyword}'"}]
            return []
        
        if predicate == "block_request":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            for keyword in self.facts["restricted_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Restricted data blocked: '{keyword}'"}]
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
            product_id = args[0] if args else "aicore-streaming-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class AICoreStreamingAgent:
    """
    AI Core Streaming Agent - Security-based routing.
    
    - Public/Internal → AI Core (external)
    - Confidential → vLLM (on-premise)
    - Restricted → Blocked
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9190/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "stream_complete")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check if blocked
        block_result = self.mangle.query("block_request", prompt)
        if block_result:
            self._log_audit("blocked", tool, "none", prompt)
            return {
                "status": "blocked",
                "message": block_result[0].get("reason", "Request blocked"),
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Determine routing
        vllm_result = self.mangle.query("route_to_vllm", prompt)
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        
        if vllm_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = vllm_result[0].get("reason", "Confidential data")
        elif aicore_result:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = aicore_result[0].get("reason", "Public/internal data")
        else:
            # Default fallback
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = "Default to AI Core"
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review",
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
        prompting = self.mangle.query("get_prompting_policy", "aicore-streaming-service-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Execute
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
                "temperature": prompting_policy.get("temperature", 0.7),
                "stream": prompting_policy.get("streaming", True)
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
            "agent": "aicore-streaming-agent",
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
        block_result = self.mangle.query("block_request", prompt)
        if block_result:
            return {
                "routing": {"backend": "blocked", "reason": block_result[0].get("reason")},
                "autonomy_level": "L2",
                "data_product": "aicore-streaming-service-v1",
                "status": "blocked"
            }
        
        vllm_result = self.mangle.query("route_to_vllm", prompt)
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        
        if vllm_result:
            backend = "vllm"
            reason = vllm_result[0].get("reason", "Confidential data")
        elif aicore_result:
            backend = "aicore"
            reason = aicore_result[0].get("reason", "Public/internal data")
        else:
            backend = "aicore"
            reason = "Default"
        
        prompting = self.mangle.query("get_prompting_policy", "aicore-streaming-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "aicore-streaming-service-v1"
        }


def main():
    import asyncio
    
    agent = AICoreStreamingAgent()
    
    print("=" * 60)
    print("AI Core Streaming Agent - Security-Based Routing")
    print("=" * 60)
    
    # Test 1: Public request (AI Core)
    print("\n--- Test 1: Public Request ---")
    governance = agent.check_governance("Summarize this article")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Internal request (AI Core)
    print("\n--- Test 2: Internal Request ---")
    governance = agent.check_governance("Internal memo summary")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: Customer data (vLLM)
    print("\n--- Test 3: Customer Data ---")
    governance = agent.check_governance("Analyze customer feedback")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Confidential (vLLM)
    print("\n--- Test 4: Confidential Data ---")
    governance = agent.check_governance("Review confidential report")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: Restricted (Blocked)
    print("\n--- Test 5: Restricted Data ---")
    governance = agent.check_governance("Process restricted documents")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 6: Classified (Blocked)
    print("\n--- Test 6: Classified Data ---")
    governance = agent.check_governance("Analyze classified information")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 7: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()