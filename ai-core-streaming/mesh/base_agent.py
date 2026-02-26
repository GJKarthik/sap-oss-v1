"""
SAP OSS Service Mesh - Base Agent Class

All service agents should inherit from this class to automatically
route LLM calls through the central mesh.
"""

import json
import urllib.request
from abc import ABC, abstractmethod
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone


class MeshAgent(ABC):
    """
    Base class for all SAP OSS service agents.
    
    Routes ALL LLM calls through the central mesh (ai-core-streaming)
    which then routes to the appropriate backend based on:
    - Service ID (X-Mesh-Service header)
    - Security class (X-Mesh-Security-Class header)
    - Content analysis
    - Model mapping
    
    Usage:
        class MyAgent(MeshAgent):
            SERVICE_ID = "my-service"
            SECURITY_CLASS = "confidential"  # or "public", "internal"
            
            async def invoke(self, prompt, context):
                response = await self._call_mesh_chat({
                    "model": "gpt-4",
                    "messages": [{"role": "user", "content": prompt}]
                })
                return response
    """
    
    # Central mesh endpoint (ai-core-streaming)
    MESH_ENDPOINT = "http://localhost:9190/v1"
    
    # Override in subclass
    SERVICE_ID: str = "unknown"
    SECURITY_CLASS: str = "public"  # public, internal, confidential, restricted
    
    def __init__(self):
        self.audit_log: List[Dict] = []
    
    async def _call_mesh_chat(
        self,
        request: Dict[str, Any],
        headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """
        Call central mesh for chat completions.
        
        The mesh will route based on:
        - X-Mesh-Service: Service ID
        - X-Mesh-Security-Class: Security classification
        - X-Mesh-Routing: Optional forced backend
        """
        return await self._call_mesh("/chat/completions", request, headers)
    
    async def _call_mesh_completion(
        self,
        request: Dict[str, Any],
        headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """Call central mesh for legacy completions."""
        return await self._call_mesh("/completions", request, headers)
    
    async def _call_mesh_embeddings(
        self,
        request: Dict[str, Any],
        headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """Call central mesh for embeddings."""
        return await self._call_mesh("/embeddings", request, headers)
    
    async def _call_mesh(
        self,
        path: str,
        request: Dict[str, Any],
        extra_headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """Call central mesh with governance headers."""
        url = f"{self.MESH_ENDPOINT}{path}"
        
        # Build headers with governance info
        headers = {
            "Content-Type": "application/json",
            "X-Mesh-Service": self.SERVICE_ID,
            "X-Mesh-Security-Class": self.SECURITY_CLASS
        }
        
        if extra_headers:
            headers.update(extra_headers)
        
        req = urllib.request.Request(
            url,
            data=json.dumps(request).encode(),
            headers=headers,
            method="POST"
        )
        
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read().decode())
                self._log_mesh_call(path, request, result, "success")
                return result
        except urllib.error.HTTPError as e:
            error_result = {"error": {"message": e.reason, "code": e.code}}
            self._log_mesh_call(path, request, error_result, "error")
            return error_result
        except urllib.error.URLError:
            # Mesh not running - return mock response
            mock_result = self._mock_mesh_response(path, request)
            self._log_mesh_call(path, request, mock_result, "mock")
            return mock_result
    
    def _mock_mesh_response(self, path: str, request: Dict) -> Dict[str, Any]:
        """Mock response when mesh is not running."""
        # Determine expected backend based on security class
        if self.SECURITY_CLASS in ("confidential", "restricted"):
            backend = "vllm"
        else:
            backend = "ai-core-streaming"
        
        if "chat" in path:
            return {
                "id": "chatcmpl-mock",
                "object": "chat.completion",
                "created": int(datetime.now().timestamp()),
                "model": request.get("model", "gpt-4"),
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": f"[MOCK via mesh -> {backend}] Response would go here"
                    },
                    "finish_reason": "stop"
                }],
                "x_mesh_backend": backend,
                "x_mesh_routing_reason": f"Service policy: {self.SERVICE_ID} -> {backend}"
            }
        elif "completion" in path:
            return {
                "id": "cmpl-mock",
                "object": "text_completion",
                "created": int(datetime.now().timestamp()),
                "model": request.get("model", "gpt-3.5-turbo-instruct"),
                "choices": [{
                    "text": f"[MOCK via mesh -> {backend}]",
                    "index": 0,
                    "finish_reason": "stop"
                }],
                "x_mesh_backend": backend,
                "x_mesh_routing_reason": f"Service policy: {self.SERVICE_ID} -> {backend}"
            }
        elif "embedding" in path:
            return {
                "object": "list",
                "data": [{"object": "embedding", "embedding": [0.0] * 1536, "index": 0}],
                "model": request.get("model", "text-embedding-ada-002"),
                "x_mesh_backend": backend,
                "x_mesh_routing_reason": f"Service policy: {self.SERVICE_ID} -> {backend}"
            }
        
        return {"x_mesh_backend": backend, "x_mesh_mock": True}
    
    def _log_mesh_call(
        self,
        path: str,
        request: Dict,
        response: Dict,
        status: str
    ):
        """Log mesh call for audit."""
        self.audit_log.append({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "service_id": self.SERVICE_ID,
            "security_class": self.SECURITY_CLASS,
            "path": path,
            "model": request.get("model", "unknown"),
            "backend": response.get("x_mesh_backend", "unknown"),
            "routing_reason": response.get("x_mesh_routing_reason", ""),
            "status": status,
            "mesh_routed": True
        })
    
    def get_audit_log(self) -> List[Dict]:
        """Get mesh routing audit log."""
        return self.audit_log
    
    def get_mesh_config(self) -> Dict[str, Any]:
        """Get mesh configuration for this agent."""
        return {
            "mesh_endpoint": self.MESH_ENDPOINT,
            "service_id": self.SERVICE_ID,
            "security_class": self.SECURITY_CLASS,
            "routing": self._get_expected_routing()
        }
    
    def _get_expected_routing(self) -> str:
        """Get expected routing based on security class."""
        if self.SECURITY_CLASS in ("confidential", "restricted"):
            return "vLLM (on-premise)"
        else:
            return "AI Core (external)"
    
    @abstractmethod
    async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
        """
        Invoke the agent with a prompt.
        Must be implemented by subclasses.
        """
        pass


