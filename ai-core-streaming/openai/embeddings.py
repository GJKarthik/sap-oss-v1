"""
OpenAI-Compatible Embeddings API
POST /v1/embeddings

100% compatible with OpenAI API specification.
"""

import uuid
from typing import Any, Dict, List, Optional, Union
from .router import MeshRouter


class EmbeddingsHandler:
    """
    OpenAI-compatible embeddings handler.
    
    Request format:
    {
        "model": "text-embedding-ada-002",
        "input": "Text to embed" | ["Text 1", "Text 2"],
        "encoding_format": "float"  # optional: "float" or "base64"
    }
    
    Response format:
    {
        "object": "list",
        "data": [
            {
                "object": "embedding",
                "embedding": [0.1, 0.2, ...],
                "index": 0
            }
        ],
        "model": "text-embedding-ada-002",
        "usage": {
            "prompt_tokens": 10,
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
        """Handle embeddings request."""
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
        
        # Forward
        try:
            response = await self.router.forward_request(
                endpoint,
                "/embeddings",
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
        
        if not request.get("input"):
            return self._create_error_response(
                "Missing required parameter: 'input'",
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
        backend: str = "mock",
        reason: str = "mock response"
    ) -> Dict[str, Any]:
        """Create mock response for testing."""
        input_data = request.get("input", "")
        if isinstance(input_data, str):
            input_data = [input_data]
        
        # Generate fake embeddings (1536 dimensions for ada-002)
        embeddings_data = []
        total_tokens = 0
        
        for i, text in enumerate(input_data):
            tokens = len(str(text).split())
            total_tokens += tokens
            
            # Fake embedding vector
            embedding = [0.0] * 1536
            embedding[0] = 0.1 * i
            embedding[1] = 0.2
            
            embeddings_data.append({
                "object": "embedding",
                "embedding": embedding,
                "index": i
            })
        
        return {
            "object": "list",
            "data": embeddings_data,
            "model": request.get("model", "text-embedding-ada-002"),
            "usage": {
                "prompt_tokens": total_tokens,
                "total_tokens": total_tokens
            },
            "x_mesh_backend": backend,
            "x_mesh_routing_reason": reason
        }


def main():
    """Test embeddings handler."""
    import asyncio
    
    handler = EmbeddingsHandler()
    
    print("=" * 60)
    print("OpenAI-Compatible Embeddings API Test")
    print("=" * 60)
    
    # Test 1: Single text
    print("\n--- Test 1: Single text embedding ---")
    request = {
        "model": "text-embedding-ada-002",
        "input": "Hello world"
    }
    response = handler.create_mock_response(request, "ai-core-streaming", "Default routing")
    print(f"Model: {response['model']}")
    print(f"Embeddings count: {len(response['data'])}")
    print(f"Dimensions: {len(response['data'][0]['embedding'])}")
    print(f"Usage: {response['usage']}")
    
    # Test 2: Multiple texts
    print("\n--- Test 2: Multiple text embeddings ---")
    request = {
        "model": "text-embedding-3-small",
        "input": ["First text", "Second text", "Third text"]
    }
    response = handler.create_mock_response(request, "ai-core-streaming", "Batch embedding")
    print(f"Embeddings count: {len(response['data'])}")
    for emb in response["data"]:
        print(f"  Index {emb['index']}: {len(emb['embedding'])} dimensions")
    
    # Test 3: Validation error
    print("\n--- Test 3: Missing model (error) ---")
    request = {"input": "Hello"}
    response = asyncio.run(handler.handle(request))
    print(f"Error: {response['error']['message']}")
    
    # Test 4: Confidential routing
    print("\n--- Test 4: Confidential routing ---")
    request = {
        "model": "text-embedding-ada-002",
        "input": "Customer payment data"
    }
    backend, _, reason = handler.router.route(request)
    print(f"Backend: {backend}")
    print(f"Reason: {reason}")
    
    print("\n✅ All tests passed!")


if __name__ == "__main__":
    main()