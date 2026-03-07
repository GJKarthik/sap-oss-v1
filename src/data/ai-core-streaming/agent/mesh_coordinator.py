"""
SAP OSS Service Mesh Coordinator Agent

Orchestrates multi-service workflows across all 12 SAP OSS services
with OpenAI-compatible API and governance-based routing.
"""

import json
import yaml
import urllib.request
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone
from pathlib import Path

# Import OpenAI handlers
import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from openai.router import MeshRouter
from openai.chat_completions import ChatCompletionsHandler
from openai.completions import CompletionsHandler
from openai.embeddings import EmbeddingsHandler
from openai.models import ModelsHandler


class MeshCoordinator:
    """
    Central coordinator for SAP OSS Service Mesh.
    
    Provides:
    - Service discovery
    - Request routing with governance
    - Multi-service orchestration
    - Audit logging
    """
    
    def __init__(self, registry_path: Optional[str] = None):
        self.registry_path = registry_path or str(
            Path(__file__).parent.parent / "mesh" / "registry.yaml"
        )
        self.registry = self._load_registry()
        
        # Initialize handlers
        self.router = MeshRouter()
        self.chat_handler = ChatCompletionsHandler(self.router)
        self.completions_handler = CompletionsHandler(self.router)
        self.embeddings_handler = EmbeddingsHandler(self.router)
        self.models_handler = ModelsHandler()
        
        # Audit log
        self.audit_log: List[Dict] = []
    
    def _load_registry(self) -> Dict:
        """Load service registry."""
        try:
            with open(self.registry_path, 'r') as f:
                return yaml.safe_load(f)
        except Exception:
            return {"services": [], "routing": {}}
    
    # =========================================================================
    # SERVICE DISCOVERY
    # =========================================================================
    
    def list_services(self) -> List[Dict]:
        """List all registered services."""
        return self.registry.get("services", [])
    
    def get_service(self, service_id: str) -> Optional[Dict]:
        """Get service by ID."""
        for service in self.registry.get("services", []):
            if service.get("id") == service_id:
                return service
        return None
    
    def discover_by_capability(self, capability: str) -> List[Dict]:
        """Find services with a specific capability."""
        matching = []
        for service in self.registry.get("services", []):
            if capability in service.get("capabilities", []):
                matching.append(service)
        return matching
    
    def discover_by_type(self, service_type: str) -> List[Dict]:
        """Find services of a specific type."""
        matching = []
        for service in self.registry.get("services", []):
            if service.get("type") == service_type:
                matching.append(service)
        return matching
    
    def get_backends(self) -> Dict[str, Dict]:
        """Get LLM backends (AI Core and vLLM)."""
        backends = {}
        for service in self.registry.get("services", []):
            if service.get("type") == "llm-backend":
                backends[service["id"]] = service
        return backends
    
    # =========================================================================
    # OPENAI-COMPATIBLE API
    # =========================================================================
    
    async def chat_completion(
        self,
        request: Dict[str, Any],
        service_id: Optional[str] = None,
        security_class: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        OpenAI-compatible chat completion.
        
        POST /v1/chat/completions
        """
        headers = {}
        if service_id:
            headers["X-Mesh-Service"] = service_id
        if security_class:
            headers["X-Mesh-Security-Class"] = security_class
        
        response = await self.chat_handler.handle(request, headers)
        self._log_request("chat_completion", request, response)
        return response
    
    async def completion(
        self,
        request: Dict[str, Any],
        service_id: Optional[str] = None,
        security_class: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        OpenAI-compatible completion (legacy).
        
        POST /v1/completions
        """
        headers = {}
        if service_id:
            headers["X-Mesh-Service"] = service_id
        if security_class:
            headers["X-Mesh-Security-Class"] = security_class
        
        response = await self.completions_handler.handle(request, headers)
        self._log_request("completion", request, response)
        return response
    
    async def embedding(
        self,
        request: Dict[str, Any],
        service_id: Optional[str] = None,
        security_class: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        OpenAI-compatible embeddings.
        
        POST /v1/embeddings
        """
        headers = {}
        if service_id:
            headers["X-Mesh-Service"] = service_id
        if security_class:
            headers["X-Mesh-Security-Class"] = security_class
        
        response = await self.embeddings_handler.handle(request, headers)
        self._log_request("embedding", request, response)
        return response
    
    def list_models(self) -> Dict[str, Any]:
        """
        OpenAI-compatible model list.
        
        GET /v1/models
        """
        return self.models_handler.list_models()
    
    def get_model(self, model_id: str) -> Dict[str, Any]:
        """
        OpenAI-compatible model details.
        
        GET /v1/models/{model_id}
        """
        return self.models_handler.get_model(model_id)
    
    # =========================================================================
    # GOVERNANCE
    # =========================================================================
    
    def check_routing(
        self,
        request: Dict[str, Any],
        service_id: Optional[str] = None,
        security_class: Optional[str] = None
    ) -> Dict[str, Any]:
        """Check where a request would be routed."""
        backend, endpoint, reason = self.router.route(
            request,
            service_id=service_id,
            security_class=security_class
        )
        return {
            "backend": backend,
            "endpoint": endpoint,
            "reason": reason,
            "model": request.get("model", "unknown")
        }
    
    def get_service_routing(self, service_id: str) -> Dict[str, Any]:
        """Get routing policy for a service."""
        service = self.get_service(service_id)
        if not service:
            return {"error": f"Service '{service_id}' not found"}
        
        return {
            "service_id": service_id,
            "routing": service.get("routing"),
            "security_class": service.get("security_class"),
            "backend": self.router.SERVICE_ROUTING.get(service_id, "default")
        }
    
    # =========================================================================
    # MULTI-SERVICE ORCHESTRATION
    # =========================================================================
    
    async def orchestrate(
        self,
        workflow: List[Dict[str, Any]]
    ) -> List[Dict[str, Any]]:
        """
        Execute a multi-service workflow.
        
        Workflow format:
        [
            {"service": "langchain-hana", "action": "search", "params": {...}},
            {"service": "ai-core-pal", "action": "classify", "params": {...}},
            {"service": "chat", "action": "summarize", "params": {...}}
        ]
        """
        results = []
        context = {}  # Shared context between steps
        
        for i, step in enumerate(workflow):
            service = step.get("service")
            action = step.get("action")
            params = step.get("params", {})
            
            # Inject context from previous steps
            if "context" in params and params["context"] == "$previous":
                params["context"] = context
            
            # Execute step
            try:
                result = await self._execute_step(service, action, params)
                results.append({
                    "step": i,
                    "service": service,
                    "action": action,
                    "status": "success",
                    "result": result
                })
                
                # Update shared context
                context[f"step_{i}"] = result
                
            except Exception as e:
                results.append({
                    "step": i,
                    "service": service,
                    "action": action,
                    "status": "error",
                    "error": str(e)
                })
                break  # Stop on error
        
        return results
    
    async def _execute_step(
        self,
        service: str,
        action: str,
        params: Dict[str, Any]
    ) -> Any:
        """Execute a single workflow step."""
        if service == "chat":
            return await self.chat_completion(params, security_class="internal")
        
        if service == "embedding":
            return await self.embedding(params, security_class="internal")
        
        # For other services, call their MCP endpoint
        service_info = self.get_service(service)
        if not service_info:
            raise ValueError(f"Unknown service: {service}")
        
        mcp_endpoint = service_info.get("mcp_endpoint")
        if not mcp_endpoint:
            raise ValueError(f"Service {service} has no MCP endpoint")
        
        # Call MCP tool
        request_data = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": action, "arguments": params}
        }
        
        req = urllib.request.Request(
            mcp_endpoint,
            data=json.dumps(request_data).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    
    # =========================================================================
    # HEALTH & AUDIT
    # =========================================================================
    
    def health_check(self) -> Dict[str, Any]:
        """Check health of all services."""
        health = {
            "mesh": "healthy",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "services": {}
        }
        
        for service in self.list_services():
            service_id = service.get("id")
            health["services"][service_id] = {
                "endpoint": service.get("endpoint"),
                "status": "unknown"  # Would ping health endpoint in production
            }
        
        return health
    
    def _log_request(self, endpoint: str, request: Dict, response: Dict):
        """Log request for audit."""
        self.audit_log.append({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "endpoint": endpoint,
            "model": request.get("model", "unknown"),
            "backend": response.get("x_mesh_backend", "unknown"),
            "status": "error" if "error" in response else "success"
        })
    
    def get_audit_log(self) -> List[Dict]:
        """Get audit log."""
        return self.audit_log


def main():
    """Test mesh coordinator."""
    import asyncio
    
    coordinator = MeshCoordinator()
    
    print("=" * 60)
    print("SAP OSS Service Mesh Coordinator")
    print("=" * 60)
    
    # Test 1: List services
    print("\n--- Test 1: List Services ---")
    services = coordinator.list_services()
    print(f"Registered services: {len(services)}")
    for svc in services[:5]:
        print(f"  - {svc['id']}: {svc['name']}")
    
    # Test 2: Get backends
    print("\n--- Test 2: LLM Backends ---")
    backends = coordinator.get_backends()
    for backend_id, info in backends.items():
        print(f"  - {backend_id}: {info['endpoint']}")
    
    # Test 3: Discover by capability
    print("\n--- Test 3: Services with embeddings ---")
    services = coordinator.discover_by_capability("embeddings")
    for svc in services:
        print(f"  - {svc['id']}")
    
    # Test 4: List models
    print("\n--- Test 4: Available Models ---")
    models = coordinator.list_models()
    print(f"Total models: {len(models['data'])}")
    for m in models["data"][:5]:
        print(f"  - {m['id']} (owned by: {m['owned_by']})")
    
    # Test 5: Check routing
    print("\n--- Test 5: Routing Check ---")
    request = {"model": "gpt-4", "messages": []}
    routing = coordinator.check_routing(request)
    print(f"Model: {routing['model']}")
    print(f"Backend: {routing['backend']}")
    print(f"Reason: {routing['reason']}")
    
    # Test 6: Confidential routing
    print("\n--- Test 6: Confidential Routing ---")
    request = {
        "model": "gpt-4",
        "messages": [{"role": "user", "content": "Analyze customer salary data"}]
    }
    routing = coordinator.check_routing(request)
    print(f"Backend: {routing['backend']}")
    print(f"Reason: {routing['reason']}")
    
    # Test 7: Service-specific routing
    print("\n--- Test 7: Service Routing (data-cleaning) ---")
    routing = coordinator.get_service_routing("data-cleaning-copilot")
    print(f"Service: {routing.get('service_id')}")
    print(f"Backend: {routing.get('backend')}")
    
    # Test 8: Mock chat completion
    print("\n--- Test 8: Mock Chat Completion ---")
    response = coordinator.chat_handler.create_mock_response(
        {"model": "gpt-4", "messages": [{"role": "user", "content": "Hello"}]},
        "Hello! How can I help you today?",
        backend="ai-core-streaming",
        reason="Model routing: gpt-4"
    )
    print(f"Response ID: {response['id']}")
    print(f"Backend: {response['x_mesh_backend']}")
    print(f"Content: {response['choices'][0]['message']['content'][:50]}...")
    
    # Test 9: Health check
    print("\n--- Test 9: Health Check ---")
    health = coordinator.health_check()
    print(f"Mesh status: {health['mesh']}")
    print(f"Services monitored: {len(health['services'])}")
    
    print("\n" + "=" * 60)
    print("✅ Service Mesh Coordinator Ready!")
    print("=" * 60)
    print("\nOpenAI-Compatible Endpoints:")
    print("  POST /v1/chat/completions")
    print("  POST /v1/completions")
    print("  POST /v1/embeddings")
    print("  GET  /v1/models")
    print("  GET  /v1/models/{model_id}")


if __name__ == "__main__":
    main()