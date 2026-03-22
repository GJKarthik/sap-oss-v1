"""
SAP OSS Service Mesh - Smart Router
Routes requests to AI Core (external) or vLLM (local) based on governance rules.
"""

import json
import os
import urllib.request
from typing import Any, Dict, List, Optional, Tuple
from datetime import datetime, timezone


class MeshRouter:
    """
    Smart router that determines which backend to use based on:
    - Security classification
    - Service policy
    - Content analysis
    - Model mapping
    """
    
    # Backend endpoints
    BACKENDS = {
        "ai-core-streaming": os.environ.get("AICORE_STREAMING_URL", "http://localhost:9190/v1"),
        "vllm": os.environ.get("VLLM_URL", "http://localhost:9180/v1"),
    }
    
    # Security class to backend mapping
    SECURITY_ROUTING = {
        "public": "ai-core-streaming",
        "internal": "ai-core-streaming",
        "confidential": "vllm",
        "restricted": "vllm"
    }
    
    # Service-specific routing overrides
    SERVICE_ROUTING = {
        "data-cleaning-copilot": "vllm",
        "gen-ai-toolkit-hana": "vllm",
        "ai-core-pal": "vllm",
        "langchain-hana": "vllm",  # Default to vLLM, can override
        "odata-vocabularies": "ai-core-streaming",
        "ui5-webcomponents-ngx": "ai-core-streaming",
        "world-monitor": "ai-core-streaming",  # Default, content-based
    }
    
    # Model to backend mapping
    MODEL_BACKEND = {
        # External models (AI Core)
        "gpt-4": "ai-core-streaming",
        "gpt-4-turbo": "ai-core-streaming",
        "gpt-4-turbo-preview": "ai-core-streaming",
        "gpt-3.5-turbo": "ai-core-streaming",
        "claude-3-sonnet": "ai-core-streaming",
        "claude-3-opus": "ai-core-streaming",
        "claude-3-haiku": "ai-core-streaming",
        # Local models (vLLM)
        "llama-3.1-70b": "vllm",
        "llama-3.1-8b": "vllm",
        "codellama-34b": "vllm",
        "mistral-7b": "vllm",
        "mixtral-8x7b": "vllm",
    }
    
    # Model aliases for confidential routing
    MODEL_ALIASES = {
        "gpt-4-confidential": "llama-3.1-70b",
        "gpt-4-turbo-confidential": "llama-3.1-70b",
        "claude-3-confidential": "llama-3.1-70b",
    }
    
    # Confidential keywords
    CONFIDENTIAL_KEYWORDS = [
        "customer", "personal", "private", "confidential",
        "salary", "ssn", "credit_card", "password", "secret"
    ]
    
    def __init__(self):
        self.audit_log: List[Dict] = []

    def validate_request(self, request: Dict, service_id: Optional[str], security_class: Optional[str]) -> Optional[str]:
        """Return an error message if the request violates security policy, or None if OK."""
        if service_id and service_id in self.SERVICE_ROUTING:
            required_backend = self.SERVICE_ROUTING[service_id]
            if required_backend == "vllm" and not security_class:
                return f"Service '{service_id}' requires security_class header for routing"
        return None

    def route(
        self,
        request: Dict[str, Any],
        service_id: Optional[str] = None,
        security_class: Optional[str] = None,
        force_backend: Optional[str] = None,
        trace_id: Optional[str] = None
    ) -> Tuple[str, str, str]:
        """
        Determine which backend to route to.
        
        Returns:
            Tuple of (backend_id, endpoint_url, reason)
        """
        # 0. Validate security headers
        validation_error = self.validate_request(request, service_id, security_class)
        if validation_error:
            import logging
            logging.getLogger(__name__).warning("Security validation: %s", validation_error)

        # 1. Check forced backend (X-Mesh-Routing header)
        if force_backend:
            if force_backend in self.BACKENDS:
                return (
                    force_backend,
                    self.BACKENDS[force_backend],
                    f"Forced routing via header: {force_backend}"
                )
        
        # 2. Check service-specific routing
        if service_id and service_id in self.SERVICE_ROUTING:
            backend = self.SERVICE_ROUTING[service_id]
            return (
                backend,
                self.BACKENDS[backend],
                f"Service policy: {service_id} -> {backend}"
            )
        
        # 3. Check security class routing
        if security_class and security_class in self.SECURITY_ROUTING:
            backend = self.SECURITY_ROUTING[security_class]
            return (
                backend,
                self.BACKENDS[backend],
                f"Security class: {security_class} -> {backend}"
            )
        
        # 4. Check model-based routing
        model = request.get("model", "")
        if model in self.MODEL_ALIASES:
            # Redirect to local model
            actual_model = self.MODEL_ALIASES[model]
            request["model"] = actual_model
            return (
                "vllm",
                self.BACKENDS["vllm"],
                f"Model alias: {model} -> {actual_model} (vllm)"
            )
        
        if model in self.MODEL_BACKEND:
            backend = self.MODEL_BACKEND[model]
            return (
                backend,
                self.BACKENDS[backend],
                f"Model routing: {model} -> {backend}"
            )
        
        # 5. Check content for confidential keywords
        content = self._extract_content(request)
        if self._contains_confidential(content):
            return (
                "vllm",
                self.BACKENDS["vllm"],
                "Content-based routing: confidential keywords detected"
            )
        
        # 6. Default to AI Core
        return (
            "ai-core-streaming",
            self.BACKENDS["ai-core-streaming"],
            "Default routing: ai-core-streaming"
        )
    
    def _extract_content(self, request: Dict[str, Any]) -> str:
        """Extract text content from request for analysis."""
        content_parts = []
        
        # Chat completions
        messages = request.get("messages", [])
        for msg in messages:
            if isinstance(msg, dict) and "content" in msg:
                content_parts.append(str(msg["content"]))
        
        # Completions
        prompt = request.get("prompt", "")
        if prompt:
            content_parts.append(str(prompt))
        
        # Embeddings
        input_text = request.get("input", "")
        if input_text:
            if isinstance(input_text, list):
                content_parts.extend([str(t) for t in input_text])
            else:
                content_parts.append(str(input_text))
        
        return " ".join(content_parts).lower()
    
    def _contains_confidential(self, content: str) -> bool:
        """Check if content contains confidential keywords."""
        for keyword in self.CONFIDENTIAL_KEYWORDS:
            if keyword in content:
                return True
        return False
    
    async def forward_request(
        self,
        endpoint: str,
        path: str,
        request: Dict[str, Any],
        headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """Forward request to backend and return response."""
        url = f"{endpoint}{path}"
        
        req_headers = {"Content-Type": "application/json"}
        if headers:
            req_headers.update(headers)
        
        req = urllib.request.Request(
            url,
            data=json.dumps(request).encode(),
            headers=req_headers,
            method="POST"
        )
        
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            # Return OpenAI-compatible error
            return {
                "error": {
                    "message": e.reason,
                    "type": "api_error",
                    "code": e.code
                }
            }
    
    def log_routing(
        self,
        request_id: str,
        backend: str,
        reason: str,
        model: str,
        status: str,
        trace_id: Optional[str] = None
    ):
        """Log routing decision for audit."""
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "request_id": request_id,
            "backend": backend,
            "reason": reason,
            "model": model,
            "status": status,
        }
        if trace_id:
            entry["trace_id"] = trace_id
        self.audit_log.append(entry)
    
    def get_audit_log(self) -> List[Dict]:
        """Get routing audit log."""
        return self.audit_log