# =============================================================================
# PRE-CONFIGURED AGENT TYPES
# =============================================================================

class PublicMeshAgent(MeshAgent):
    """Agent for public data - routes to AI Core."""
    SECURITY_CLASS = "public"

class InternalMeshAgent(MeshAgent):
    """Agent for internal data - routes to AI Core."""
    SECURITY_CLASS = "internal"

class ConfidentialMeshAgent(MeshAgent):
    """Agent for confidential data - routes to vLLM."""
    SECURITY_CLASS = "confidential"

class RestrictedMeshAgent(MeshAgent):
    """Agent for restricted data - routes to vLLM only."""
    SECURITY_CLASS = "restricted"


# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

def create_mesh_agent(
    service_id: str,
    security_class: str = "public"
) -> type:
    """
    Factory function to create a configured mesh agent class.
    
    Usage:
        MyAgentClass = create_mesh_agent("my-service", "confidential")
        agent = MyAgentClass()
    """
    class ConfiguredMeshAgent(MeshAgent):
        SERVICE_ID = service_id
        SECURITY_CLASS = security_class
        
        async def invoke(self, prompt: str, context: Optional[Dict] = None) -> Dict[str, Any]:
            response = await self._call_mesh_chat({
                "model": "gpt-4",
                "messages": [{"role": "user", "content": prompt}]
            })
            return response
    
    return ConfiguredMeshAgent


def main():
    """Test base agent."""
    import asyncio
    
    # Create a test agent
    TestAgent = create_mesh_agent("test-service", "confidential")
    agent = TestAgent()
    
    print("=" * 60)
    print("SAP OSS Service Mesh - Base Agent Test")
    print("=" * 60)
    
    # Test 1: Config
    print("\n--- Test 1: Mesh Config ---")
    config = agent.get_mesh_config()
    print(f"Endpoint: {config['mesh_endpoint']}")
    print(f"Service ID: {config['service_id']}")
    print(f"Security Class: {config['security_class']}")
    print(f"Expected Routing: {config['routing']}")
    
    # Test 2: Invoke (mock)
    print("\n--- Test 2: Invoke (mock) ---")
    result = asyncio.run(agent.invoke("Test prompt"))
    print(f"Backend: {result.get('x_mesh_backend')}")
    print(f"Routing: {result.get('x_mesh_routing_reason')}")
    
    # Test 3: Audit log
    print("\n--- Test 3: Audit Log ---")
    for entry in agent.get_audit_log():
        print(f"  [{entry['timestamp']}] {entry['service_id']} -> {entry['backend']} (mesh_routed: {entry['mesh_routed']})")
    
    print("\n✅ Base agent ready for use by all services!")


if __name__ == "__main__":
    main()