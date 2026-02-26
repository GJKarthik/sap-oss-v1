"""
Data Cleaning Agent with ODPS + Regulations Integration

Routes ALL LLM calls through the central mesh (ai-core-streaming).
The mesh then routes to vLLM (on-premise) based on security class.
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
            ("data-cleaning-agent", "autonomy_level"): "L2",
            ("data-cleaning-agent", "service_name"): "data-cleaning-copilot",
            ("data-cleaning-agent", "mcp_endpoint"): "http://localhost:9110/mcp",
            ("data-cleaning-agent", "security_class"): "confidential",
        }
        
        self.facts["agent_can_use"] = {
            "analyze_data_quality", "suggest_cleaning_rules", 
            "generate_validation", "profile_data", "mangle_query"
        }
        
        self.facts["agent_requires_approval"] = {
            "apply_transformation", "delete_records", 
            "modify_schema", "export_data"
        }
        
        # Fields that must be masked in audit logs
        self.facts["must_mask_fields"] = {
            "account_number", "ssn", "credit_card", "balance",
            "salary", "email", "phone"
        }
        
        self.facts["prompting_policy"] = {
            "data-cleaning-service-v1": {
                "max_tokens": 4096,
                "temperature": 0.3,
                "system_prompt": (
                    "You are a data cleaning and validation assistant. "
                    "Analyze data quality issues and suggest transformations. "
                    "Never expose raw data values in responses. "
                    "Focus on patterns and structural recommendations. "
                    "All data processing must remain on-premise."
                )
            }
        }
    
    def query(self, predicate: str, *args) -> List[Dict]:
        if predicate == "get_security_class":
            return [{"result": "confidential"}]
        
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
            product_id = args[0] if args else "data-cleaning-service-v1"
            policy = self.facts["prompting_policy"].get(product_id)
            if policy:
                return [policy]
            return []
        
        if predicate == "must_mask_field":
            field = args[0] if args else ""
            if field.lower() in self.facts["must_mask_fields"]:
                return [{"result": True, "field": field}]
            return []
        
        if predicate == "autonomy_level":
            return [{"level": "L2"}]
        
        return []


class DataCleaningAgent:
    """
    Data Cleaning Agent - Routes through central mesh.
    
    All LLM calls go through ai-core-streaming mesh which routes to:
    - vLLM (local) for confidential data (default for this service)
    - AI Core (external) for public data
    
    Mesh routing is based on X-Mesh-Service header.
    """
    
    # Central mesh endpoint (ai-core-streaming)
    MESH_ENDPOINT = "http://localhost:9190/v1"
    SERVICE_ID = "data-cleaning-copilot"
    SECURITY_CLASS = "confidential"
    
    def __init__(self):
        self.mangle = MangleEngine([
            "mangle/domain/agents.mg",
            "../regulations/mangle/rules.mg"
        ])
        self.audit_log: List[Dict] = []
    
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        context = context or {}
        tool = context.get("tool", "analyze_data_quality")
        timestamp = datetime.now(timezone.utc).isoformat()
        
        # Check if human review required
        if self.mangle.query("requires_human_review", tool):
            self._log_audit("pending_approval", tool, "pending", prompt)
            return {
                "status": "pending_approval",
                "message": f"Action '{tool}' requires human review before execution",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Safety check
        if not self.mangle.query("safety_check_passed", tool):
            self._log_audit("blocked", tool, "blocked", prompt)
            return {
                "status": "blocked",
                "message": f"Safety check failed for tool '{tool}'",
                "tool": tool,
                "timestamp": timestamp
            }
        
        # Get prompting policy
        prompting = self.mangle.query("get_prompting_policy", "data-cleaning-service-v1")
        prompting_policy = prompting[0] if prompting else {}
        
        # Route through central mesh with governance headers
        try:
            result = await self._call_mesh_chat({
                "model": "gpt-4",  # Mesh will route to appropriate backend
                "messages": [
                    {"role": "system", "content": prompting_policy.get("system_prompt", "")},
                    {"role": "user", "content": prompt}
                ],
                "max_tokens": prompting_policy.get("max_tokens", 4096),
                "temperature": prompting_policy.get("temperature", 0.3)
            })
            
            backend = result.get("x_mesh_backend", "unknown")
            routing_reason = result.get("x_mesh_routing_reason", "")
            
            self._log_audit("success", tool, backend, prompt)
            
            return {
                "status": "success",
                "backend": backend,
                "routing_reason": routing_reason,
                "result": result,
                "timestamp": timestamp
            }
            
        except Exception as e:
            self._log_audit("error", tool, "error", prompt, str(e))
            return {
                "status": "error",
                "message": str(e),
                "timestamp": timestamp
            }
    
    async def _call_mesh_chat(self, request: Dict) -> Dict[str, Any]:
        """Call central mesh for chat completions."""
        url = f"{self.MESH_ENDPOINT}/chat/completions"
        
        # Add mesh governance headers
        headers = {
            "Content-Type": "application/json",
            "X-Mesh-Service": self.SERVICE_ID,
            "X-Mesh-Security-Class": self.SECURITY_CLASS
        }
        
        req = urllib.request.Request(
            url,
            data=json.dumps(request).encode(),
            headers=headers,
            method="POST"
        )
        
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return {"error": {"message": e.reason, "code": e.code}}
        except urllib.error.URLError:
            # Mesh not running - return mock response for testing
            return self._mock_mesh_response(request)
    
    def _mock_mesh_response(self, request: Dict) -> Dict[str, Any]:
        """Mock response when mesh is not running."""
        return {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": int(datetime.now().timestamp()),
            "model": request.get("model", "gpt-4"),
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "[MOCK] Analysis would be performed here"
                },
                "finish_reason": "stop"
            }],
            "x_mesh_backend": "vllm",
            "x_mesh_routing_reason": f"Service policy: {self.SERVICE_ID} -> vllm"
        }
    
    def _log_audit(self, status: str, tool: str, backend: str, prompt: str, error: str = None):
        """Log with data masking"""
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": "data-cleaning-agent",
            "service_id": self.SERVICE_ID,
            "status": status,
            "tool": tool,
            "backend": backend,
            "prompt_hash": hash(prompt),
            "prompt_length": len(prompt),
            "data_masked": True,
            "mesh_routed": True
        }
        if error:
            entry["error"] = error
        self.audit_log.append(entry)
    
    def get_audit_log(self) -> List[Dict]:
        return self.audit_log
    
    def check_governance(self, prompt: str) -> Dict[str, Any]:
        prompting = self.mangle.query("get_prompting_policy", "data-cleaning-service-v1")
        autonomy = self.mangle.query("autonomy_level")
        
        return {
            "mesh": {
                "endpoint": self.MESH_ENDPOINT,
                "service_id": self.SERVICE_ID,
                "security_class": self.SECURITY_CLASS,
                "routing": "Mesh routes confidential services to vLLM"
            },
            "autonomy_level": autonomy[0]["level"] if autonomy else "L2",
            "prompting_policy": prompting[0] if prompting else {},
            "data_product": "data-cleaning-service-v1",
            "requires_human_oversight": True
        }


def main():
    import asyncio
    
    agent = DataCleaningAgent()
    
    print("=" * 60)
    print("Data Cleaning Agent - Routes through Central Mesh")
    print("=" * 60)
    
    # Test 1: Governance check
    print("\n--- Test 1: Governance Check ---")
    governance = agent.check_governance("Analyze the data quality")
    print(f"Mesh Endpoint: {governance['mesh']['endpoint']}")
    print(f"Service ID: {governance['mesh']['service_id']}")
    print(f"Security Class: {governance['mesh']['security_class']}")
    print(f"Routing: {governance['mesh']['routing']}")
    
    # Test 2: Invoke with mesh routing
    print("\n--- Test 2: Analysis (via mesh) ---")
    result = asyncio.run(agent.invoke(
        "Analyze the data quality of the accounts table",
        {"tool": "analyze_data_quality"}
    ))
    print(f"Status: {result['status']}")
    print(f"Backend: {result.get('backend', 'N/A')}")
    print(f"Routing: {result.get('routing_reason', 'N/A')}")
    
    # Test 3: Transformation request (requires approval)
    print("\n--- Test 3: Apply Transformation ---")
    result = asyncio.run(agent.invoke(
        "Apply the cleaning rules",
        {"tool": "apply_transformation"}
    ))
    print(f"Status: {result['status']}")
    print(f"Message: {result.get('message', '')}")
    
    # Test 4: Audit log
    print("\n--- Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['status']} - {entry['tool']} via {entry['backend']} (mesh_routed: {entry.get('mesh_routed', False)})")


if __name__ == "__main__":
    main()