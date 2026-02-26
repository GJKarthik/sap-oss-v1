"""
AI SDK Agent with ODPS + Regulations Integration

Provides governance-aware LLM routing:
- Confidential financial data → vLLM (on-premise)
- General queries → AI Core (external LLM)
- Integrates with regulations/mangle for compliance
"""

import json
import os
import sys
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone

# =============================================================================
# Mangle Engine (Simulated)
# =============================================================================

class MangleEngine:
    """
    Mangle query interface for governance rules.
    In production, connect to actual Mangle engine.
    """
    
    def __init__(self, rules_paths: Optional[List[str]] = None):
        self.rules_paths = rules_paths or []
        self.facts: Dict[str, Any] = {}
        self._load_rules()
    
    def _load_rules(self):
        """Load and parse Mangle rules into fact store"""
        # Agent configuration
        self.facts["agent_config"] = {
            ("ai-sdk-agent", "autonomy_level"): "L2",
            ("ai-sdk-agent", "service_name"): "ai-sdk-js",
            ("ai-sdk-agent", "mcp_endpoint"): "http://localhost:9090/mcp",
            ("ai-sdk-agent", "default_backend"): "aicore",
            ("ai-sdk-agent", "confidential_backend"): "vllm",
        }
        
        # Tool permissions
        self.facts["agent_can_use"] = {
            "aicore_chat", "aicore_embed", "list_deployments", 
            "get_deployment_info", "mangle_query"
        }
        
        # Tools requiring approval
        self.facts["agent_requires_approval"] = {
            "create_deployment", "delete_deployment", "modify_deployment"
        }
        
        # Confidential data keywords
        self.facts["confidential_keywords"] = {
            "trading", "position", "pnl", "profit", "loss", "balance",
            "fx", "derivative", "swap", "hedge", "var", "exposure", 
            "counterparty", "risk", "liquidity", "capital"
        }
        
        # Data products
        self.facts["data_products"] = {
            "ai-core-inference-v1": {
                "security_class": "internal",
                "routing": "hybrid",
                "owner": "AI Platform Team"
            }
        }
        
        # Prompting policy
        self.facts["prompting_policy"] = {
            "ai-core-inference-v1": {
                "max_tokens": 2048,
                "temperature": 0.7,
                "system_prompt": (
                    "You are an AI assistant operating within SAP enterprise guidelines. "
                    "Follow all governance requirements from the Model Governance Framework. "
                    "Never disclose confidential financial information externally. "
                    "Always apply safety controls and guardrails."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        """Query Mangle knowledge base"""
        
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()
            for keyword in self.facts["confidential_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Contains '{keyword}'"}]
            return []
        
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            if not self.query("route_to_vllm", request):
                return [{"result": True}]
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
        
        if predicate == "agent_can_use":
            tool = args[0] if args else ""
            if tool in self.facts["agent_can_use"]:
                return [{"result": True}]
            return []
        
        if predicate == "get_prompting_policy":
            product_id = args[0] if args else "ai-core-inference-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []
    
    def assert_fact(self, fact: str):
        """Assert a new fact into the knowledge base"""
        # Parse and store fact
        pass


# =============================================================================
# AI SDK Agent
# =============================================================================

class AISdkAgent:
    """
    AI SDK Agent with ODPS data product awareness and regulations compliance.
    
    Features:
    - Routes confidential financial data to vLLM (on-premise)
    - Routes general queries to AI Core (external)
    - Enforces governance rules from regulations/mangle
    - Applies prompting policies from ODPS 4.1
    - Logs all actions for audit
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9090/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        """
        Process a request with full governance checks.
        
        Args:
            prompt: User prompt/request
            context: Additional context (tool, data_product, etc.)
        
        Returns:
            Response with status, backend used, and result
        """
        context = context or {}
        tool = context.get("tool", "aicore_chat")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # 1. Check routing (vLLM for confidential, AI Core for general)
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = routing_result[0].get("reason", "Contains confidential data")
        else:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = "General query"
        
        # 2. Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review before execution",
                "tool": tool,
                "backend": backend,
                "timestamp": timestamp
            }
        
        # 3. Safety check
        if not self.mangle.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, backend, prompt)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # 4. Get prompting policy
        prompting = self.mangle.query("get_prompting_policy", "ai-core-inference-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # 5. Execute via MCP
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
                "temperature": prompting_policy.get("temperature", 0.7)
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
        """Call MCP server tool"""
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
        """Log action for audit trail"""
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "ai-sdk-agent",
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hash(prompt),  # Don't log actual prompt
            "prompt_length": len(prompt)
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
    
    def get_audit_log(self) -> List[Dict]:
        """Get audit log entries"""
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        """
        Check governance rules for a prompt without executing.
        
        Returns routing decision and applicable policies.
        """
        routing_result = self.mangle.query("route_to_vllm", prompt)
        if routing_result:
            backend = "vllm"
            reason = routing_result[0].get("reason", "Contains confidential data")
        else:
            backend = "aicore"
            reason = "General query - can use external LLM"
        
        prompting = self.mangle.query("get_prompting_policy", "ai-core-inference-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {
                "backend": backend,
                "reason": reason
            },
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "ai-core-inference-v1"
        }


# =============================================================================
# CLI for Testing
# =============================================================================

def main():
    import asyncio
    
    agent = AISdkAgent()
    
    print("=" * 60)
    print("AI SDK Agent - Governance-Aware LLM Routing")
    print("=" * 60)
    
    # Test 1: General query (should route to AI Core)
    print("\n--- Test 1: General Query ---")
    governance = agent.check_governance("Explain how to use the AI SDK for chat completion")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Confidential query (should route to vLLM)
    print("\n--- Test 2: Confidential Query ---")
    governance = agent.check_governance("Analyze our FX trading positions for EUR/USD")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: Risk data (should route to vLLM)
    print("\n--- Test 3: Risk Data Query ---")
    governance = agent.check_governance("What is our counterparty exposure to Deutsche Bank?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Action requiring approval
    print("\n--- Test 4: Action Requiring Approval ---")
    result = asyncio.run(agent.invoke(
        "Create a new deployment for GPT-4",
        {"tool": "create_deployment"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 5: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()