def main():
    """Test router."""
    router = MeshRouter()
    
    print("=" * 60)
    print("SAP OSS Service Mesh - Router Test")
    print("=" * 60)
    
    # Test 1: Default routing
    print("\n--- Test 1: Default routing (no hints) ---")
    backend, url, reason = router.route({"model": "gpt-4", "messages": []})
    print(f"Backend: {backend}")
    print(f"URL: {url}")
    print(f"Reason: {reason}")
    
    # Test 2: Confidential model alias
    print("\n--- Test 2: Confidential model alias ---")
    backend, url, reason = router.route({"model": "gpt-4-confidential", "messages": []})
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    # Test 3: Service-specific routing
    print("\n--- Test 3: Service-specific (data-cleaning) ---")
    backend, url, reason = router.route(
        {"model": "gpt-4", "messages": []},
        service_id="data-cleaning-copilot"
    )
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    # Test 4: Security class routing
    print("\n--- Test 4: Security class (confidential) ---")
    backend, url, reason = router.route(
        {"model": "gpt-4", "messages": []},
        security_class="confidential"
    )
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    # Test 5: Content-based routing
    print("\n--- Test 5: Content-based (customer data) ---")
    backend, url, reason = router.route({
        "model": "gpt-4",
        "messages": [{"role": "user", "content": "Analyze customer payment data"}]
    })
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    # Test 6: Local model
    print("\n--- Test 6: Local model (llama) ---")
    backend, url, reason = router.route({"model": "llama-3.1-70b", "messages": []})
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    # Test 7: Forced routing
    print("\n--- Test 7: Forced routing (header override) ---")
    backend, url, reason = router.route(
        {"model": "gpt-4", "messages": []},
        force_backend="vllm"
    )
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")


if __name__ == "__main__":
    main()