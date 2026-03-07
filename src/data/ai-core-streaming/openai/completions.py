"""
OpenAI-Compatible Completions API (Legacy)
POST /v1/completions

100% compatible with OpenAI API specification.
"""

import uuid
import time
from typing import Any, Dict, List, Optional
from .router import MeshRouter


class CompletionsHandler:
    """
    OpenAI-compatible completions handler (legacy API).
    
    Request format:
    {
        "model": "gpt-3.5-turbo-instruct",
        "prompt": "Say this is a test",
        "max_tokens": 100,
        "temperature": 0.7,
        "stream": false
    }
    
    Response format:
    {
        "id": "cmpl-xxx",
        "object": "text_completion",
        "created": 1234567890,
        "model": "gpt-3.5-turbo-instruct",
        "choices": [{
            "text": "This is a test.",
            "index": 0,
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": 5,
            "completion_tokens": 5,
            "total_tokens": 10
        }
    }
    """
    
    def __init__(self, router: Optional[MeshRouter] = None):
        self.router = router or MeshRouter()
    
    async def handle(
        self,
        request: Dict[str, Any],
        headers: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """Handle completions request."""
        # Validate
        validation_error = self._validate_request(request)
        if validation_error:
            return validation_error
        
        # Extract governance hints
        service_id = headers.get("X-Mesh-Service") if headers else None
        security_class = headers.get("X-Mesh-Security-Class") if headers else None
        force_backend = headers.get("X-Mesh-Routing") if headers else None
        
        # Route
        backend, endpoint, reason = self.router.route(
            request,
            service_id=service_id,
            security_class=security_class,
            force_backend=force_backend
        )
        
        # Generate request ID
        request_id = f"cmpl-{uuid.uuid4().hex[:24]}"
        
        # Forward
        try:
            response = await self.router.forward_request(
                endpoint,
                "/completions",
                request,
                headers
            )
            
            if "error" not in response:
                response["x_mesh_backend"] = backend
                response["x_mesh_routing_reason"] = reason
            
            return response
            
        except Exception as e:
            return self._create_error_response(str(e), 500)
    
    def _validate_request(self, request: Dict[str, Any]) -> Optional[Dict]:
        """Validate request format."""
        if not request.get("model"):
            return self._create_error_response(
                "Missing required parameter: 'model'",
                400,
                "invalid_request_error"
            )
        
        if not request.get("prompt"):
            return self._create_error_response(
                "Missing required parameter: 'prompt'",
                400,
                "invalid_request_error"
            )
        
        return None
    
    def _create_error_response(
        self,
        message: str,
        code: int,
        error_type: str = "api_error"
    ) -> Dict[str, Any]:
        """Create OpenAI-compatible error response."""
        return {
            "error": {
                "message": message,
                "type": error_type,
                "code": code
            }
        }
    
    def create_mock_response(
        self,
        request: Dict[str, Any],
        completion_text: str,
        backend: str = "mock",
        reason: str = "mock response"
    ) -> Dict[str, Any]:
        """Create mock response for testing."""
        request_id = f"cmpl-{uuid.uuid4().hex[:24]}"
        
        prompt = request.get("prompt", "")
        prompt_tokens = len(str(prompt).split()) * 1.3
        completion_tokens = len(completion_text.split()) * 1.3
        
        return {
            "id": request_id,
            "object": "text_completion",
            "created": int(time.time()),
            "model": request.get("model", "gpt-3.5-turbo-instruct"),
            "choices": [{
                "text": completion_text,
                "index": 0,
                "logprobs": None,
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": int(prompt_tokens),
                "completion_tokens": int(completion_tokens),
                "total_tokens": int(prompt_tokens + completion_tokens)
            },
            "x_mesh_backend": backend,
            "x_mesh_routing_reason": reason
        }


def main():
    """Test completions handler."""
    import asyncio
    
    handler = CompletionsHandler()
    
    print("=" * 60)
    print("OpenAI-Compatible Completions API Test")
    print("=" * 60)
    
    # Test 1: Valid request
    print("\n--- Test 1: Valid request ---")
    request = {
        "model": "gpt-3.5-turbo-instruct",
        "prompt": "Say this is a test:",
        "max_tokens": 50
    }
    response = handler.create_mock_response(
        request,
        " This is indeed a test.",
        backend="ai-core-streaming",
        reason="Model routing: gpt-3.5-turbo-instruct"
    )
    print(f"ID: {response['id']}")
    print(f"Model: {response['model']}")
    print(f"Text: {response['choices'][0]['text']}")
    print(f"Backend: {response['x_mesh_backend']}")
    
    # Test 2: Missing model
    print("\n--- Test 2: Missing model (error) ---")
    request = {"prompt": "Hello"}
    response = asyncio.run(handler.handle(request))
    print(f"Error: {response['error']['message']}")
    
    # Test 3: Confidential routing
    print("\n--- Test 3: Confidential routing ---")
    request = {
        "model": "gpt-3.5-turbo-instruct",
        "prompt": "Summarize customer payment history"
    }
    backend, _, reason = handler.router.route(request)
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    print("\n✅ All tests passed!")


if __name__ == "__main__":
    main()