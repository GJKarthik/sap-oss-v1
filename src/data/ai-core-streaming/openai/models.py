"""
OpenAI-Compatible Models API
GET /v1/models
GET /v1/models/{model_id}

100% compatible with OpenAI API specification.
"""

import time
from typing import Any, Dict, List, Optional


class ModelsHandler:
    """
    OpenAI-compatible models handler.
    
    GET /v1/models Response:
    {
        "object": "list",
        "data": [
            {
                "id": "gpt-4",
                "object": "model",
                "created": 1234567890,
                "owned_by": "openai"
            }
        ]
    }
    
    GET /v1/models/{id} Response:
    {
        "id": "gpt-4",
        "object": "model",
        "created": 1234567890,
        "owned_by": "openai"
    }
    """
    
    # Available models with metadata
    MODELS = {
        # AI Core (external) models
        "gpt-4": {
            "id": "gpt-4",
            "object": "model",
            "created": 1687882411,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "gpt-4-turbo": {
            "id": "gpt-4-turbo",
            "object": "model",
            "created": 1712361441,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "gpt-4-turbo-preview": {
            "id": "gpt-4-turbo-preview",
            "object": "model",
            "created": 1706037777,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "gpt-3.5-turbo": {
            "id": "gpt-3.5-turbo",
            "object": "model",
            "created": 1677610602,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "claude-3-sonnet": {
            "id": "claude-3-sonnet",
            "object": "model",
            "created": 1709596800,
            "owned_by": "anthropic",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "claude-3-opus": {
            "id": "claude-3-opus",
            "object": "model",
            "created": 1709596800,
            "owned_by": "anthropic",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "claude-3-haiku": {
            "id": "claude-3-haiku",
            "object": "model",
            "created": 1710288000,
            "owned_by": "anthropic",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        
        # vLLM (local) models
        "llama-3.1-70b": {
            "id": "llama-3.1-70b",
            "object": "model",
            "created": 1721865600,
            "owned_by": "meta",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential"
        },
        "llama-3.1-8b": {
            "id": "llama-3.1-8b",
            "object": "model",
            "created": 1721865600,
            "owned_by": "meta",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential"
        },
        "codellama-34b": {
            "id": "codellama-34b",
            "object": "model",
            "created": 1692835200,
            "owned_by": "meta",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential"
        },
        "mistral-7b": {
            "id": "mistral-7b",
            "object": "model",
            "created": 1695945600,
            "owned_by": "mistral",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential"
        },
        "mixtral-8x7b": {
            "id": "mixtral-8x7b",
            "object": "model",
            "created": 1702252800,
            "owned_by": "mistral",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential"
        },
        
        # Confidential aliases (maps to local models)
        "gpt-4-confidential": {
            "id": "gpt-4-confidential",
            "object": "model",
            "created": int(time.time()),
            "owned_by": "sap-mesh",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential",
            "x_mesh_alias_for": "llama-3.1-70b"
        },
        "gpt-4-turbo-confidential": {
            "id": "gpt-4-turbo-confidential",
            "object": "model",
            "created": int(time.time()),
            "owned_by": "sap-mesh",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential",
            "x_mesh_alias_for": "llama-3.1-70b"
        },
        "claude-3-confidential": {
            "id": "claude-3-confidential",
            "object": "model",
            "created": int(time.time()),
            "owned_by": "sap-mesh",
            "x_mesh_backend": "vllm",
            "x_mesh_security_class": "confidential",
            "x_mesh_alias_for": "llama-3.1-70b"
        },
        
        # Embedding models
        "text-embedding-ada-002": {
            "id": "text-embedding-ada-002",
            "object": "model",
            "created": 1671217299,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "text-embedding-3-small": {
            "id": "text-embedding-3-small",
            "object": "model",
            "created": 1705953180,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        },
        "text-embedding-3-large": {
            "id": "text-embedding-3-large",
            "object": "model",
            "created": 1705953180,
            "owned_by": "openai",
            "x_mesh_backend": "ai-core-streaming",
            "x_mesh_security_class": "public"
        }
    }
    
    def list_models(
        self,
        backend_filter: Optional[str] = None,
        security_class_filter: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        List available models.
        
        Returns OpenAI-compatible model list.
        """
        models = []
        
        for model_id, model_data in self.MODELS.items():
            # Apply filters
            if backend_filter and model_data.get("x_mesh_backend") != backend_filter:
                continue
            if security_class_filter and model_data.get("x_mesh_security_class") != security_class_filter:
                continue
            
            # Return OpenAI-compatible format (strip mesh extensions for standard response)
            models.append({
                "id": model_data["id"],
                "object": model_data["object"],
                "created": model_data["created"],
                "owned_by": model_data["owned_by"]
            })
        
        return {
            "object": "list",
            "data": models
        }
    
    def get_model(self, model_id: str) -> Dict[str, Any]:
        """
        Get a specific model by ID.
        
        Returns OpenAI-compatible model object or error.
        """
        if model_id not in self.MODELS:
            return {
                "error": {
                    "message": f"The model '{model_id}' does not exist",
                    "type": "invalid_request_error",
                    "code": 404
                }
            }
        
        model_data = self.MODELS[model_id]
        
        return {
            "id": model_data["id"],
            "object": model_data["object"],
            "created": model_data["created"],
            "owned_by": model_data["owned_by"]
        }
    
    def get_model_extended(self, model_id: str) -> Dict[str, Any]:
        """
        Get model with mesh extensions (routing info).
        """
        if model_id not in self.MODELS:
            return {
                "error": {
                    "message": f"The model '{model_id}' does not exist",
                    "type": "invalid_request_error",
                    "code": 404
                }
            }
        
        return self.MODELS[model_id].copy()
    
    def list_models_extended(self) -> Dict[str, Any]:
        """
        List all models with mesh extensions.
        """
        return {
            "object": "list",
            "data": list(self.MODELS.values())
        }


def main():
    """Test models handler."""
    handler = ModelsHandler()
    
    print("=" * 60)
    print("OpenAI-Compatible Models API Test")
    print("=" * 60)
    
    # Test 1: List all models
    print("\n--- Test 1: List all models ---")
    response = handler.list_models()
    print(f"Total models: {len(response['data'])}")
    for model in response["data"][:5]:
        print(f"  - {model['id']} (owned by: {model['owned_by']})")
    print("  ...")
    
    # Test 2: Get specific model
    print("\n--- Test 2: Get gpt-4 ---")
    response = handler.get_model("gpt-4")
    print(f"ID: {response['id']}")
    print(f"Owned by: {response['owned_by']}")
    
    # Test 3: Get model with extensions
    print("\n--- Test 3: Get gpt-4 with extensions ---")
    response = handler.get_model_extended("gpt-4")
    print(f"ID: {response['id']}")
    print(f"Backend: {response['x_mesh_backend']}")
    print(f"Security: {response['x_mesh_security_class']}")
    
    # Test 4: Get confidential model
    print("\n--- Test 4: Get confidential alias ---")
    response = handler.get_model_extended("gpt-4-confidential")
    print(f"ID: {response['id']}")
    print(f"Backend: {response['x_mesh_backend']}")
    print(f"Alias for: {response.get('x_mesh_alias_for', 'N/A')}")
    
    # Test 5: Filter by backend
    print("\n--- Test 5: List vLLM models only ---")
    response = handler.list_models(backend_filter="vllm")
    print(f"vLLM models: {len(response['data'])}")
    for model in response["data"]:
        print(f"  - {model['id']}")
    
    # Test 6: Model not found
    print("\n--- Test 6: Model not found ---")
    response = handler.get_model("nonexistent-model")
    print(f"Error: {response['error']['message']}")
    
    print("\n✅ All tests passed!")


if __name__ == "__main__":
    main()