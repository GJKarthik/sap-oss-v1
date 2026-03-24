# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
ModelOpt Client for Fine-Tuned Model Integration.

Connects to the nvidia-modelopt service for inference with
fine-tuned Qwen models, and integrates with the vLLM router
for PII-aware routing.
"""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional
import json
import logging
import os

logger = logging.getLogger(__name__)

# Try to import httpx for async HTTP
try:
    import httpx
    HAS_HTTPX = True
except ImportError:
    HAS_HTTPX = False


@dataclass
class ModelInfo:
    """Information about a deployed model."""
    
    model_id: str
    name: str
    base_model: str
    quantization: Optional[str] = None
    fine_tuned: bool = False
    domain: str = ""  # e.g., "treasury", "esg", "performance"
    loaded: bool = False
    memory_gb: float = 0.0


@dataclass
class InferenceRequest:
    """Request for model inference."""
    
    messages: list[dict]  # OpenAI-format messages
    model: str = "qwen-3.5-finetuned"
    temperature: float = 0.7
    max_tokens: int = 2048
    stream: bool = False
    
    # Metadata for routing
    table_context: Optional[str] = None
    data_class: Optional[str] = None


@dataclass
class InferenceResponse:
    """Response from model inference."""
    
    content: str
    model: str
    backend: str
    tokens_used: int = 0
    latency_ms: float = 0.0
    metadata: dict = field(default_factory=dict)


class ModelOptClient:
    """
    Client for nvidia-modelopt service.
    
    Provides inference with fine-tuned models and integrates
    with the data products for domain-specific routing.
    """
    
    # Default models from training configuration
    DEFAULT_MODELS = {
        "qwen-3.5-finetuned": ModelInfo(
            model_id="qwen-3.5-finetuned",
            name="Qwen 3.5 Fine-tuned for HANA",
            base_model="Qwen/Qwen2.5-3B-Instruct",
            quantization="AWQ",
            fine_tuned=True,
            domain="general",
        ),
        "qwen-treasury": ModelInfo(
            model_id="qwen-treasury",
            name="Qwen Treasury Specialist",
            base_model="Qwen/Qwen2.5-3B-Instruct",
            fine_tuned=True,
            domain="treasury",
        ),
        "qwen-esg": ModelInfo(
            model_id="qwen-esg",
            name="Qwen ESG Specialist",
            base_model="Qwen/Qwen2.5-3B-Instruct",
            fine_tuned=True,
            domain="esg",
        ),
        "qwen-performance": ModelInfo(
            model_id="qwen-performance",
            name="Qwen Performance Specialist",
            base_model="Qwen/Qwen2.5-3B-Instruct",
            fine_tuned=True,
            domain="performance",
        ),
        "llama-3.1-70b": ModelInfo(
            model_id="llama-3.1-70b",
            name="Llama 3.1 70B",
            base_model="meta-llama/Llama-3.1-70B-Instruct",
            quantization="GPTQ",
            fine_tuned=False,
            domain="general",
        ),
    }
    
    # Domain routing - which model to use for which data product domain
    DOMAIN_ROUTING = {
        "treasury": "qwen-treasury",
        "Treasury": "qwen-treasury",
        "esg": "qwen-esg",
        "ESG": "qwen-esg",
        "performance": "qwen-performance",
        "Performance": "qwen-performance",
    }
    
    def __init__(
        self,
        modelopt_url: Optional[str] = None,
        api_key: Optional[str] = None,
        timeout: float = 30.0,
    ):
        """
        Initialize client.
        
        Args:
            modelopt_url: URL of nvidia-modelopt service
            api_key: API key for authentication
            timeout: Request timeout in seconds
        """
        self.modelopt_url = modelopt_url or os.getenv(
            "MODELOPT_URL", "http://localhost:8001"
        )
        self.api_key = api_key or os.getenv("MODELOPT_API_KEY", "")
        self.timeout = timeout
        self._available = None
        self._models: dict[str, ModelInfo] = {}
    
    def _get_headers(self) -> dict[str, str]:
        """Get request headers."""
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers
    
    async def check_health(self) -> bool:
        """
        Check if ModelOpt service is available.
        
        Returns:
            True if healthy
        """
        if not HAS_HTTPX:
            return False
        
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(f"{self.modelopt_url}/health")
                self._available = response.status_code == 200
                return self._available
        except Exception as e:
            logger.warning(f"ModelOpt health check failed: {e}")
            self._available = False
            return False
    
    def check_health_sync(self) -> bool:
        """Synchronous health check."""
        if not HAS_HTTPX:
            return False
        
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(f"{self.modelopt_url}/health")
                self._available = response.status_code == 200
                return self._available
        except Exception:
            self._available = False
            return False
    
    def available(self) -> bool:
        """Check if service was available at last check."""
        if self._available is None:
            return self.check_health_sync()
        return self._available
    
    async def list_models(self) -> list[ModelInfo]:
        """
        List available models from ModelOpt service.
        
        Returns:
            List of ModelInfo
        """
        if not HAS_HTTPX:
            return list(self.DEFAULT_MODELS.values())
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.get(
                    f"{self.modelopt_url}/v1/models",
                    headers=self._get_headers(),
                )
                if response.status_code == 200:
                    data = response.json()
                    models = []
                    for m in data.get("data", []):
                        model = ModelInfo(
                            model_id=m.get("id", ""),
                            name=m.get("name", m.get("id", "")),
                            base_model=m.get("base_model", ""),
                            quantization=m.get("quantization"),
                            fine_tuned=m.get("fine_tuned", False),
                            domain=m.get("domain", "general"),
                            loaded=m.get("loaded", False),
                            memory_gb=m.get("memory_gb", 0),
                        )
                        models.append(model)
                        self._models[model.model_id] = model
                    return models
        except Exception as e:
            logger.warning(f"Failed to list models: {e}")
        
        return list(self.DEFAULT_MODELS.values())
    
    def get_model_for_domain(self, domain: str) -> str:
        """
        Get the best model for a domain.
        
        Args:
            domain: Data product domain (treasury, esg, performance)
            
        Returns:
            Model ID to use
        """
        return self.DOMAIN_ROUTING.get(domain, "qwen-3.5-finetuned")
    
    async def infer(self, request: InferenceRequest) -> InferenceResponse:
        """
        Run inference on a model.
        
        Args:
            request: Inference request
            
        Returns:
            Inference response
        """
        start_time = datetime.utcnow()
        
        # Select model based on domain if not specified
        model = request.model
        if request.data_class and request.data_class in self.DOMAIN_ROUTING:
            model = self.DOMAIN_ROUTING[request.data_class]
        
        if not HAS_HTTPX or not self.available():
            return self._mock_inference(request, model, start_time)
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                payload = {
                    "model": model,
                    "messages": request.messages,
                    "temperature": request.temperature,
                    "max_tokens": request.max_tokens,
                    "stream": request.stream,
                }
                
                response = await client.post(
                    f"{self.modelopt_url}/v1/chat/completions",
                    headers=self._get_headers(),
                    json=payload,
                )
                
                if response.status_code == 200:
                    data = response.json()
                    latency = (datetime.utcnow() - start_time).total_seconds() * 1000
                    
                    return InferenceResponse(
                        content=data["choices"][0]["message"]["content"],
                        model=model,
                        backend="modelopt",
                        tokens_used=data.get("usage", {}).get("total_tokens", 0),
                        latency_ms=latency,
                        metadata={
                            "finish_reason": data["choices"][0].get("finish_reason"),
                        },
                    )
                else:
                    logger.error(f"ModelOpt inference failed: {response.status_code}")
                    return self._mock_inference(request, model, start_time)
        except Exception as e:
            logger.error(f"ModelOpt inference error: {e}")
            return self._mock_inference(request, model, start_time)
    
    def infer_sync(self, request: InferenceRequest) -> InferenceResponse:
        """Synchronous inference."""
        start_time = datetime.utcnow()
        
        model = request.model
        if request.data_class and request.data_class in self.DOMAIN_ROUTING:
            model = self.DOMAIN_ROUTING[request.data_class]
        
        if not HAS_HTTPX or not self.available():
            return self._mock_inference(request, model, start_time)
        
        try:
            with httpx.Client(timeout=self.timeout) as client:
                payload = {
                    "model": model,
                    "messages": request.messages,
                    "temperature": request.temperature,
                    "max_tokens": request.max_tokens,
                }
                
                response = client.post(
                    f"{self.modelopt_url}/v1/chat/completions",
                    headers=self._get_headers(),
                    json=payload,
                )
                
                if response.status_code == 200:
                    data = response.json()
                    latency = (datetime.utcnow() - start_time).total_seconds() * 1000
                    
                    return InferenceResponse(
                        content=data["choices"][0]["message"]["content"],
                        model=model,
                        backend="modelopt",
                        tokens_used=data.get("usage", {}).get("total_tokens", 0),
                        latency_ms=latency,
                    )
        except Exception as e:
            logger.error(f"ModelOpt sync inference error: {e}")
        
        return self._mock_inference(request, model, start_time)
    
    def _mock_inference(
        self,
        request: InferenceRequest,
        model: str,
        start_time: datetime,
    ) -> InferenceResponse:
        """Generate mock response when service unavailable."""
        latency = (datetime.utcnow() - start_time).total_seconds() * 1000
        
        # Generate contextual mock response
        last_message = request.messages[-1]["content"] if request.messages else ""
        
        if "treasury" in model.lower() or "capital" in last_message.lower():
            content = (
                "Based on the Treasury Capital Markets data, I can help you query "
                "accounts, cost centers, and location data. Please specify the "
                "account IDs or cost centers you'd like to analyze."
            )
        elif "esg" in model.lower() or "sustainability" in last_message.lower():
            content = (
                "I can help you analyze ESG sustainability metrics including "
                "carbon footprint data, sustainability scores, and client-level "
                "environmental indicators. What specific metrics would you like to query?"
            )
        elif "performance" in model.lower() or "bpc" in last_message.lower():
            content = (
                "For Performance BPC analysis, I can query fact tables for period "
                "amounts, currency conversions, and account hierarchies. "
                "What time period and accounts are you interested in?"
            )
        else:
            content = (
                "I'm a fine-tuned model for HANA data queries. I can help you "
                "generate SQL queries for Treasury, ESG, or Performance data. "
                "What would you like to analyze?"
            )
        
        return InferenceResponse(
            content=content,
            model=model,
            backend="modelopt-mock",
            tokens_used=len(content.split()),
            latency_ms=latency,
            metadata={"mock": True},
        )


# =============================================================================
# vLLM Router Integration
# =============================================================================

def integrate_with_router(router):
    """
    Integrate ModelOpt client with the vLLM router.
    
    Adds the fine-tuned models as a backend option for
    confidential HANA data.
    
    Args:
        router: LLMRouter instance from llm/router.py
    """
    # Add modelopt as a backend
    router.add_backend(
        name="modelopt",
        endpoint=os.getenv("MODELOPT_URL", "http://localhost:8001"),
        models=list(ModelOptClient.DEFAULT_MODELS.keys()),
        for_security_class=["confidential", "restricted"],
    )


def get_routing_recommendation(
    message: str,
    data_class: Optional[str] = None,
    contains_pii: bool = False,
) -> dict:
    """
    Get routing recommendation for a message.
    
    Args:
        message: User message
        data_class: Data classification (confidential, internal, etc.)
        contains_pii: Whether message contains PII
        
    Returns:
        Routing recommendation
    """
    client = get_client()
    
    # Always use local models for HANA data
    if data_class in ["confidential", "restricted"] or contains_pii:
        backend = "modelopt"
        
        # Select specialist model based on content
        domain = "general"
        lower_msg = message.lower()
        
        if any(kw in lower_msg for kw in ["treasury", "capital", "account", "nfrp"]):
            domain = "treasury"
        elif any(kw in lower_msg for kw in ["esg", "sustainability", "carbon", "climate"]):
            domain = "esg"
        elif any(kw in lower_msg for kw in ["performance", "bpc", "budget", "forecast"]):
            domain = "performance"
        
        model = client.get_model_for_domain(domain)
        
        return {
            "backend": backend,
            "model": model,
            "domain": domain,
            "reason": "Confidential HANA data routed to fine-tuned local model",
            "pii_safe": True,
        }
    
    # Non-sensitive data can use cloud models
    return {
        "backend": "aicore",
        "model": "gpt-4-turbo",
        "domain": "general",
        "reason": "Non-sensitive data can use cloud backend",
        "pii_safe": data_class not in ["confidential", "restricted"],
    }


# =============================================================================
# Module-level singleton
# =============================================================================

_client: Optional[ModelOptClient] = None


def get_client() -> ModelOptClient:
    """Get singleton client instance."""
    global _client
    if _client is None:
        _client = ModelOptClient()
    return _client


def infer(
    messages: list[dict],
    model: Optional[str] = None,
    data_class: Optional[str] = None,
) -> dict:
    """
    Run inference with automatic routing.
    
    Args:
        messages: Chat messages
        model: Optional model override
        data_class: Data classification for routing
        
    Returns:
        Inference result dict
    """
    client = get_client()
    
    request = InferenceRequest(
        messages=messages,
        model=model or "qwen-3.5-finetuned",
        data_class=data_class,
    )
    
    response = client.infer_sync(request)
    
    return {
        "content": response.content,
        "model": response.model,
        "backend": response.backend,
        "tokens_used": response.tokens_used,
        "latency_ms": response.latency_ms,
    }