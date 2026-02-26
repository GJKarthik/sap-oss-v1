"""
AI Core PAL Agent with ODPS + Regulations Integration

MCP Integration with SAP HANA Predictive Analysis Library (PAL).
Always routes to vLLM - HANA data is enterprise confidential.
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
            ("aicore-pal-agent", "autonomy_level"): "L2",
            ("aicore-pal-agent", "service_name"): "aicore-pal",
            ("aicore-pal-agent", "mcp_endpoint"): "http://localhost:8084/mcp",
            ("aicore-pal-agent", "default_backend"): "vllm",
        }
        
        self.facts["agent_can_use"] = {
            "pal_classification", "pal_regression", "pal_clustering",
            "pal_forecast", "pal_anomaly", "mangle_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "pal_train_model", "pal_delete_model", "hana_write"
        }
        
        self.facts["prompting_policy"] = {
            "aicore-pal-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are an AI assistant for SAP HANA PAL predictive analytics. "
                    "Help users understand ML results, interpret predictions, and guide analysis. "
                    "All data processed is enterprise confidential - use on-premise LLM only. "
                    "Never send enterprise data or ML results to external services."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        # Always route to vLLM - HANA data is confidential
        if predicate == "route_to_vllm":
            return [{"result": True, "reason": "HANA PAL data is confidential"}]
        
        if predicate == "route_to_aicore":
            return []  # Never route to external
        
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
            product_id = args[0] if args else "aicore-pal-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class AICorePALAgent:
    """
    AI Core PAL Agent - vLLM only for HANA data.
    
    Provides governance-aware access to SAP HANA PAL
    predictive analytics operations.
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:8084/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "pal_classification")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Always vLLM for HANA data
        backend = "vllm"
        endpoint = self.vllm_endpoint
        routing_reason = "HANA PAL data is enterprise confidential - vLLM only"
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, backend, prompt)
            return {
                "status": "pending_approval",
                "message": f"ML action '{tool}' requires human review",
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
        prompting = self.mangle.query("get_prompting_policy", "aicore-pal-service-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Execute via vLLM
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
            "agent": "aicore-pal-agent",
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
        prompting = self.mangle.query("get_prompting_policy", "aicore-pal-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {
                "backend": "vllm",
                "reason": "HANA PAL data is enterprise confidential - vLLM only"
            },
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "aicore-pal-service-v1",
            "external_allowed": False
        }


def main():
    import asyncio
    
    agent = AICorePALAgent()
    
    print("=" * 60)
    print("AI Core PAL Agent - vLLM Only (HANA Data)")
    print("=" * 60)
    
    # Test 1: Classification (vLLM)
    print("\n--- Test 1: PAL Classification ---")
    governance = agent.check_governance("Classify customers by revenue")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    print(f"External allowed: {governance['external_allowed']}")
    
    # Test 2: Regression (vLLM)
    print("\n--- Test 2: PAL Regression ---")
    governance = agent.check_governance("Predict sales for Q4")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Autonomy: {governance['autonomy_level']}")
    
    # Test 3: Forecasting (vLLM)
    print("\n--- Test 3: PAL Forecast ---")
    result = asyncio.run(agent.invoke(
        "Forecast next 12 months of sales",
        {"tool": "pal_forecast"}
    ))
    print(f"Status: {result['status']}")
    print(f"Backend: {result.get('backend', 'N/A')}")
    
    # Test 4: Train model (requires approval)
    print("\n--- Test 4: Train Model ---")
    result = asyncio.run(agent.invoke(
        "Train new classification model",
        {"tool": "pal_train_model"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 5: Delete model (requires approval)
    print("\n--- Test 5: Delete Model ---")
    result = asyncio.run(agent.invoke(
        "Delete old regression model",
        {"tool": "pal_delete_model"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()