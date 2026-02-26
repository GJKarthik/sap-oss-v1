"""
World Monitor Agent with ODPS + Regulations Integration

Content-based routing:
- Public news summaries → AI Core OK
- Internal analysis/impact assessments → vLLM
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
            ("world-monitor-agent", "autonomy_level"): "L2",
            ("world-monitor-agent", "service_name"): "world-monitor",
            ("world-monitor-agent", "mcp_endpoint"): "http://localhost:9160/mcp",
            ("world-monitor-agent", "default_backend"): "vllm",
        }
        
        self.facts["agent_can_use"] = {
            "summarize_news", "analyze_trends", "search_events",
            "get_headlines", "mangle_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "impact_assessment", "competitor_analysis", "export_report"
        }
        
        # Public news keywords
        self.facts["public_news_keywords"] = {"news", "headline", "article", "summary"}
        
        # Internal context keywords (route to vLLM)
        self.facts["internal_keywords"] = {
            "internal", "analysis", "assessment", "strategy",
            "competitor", "our company", "business impact",
            "impact", "risk", "threat"
        }
        
        self.facts["prompting_policy"] = {
            "world-monitor-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.4,
                "system_prompt": (
                    "You are a global events analyst. "
                    "Monitor and analyze world events, news, and trends. "
                    "Provide balanced, factual analysis. "
                    "Flag potential business impacts for internal review. "
                    "Never share internal analysis with external systems."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        if predicate == "route_to_vllm":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Check for internal analysis keywords
            for keyword in self.facts["internal_keywords"]:
                if keyword in request_lower:
                    return [{"result": True, "reason": f"Internal context: '{keyword}'"}]
            return []
        
        if predicate == "route_to_aicore":
            request = args[0] if args else ""
            request_lower = request.lower()
            
            # Check if it's public news without internal context
            is_news = any(kw in request_lower for kw in self.facts["public_news_keywords"])
            has_internal = self.query("route_to_vllm", request)
            
            if is_news and not has_internal:
                return [{"result": True, "reason": "Public news query"}]
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
            product_id = args[0] if args else "world-monitor-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class WorldMonitorAgent:
    """
    World Monitor Agent - Content-based routing.
    
    - Public news summaries → AI Core OK
    - Internal analysis → vLLM
    - Impact assessments → vLLM + human review
    """
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.mcp_endpoint = "http://localhost:9160/mcp"
        self.vllm_endpoint = "http://localhost:9180/mcp"
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "summarize_news")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check routing based on content
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        vllm_result = self.mangle.query("route_to_vllm", prompt)
        
        if vllm_result:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = vllm_result[0].get("reason", "Internal analysis")
        elif aicore_result:
            backend = "aicore"
            endpoint = self.mcp_endpoint
            routing_reason = aicore_result[0].get("reason", "Public news")
        else:
            backend = "vllm"
            endpoint = self.vllm_endpoint
            routing_reason = "Default to vLLM for safety"
        
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
        prompting = self.mangle.query("get_prompting_policy", "world-monitor-service-v1")
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
                "temperature": prompting_policy.get("temperature", 0.4)
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
            "agent": "world-monitor-agent",
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
        aicore_result = self.mangle.query("route_to_aicore", prompt)
        vllm_result = self.mangle.query("route_to_vllm", prompt)
        
        if vllm_result:
            backend = "vllm"
            reason = vllm_result[0].get("reason", "Internal analysis")
        elif aicore_result:
            backend = "aicore"
            reason = aicore_result[0].get("reason", "Public news")
        else:
            backend = "vllm"
            reason = "Default to vLLM for safety"
        
        prompting = self.mangle.query("get_prompting_policy", "world-monitor-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "routing": {"backend": backend, "reason": reason},
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "world-monitor-service-v1"
        }


def main():
    import asyncio
    
    agent = WorldMonitorAgent()
    
    print("=" * 60)
    print("World Monitor Agent - Content-Based Routing")
    print("=" * 60)
    
    # Test 1: Public news summary (AI Core OK)
    print("\n--- Test 1: News Summary ---")
    governance = agent.check_governance("Summarize today's news headlines")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 2: Get headlines (AI Core OK)
    print("\n--- Test 2: Headlines ---")
    governance = agent.check_governance("Show me latest article headlines")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 3: Internal analysis (vLLM)
    print("\n--- Test 3: Internal Analysis ---")
    governance = agent.check_governance("Provide internal analysis of market trends")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 4: Risk assessment (vLLM)
    print("\n--- Test 4: Risk Assessment ---")
    governance = agent.check_governance("What are the potential risks from this event?")
    print(f"Routing: {governance['routing']['backend']}")
    print(f"Reason: {governance['routing']['reason']}")
    
    # Test 5: Competitor analysis (requires approval)
    print("\n--- Test 5: Competitor Analysis ---")
    result = asyncio.run(agent.invoke(
        "Analyze our competitor's market position",
        {"tool": "competitor_analysis"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 6: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']}")


if __name__ == "__main__":
    main()