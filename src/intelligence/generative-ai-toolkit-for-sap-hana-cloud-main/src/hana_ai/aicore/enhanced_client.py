# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Enhanced SAP AI Core Client for HANA Cloud Generative AI Toolkit.

Provides advanced features for AI Core Foundation Model integration:
- Intelligent model routing (cost/latency optimization)
- Response caching for reduced API calls
- Automatic fallback chains between models
- Streaming response handling
- Token usage tracking and budgeting
- Rate limiting and quota management
"""

import asyncio
import base64
import hashlib
import json
import logging
import os
import time
import urllib.request
import urllib.error
from collections import OrderedDict
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, AsyncIterator, Callable, Dict, List, Optional, Tuple, Union

from hana_ai.mangle.client import get_config_value

logger = logging.getLogger(__name__)


# =============================================================================
# Configuration
# =============================================================================

@dataclass
class AICoreConfig:
    """SAP AI Core configuration."""
    client_id: str
    client_secret: str
    auth_url: str
    base_url: str
    resource_group: str = "default"
    
    # Model preferences
    preferred_chat_model: Optional[str] = None
    preferred_embedding_model: Optional[str] = None
    
    # Performance settings
    request_timeout: int = 60
    max_retries: int = 3
    retry_delay: float = 1.0
    
    # Caching settings
    cache_enabled: bool = True
    cache_ttl_seconds: int = 3600
    cache_max_size: int = 1000
    
    # Rate limiting
    rate_limit_requests_per_minute: int = None
    rate_limit_tokens_per_minute: int = None
    
    @classmethod
    def from_env(cls) -> "AICoreConfig":
        """Load configuration from environment variables."""
        return cls(
            client_id=os.environ.get("AICORE_CLIENT_ID", ""),
            client_secret=os.environ.get("AICORE_CLIENT_SECRET", ""),
            auth_url=os.environ.get("AICORE_AUTH_URL", ""),
            base_url=os.environ.get("AICORE_BASE_URL", os.environ.get("AICORE_SERVICE_URL", "")),
            resource_group=os.environ.get("AICORE_RESOURCE_GROUP", "default"),
            preferred_chat_model=os.environ.get("AICORE_PREFERRED_CHAT_MODEL"),
            preferred_embedding_model=os.environ.get("AICORE_PREFERRED_EMBEDDING_MODEL"),
            request_timeout=int(os.environ.get("AICORE_REQUEST_TIMEOUT", "60")),
            max_retries=int(os.environ.get("AICORE_MAX_RETRIES", "3")),
            cache_enabled=os.environ.get("AICORE_CACHE_ENABLED", "true").lower() == "true",
            cache_ttl_seconds=int(os.environ.get("AICORE_CACHE_TTL", "3600")),
            rate_limit_requests_per_minute=int(os.environ.get("AICORE_RATE_LIMIT_RPM", str(get_config_value("rate_limit", "requests_per_minute", 60)))),
            rate_limit_tokens_per_minute=int(os.environ.get("AICORE_RATE_LIMIT_TPM", str(get_config_value("rate_limit", "tokens_per_minute", 100000)))),
        )
    
    def __post_init__(self):
        if self.rate_limit_requests_per_minute is None:
            self.rate_limit_requests_per_minute = get_config_value("rate_limit", "requests_per_minute", 60)
        if self.rate_limit_tokens_per_minute is None:
            self.rate_limit_tokens_per_minute = get_config_value("rate_limit", "tokens_per_minute", 100000)

    def is_ready(self) -> bool:
        """Check if configuration is complete."""
        return all([self.client_id, self.client_secret, self.auth_url, self.base_url])


class ModelCapability(Enum):
    """Model capability categories."""
    CHAT = "chat"
    EMBEDDING = "embedding"
    COMPLETION = "completion"
    CODE = "code"
    VISION = "vision"
    REASONING = "reasoning"


class ModelTier(Enum):
    """Model cost tiers."""
    ECONOMY = "economy"      # Low cost, basic capability
    STANDARD = "standard"    # Balanced cost/capability
    PREMIUM = "premium"      # High capability, higher cost
    ENTERPRISE = "enterprise" # Maximum capability


@dataclass
class ModelInfo:
    """Information about an AI Core deployment."""
    deployment_id: str
    model_name: str
    status: str
    capabilities: List[ModelCapability] = field(default_factory=list)
    tier: ModelTier = ModelTier.STANDARD
    is_anthropic: bool = False
    max_tokens: int = 4096
    context_window: int = 8192
    cost_per_1k_tokens: float = 0.01
    avg_latency_ms: float = 500.0
    
    @classmethod
    def from_deployment(cls, deployment: Dict) -> "ModelInfo":
        """Create ModelInfo from AI Core deployment response."""
        model_name = deployment.get("details", {}).get("resources", {}).get(
            "backend_details", {}
        ).get("model", {}).get("name", "unknown")
        
        # Detect capabilities and tier from model name
        capabilities = [ModelCapability.CHAT]
        tier = ModelTier.STANDARD
        is_anthropic = "anthropic" in model_name.lower() or "claude" in model_name.lower()
        
        if "embed" in model_name.lower():
            capabilities = [ModelCapability.EMBEDDING]
            tier = ModelTier.ECONOMY
        elif "gpt-4" in model_name.lower() or "claude-3" in model_name.lower():
            capabilities = [ModelCapability.CHAT, ModelCapability.CODE, ModelCapability.REASONING]
            tier = ModelTier.PREMIUM
        elif "opus" in model_name.lower():
            capabilities = [ModelCapability.CHAT, ModelCapability.CODE, ModelCapability.REASONING]
            tier = ModelTier.ENTERPRISE
        
        return cls(
            deployment_id=deployment["id"],
            model_name=model_name,
            status=deployment.get("status", "unknown"),
            capabilities=capabilities,
            tier=tier,
            is_anthropic=is_anthropic,
        )


# =============================================================================
# Token Management
# =============================================================================

@dataclass
class TokenUsage:
    """Token usage tracking."""
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0
    cached_tokens: int = 0
    
    def add(self, other: "TokenUsage") -> "TokenUsage":
        """Add token usage."""
        return TokenUsage(
            prompt_tokens=self.prompt_tokens + other.prompt_tokens,
            completion_tokens=self.completion_tokens + other.completion_tokens,
            total_tokens=self.total_tokens + other.total_tokens,
            cached_tokens=self.cached_tokens + other.cached_tokens,
        )


class TokenBudget:
    """Token budget management."""
    
    def __init__(
        self,
        daily_limit: int = 1_000_000,
        hourly_limit: int = 100_000,
        per_request_limit: int = 4096,
    ):
        self.daily_limit = daily_limit
        self.hourly_limit = hourly_limit
        self.per_request_limit = per_request_limit
        
        self._daily_usage = 0
        self._hourly_usage = 0
        self._day_start = time.time()
        self._hour_start = time.time()
    
    def check_budget(self, estimated_tokens: int) -> Tuple[bool, str]:
        """Check if request is within budget."""
        self._reset_if_needed()
        
        if estimated_tokens > self.per_request_limit:
            return False, f"Request exceeds per-request limit ({estimated_tokens} > {self.per_request_limit})"
        
        if self._daily_usage + estimated_tokens > self.daily_limit:
            return False, f"Would exceed daily limit ({self._daily_usage + estimated_tokens} > {self.daily_limit})"
        
        if self._hourly_usage + estimated_tokens > self.hourly_limit:
            return False, f"Would exceed hourly limit ({self._hourly_usage + estimated_tokens} > {self.hourly_limit})"
        
        return True, "OK"
    
    def record_usage(self, tokens: int) -> None:
        """Record token usage."""
        self._reset_if_needed()
        self._daily_usage += tokens
        self._hourly_usage += tokens
    
    def _reset_if_needed(self) -> None:
        """Reset counters if time period has passed."""
        now = time.time()
        
        if now - self._day_start > 86400:
            self._daily_usage = 0
            self._day_start = now
        
        if now - self._hour_start > 3600:
            self._hourly_usage = 0
            self._hour_start = now
    
    def get_remaining(self) -> Dict[str, int]:
        """Get remaining budget."""
        self._reset_if_needed()
        return {
            "daily": self.daily_limit - self._daily_usage,
            "hourly": self.hourly_limit - self._hourly_usage,
        }


# =============================================================================
# Response Cache
# =============================================================================

@dataclass
class CacheEntry:
    """Cached response entry."""
    response: Any
    timestamp: float
    token_usage: TokenUsage
    model_id: str


class ResponseCache:
    """LRU cache for AI Core responses."""
    
    def __init__(self, max_size: int = 1000, ttl_seconds: int = 3600):
        self._max_size = max_size
        self._ttl_seconds = ttl_seconds
        self._cache: OrderedDict[str, CacheEntry] = OrderedDict()
        self._hits = 0
        self._misses = 0
    
    def _make_key(self, messages: List[Dict], model: str) -> str:
        """Create cache key from request."""
        content = json.dumps({"messages": messages, "model": model}, sort_keys=True)
        return hashlib.sha256(content.encode()).hexdigest()
    
    def get(self, messages: List[Dict], model: str) -> Optional[CacheEntry]:
        """Get cached response."""
        key = self._make_key(messages, model)
        entry = self._cache.get(key)
        
        if entry is None:
            self._misses += 1
            return None
        
        if time.time() - entry.timestamp > self._ttl_seconds:
            self._cache.pop(key, None)
            self._misses += 1
            return None
        
        self._hits += 1
        self._cache.move_to_end(key)
        return entry
    
    def set(
        self,
        messages: List[Dict],
        model: str,
        response: Any,
        token_usage: TokenUsage,
    ) -> None:
        """Cache response."""
        while len(self._cache) >= self._max_size:
            self._cache.popitem(last=False)
        
        key = self._make_key(messages, model)
        self._cache[key] = CacheEntry(
            response=response,
            timestamp=time.time(),
            token_usage=token_usage,
            model_id=model,
        )
    
    def get_stats(self) -> Dict[str, Any]:
        """Get cache statistics."""
        total = self._hits + self._misses
        return {
            "size": len(self._cache),
            "max_size": self._max_size,
            "hits": self._hits,
            "misses": self._misses,
            "hit_rate": self._hits / total if total > 0 else 0.0,
        }
    
    def clear(self) -> None:
        """Clear cache."""
        self._cache.clear()


# =============================================================================
# Rate Limiter
# =============================================================================

class RateLimiter:
    """Token bucket rate limiter."""
    
    def __init__(
        self,
        requests_per_minute: int = 60,
        tokens_per_minute: int = 100000,
    ):
        self._rpm_limit = requests_per_minute
        self._tpm_limit = tokens_per_minute
        
        self._request_tokens = requests_per_minute
        self._token_tokens = tokens_per_minute
        self._last_refill = time.time()
    
    def _refill(self) -> None:
        """Refill tokens based on elapsed time."""
        now = time.time()
        elapsed = now - self._last_refill
        
        # Refill at rate per second
        request_refill = (elapsed / 60) * self._rpm_limit
        token_refill = (elapsed / 60) * self._tpm_limit
        
        self._request_tokens = min(self._rpm_limit, self._request_tokens + request_refill)
        self._token_tokens = min(self._tpm_limit, self._token_tokens + token_refill)
        self._last_refill = now
    
    async def acquire(self, estimated_tokens: int = 1) -> float:
        """
        Acquire rate limit tokens. Returns wait time in seconds.
        """
        self._refill()
        
        # Check if we need to wait
        if self._request_tokens < 1 or self._token_tokens < estimated_tokens:
            # Calculate wait time
            request_wait = (1 - self._request_tokens) * 60 / self._rpm_limit
            token_wait = (estimated_tokens - self._token_tokens) * 60 / self._tpm_limit
            wait_time = max(request_wait, token_wait, 0.1)
            
            await asyncio.sleep(wait_time)
            self._refill()
        
        # Consume tokens
        self._request_tokens -= 1
        self._token_tokens -= estimated_tokens
        
        return 0.0
    
    def get_remaining(self) -> Dict[str, float]:
        """Get remaining rate limit capacity."""
        self._refill()
        return {
            "requests": self._request_tokens,
            "tokens": self._token_tokens,
        }


# =============================================================================
# Model Router
# =============================================================================

class RoutingStrategy(Enum):
    """Model routing strategies."""
    COST_OPTIMIZED = "cost"       # Minimize cost
    LATENCY_OPTIMIZED = "latency" # Minimize latency
    QUALITY_OPTIMIZED = "quality" # Maximize quality
    BALANCED = "balanced"         # Balance all factors


class ModelRouter:
    """Intelligent model routing based on task requirements."""
    
    def __init__(self, strategy: RoutingStrategy = RoutingStrategy.BALANCED):
        self.strategy = strategy
        self._models: Dict[str, ModelInfo] = {}
        self._latency_history: Dict[str, List[float]] = {}
    
    def register_model(self, model: ModelInfo) -> None:
        """Register a model for routing."""
        self._models[model.deployment_id] = model
    
    def select_model(
        self,
        capability: ModelCapability,
        max_tokens: Optional[int] = None,
        prefer_tier: Optional[ModelTier] = None,
    ) -> Optional[ModelInfo]:
        """Select best model for requirements."""
        candidates = [
            m for m in self._models.values()
            if capability in m.capabilities and m.status == "RUNNING"
        ]
        
        if not candidates:
            return None
        
        # Filter by max_tokens if specified
        if max_tokens:
            candidates = [m for m in candidates if m.max_tokens >= max_tokens]
        
        if not candidates:
            return None
        
        # Apply routing strategy
        if self.strategy == RoutingStrategy.COST_OPTIMIZED:
            candidates.sort(key=lambda m: m.cost_per_1k_tokens)
        elif self.strategy == RoutingStrategy.LATENCY_OPTIMIZED:
            candidates.sort(key=lambda m: self._get_avg_latency(m.deployment_id))
        elif self.strategy == RoutingStrategy.QUALITY_OPTIMIZED:
            tier_order = {ModelTier.ENTERPRISE: 0, ModelTier.PREMIUM: 1, ModelTier.STANDARD: 2, ModelTier.ECONOMY: 3}
            candidates.sort(key=lambda m: tier_order.get(m.tier, 4))
        else:  # BALANCED
            def score(m: ModelInfo) -> float:
                cost_score = 1.0 / (m.cost_per_1k_tokens + 0.001)
                latency_score = 1.0 / (self._get_avg_latency(m.deployment_id) + 100)
                tier_score = {ModelTier.ENTERPRISE: 4, ModelTier.PREMIUM: 3, ModelTier.STANDARD: 2, ModelTier.ECONOMY: 1}.get(m.tier, 1)
                return cost_score * 0.3 + latency_score * 0.3 + tier_score * 0.4
            candidates.sort(key=score, reverse=True)
        
        # Prefer specific tier if requested
        if prefer_tier:
            tier_candidates = [m for m in candidates if m.tier == prefer_tier]
            if tier_candidates:
                return tier_candidates[0]
        
        return candidates[0]
    
    def record_latency(self, deployment_id: str, latency_ms: float) -> None:
        """Record latency for a model."""
        if deployment_id not in self._latency_history:
            self._latency_history[deployment_id] = []
        
        history = self._latency_history[deployment_id]
        history.append(latency_ms)
        
        # Keep last 100 samples
        if len(history) > 100:
            self._latency_history[deployment_id] = history[-100:]
    
    def _get_avg_latency(self, deployment_id: str) -> float:
        """Get average latency for a model."""
        history = self._latency_history.get(deployment_id, [])
        if not history:
            model = self._models.get(deployment_id)
            return model.avg_latency_ms if model else 500.0
        return sum(history) / len(history)


# =============================================================================
# Enhanced AI Core Client
# =============================================================================

class EnhancedAICoreClient:
    """
    Enhanced client for SAP AI Core with advanced features.
    
    Features:
    - Intelligent model routing
    - Response caching
    - Automatic fallback chains
    - Token budget management
    - Rate limiting
    
    Examples
    --------
    >>> client = EnhancedAICoreClient()
    >>> 
    >>> # Simple chat
    >>> response = await client.chat("What is machine learning?")
    >>> 
    >>> # With routing preferences
    >>> response = await client.chat(
    ...     "Analyze this code",
    ...     routing_strategy=RoutingStrategy.QUALITY_OPTIMIZED
    ... )
    """
    
    def __init__(self, config: Optional[AICoreConfig] = None):
        self.config = config or AICoreConfig.from_env()
        
        # Components
        self.cache = ResponseCache(
            max_size=self.config.cache_max_size,
            ttl_seconds=self.config.cache_ttl_seconds,
        ) if self.config.cache_enabled else None
        
        self.rate_limiter = RateLimiter(
            requests_per_minute=self.config.rate_limit_requests_per_minute,
            tokens_per_minute=self.config.rate_limit_tokens_per_minute,
        )
        
        self.token_budget = TokenBudget()
        self.router = ModelRouter()
        
        # State
        self._token: Optional[str] = None
        self._token_expires: float = 0
        self._deployments: List[ModelInfo] = []
        self._total_usage = TokenUsage()
    
    async def initialize(self) -> None:
        """Initialize client and load deployments."""
        await self._refresh_token()
        await self._load_deployments()
    
    async def _refresh_token(self) -> str:
        """Refresh OAuth token."""
        if self._token and time.time() < self._token_expires:
            return self._token
        
        auth = base64.b64encode(
            f"{self.config.client_id}:{self.config.client_secret}".encode()
        ).decode()
        
        req = urllib.request.Request(
            self.config.auth_url,
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": f"Basic {auth}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST"
        )
        
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None,
            lambda: urllib.request.urlopen(req, timeout=self.config.request_timeout)
        )
        
        result = json.loads(response.read().decode())
        self._token = result["access_token"]
        self._token_expires = time.time() + result.get("expires_in", 3600) - 60
        
        return self._token
    
    async def _load_deployments(self) -> None:
        """Load available deployments."""
        result = await self._request("GET", "/v2/lm/deployments")
        
        self._deployments = []
        for d in result.get("resources", []):
            model = ModelInfo.from_deployment(d)
            self._deployments.append(model)
            self.router.register_model(model)
        
        logger.info(f"Loaded {len(self._deployments)} AI Core deployments")
    
    async def _request(
        self,
        method: str,
        path: str,
        body: Optional[Dict] = None,
    ) -> Dict:
        """Make authenticated request to AI Core."""
        token = await self._refresh_token()
        url = f"{self.config.base_url}{path}"
        
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bearer {token}",
                "AI-Resource-Group": self.config.resource_group,
                "Content-Type": "application/json",
            },
            method=method
        )
        
        loop = asyncio.get_event_loop()
        
        for attempt in range(self.config.max_retries):
            try:
                response = await loop.run_in_executor(
                    None,
                    lambda: urllib.request.urlopen(req, timeout=self.config.request_timeout)
                )
                return json.loads(response.read().decode())
            except urllib.error.HTTPError as e:
                if e.code >= 500 and attempt < self.config.max_retries - 1:
                    await asyncio.sleep(self.config.retry_delay * (attempt + 1))
                    continue
                raise
            except Exception as e:
                if attempt < self.config.max_retries - 1:
                    await asyncio.sleep(self.config.retry_delay * (attempt + 1))
                    continue
                raise
        
        raise RuntimeError("Max retries exceeded")
    
    async def chat(
        self,
        message: str,
        messages: Optional[List[Dict]] = None,
        model: Optional[str] = None,
        max_tokens: int = 1024,
        temperature: float = 0.7,
        routing_strategy: Optional[RoutingStrategy] = None,
        use_cache: bool = True,
        fallback_models: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """
        Send chat completion request.
        
        Parameters
        ----------
        message : str
            User message (used if messages not provided).
        messages : List[Dict], optional
            Full message history.
        model : str, optional
            Specific model to use.
        max_tokens : int
            Maximum tokens in response.
        temperature : float
            Sampling temperature.
        routing_strategy : RoutingStrategy, optional
            Override default routing strategy.
        use_cache : bool
            Whether to use response cache.
        fallback_models : List[str], optional
            Models to try if primary fails.
        
        Returns
        -------
        Dict[str, Any]
            Chat completion response.
        """
        # Build messages
        if messages is None:
            messages = [{"role": "user", "content": message}]
        
        # Check cache
        if use_cache and self.cache:
            cached = self.cache.get(messages, model or "default")
            if cached:
                logger.debug("Cache hit for chat request")
                return {
                    "content": cached.response,
                    "model": cached.model_id,
                    "usage": cached.token_usage.__dict__,
                    "cached": True,
                }
        
        # Select model
        if model:
            deployment = next((m for m in self._deployments if m.deployment_id == model), None)
        else:
            strategy = routing_strategy or self.router.strategy
            old_strategy = self.router.strategy
            self.router.strategy = strategy
            deployment = self.router.select_model(ModelCapability.CHAT, max_tokens=max_tokens)
            self.router.strategy = old_strategy
        
        if not deployment:
            raise ValueError("No suitable model available")
        
        # Check budget
        estimated_tokens = len(str(messages)) // 4 + max_tokens
        ok, reason = self.token_budget.check_budget(estimated_tokens)
        if not ok:
            raise ValueError(f"Token budget exceeded: {reason}")
        
        # Rate limiting
        await self.rate_limiter.acquire(estimated_tokens)
        
        # Execute with fallback
        models_to_try = [deployment]
        if fallback_models:
            for fm in fallback_models:
                fb_model = next((m for m in self._deployments if m.deployment_id == fm), None)
                if fb_model:
                    models_to_try.append(fb_model)
        
        last_error = None
        for model_info in models_to_try:
            try:
                start_time = time.time()
                result = await self._execute_chat(model_info, messages, max_tokens, temperature)
                latency = (time.time() - start_time) * 1000
                
                self.router.record_latency(model_info.deployment_id, latency)
                
                # Parse response
                content = self._extract_content(result, model_info.is_anthropic)
                usage = self._extract_usage(result)
                
                # Update tracking
                self.token_budget.record_usage(usage.total_tokens)
                self._total_usage = self._total_usage.add(usage)
                
                # Cache response
                if use_cache and self.cache:
                    self.cache.set(messages, model_info.deployment_id, content, usage)
                
                return {
                    "content": content,
                    "model": model_info.deployment_id,
                    "model_name": model_info.model_name,
                    "usage": usage.__dict__,
                    "latency_ms": latency,
                    "cached": False,
                }
            
            except Exception as e:
                last_error = e
                logger.warning(f"Model {model_info.deployment_id} failed: {e}")
                continue
        
        raise last_error or RuntimeError("All models failed")
    
    async def _execute_chat(
        self,
        model: ModelInfo,
        messages: List[Dict],
        max_tokens: int,
        temperature: float,
    ) -> Dict:
        """Execute chat request on specific model."""
        if model.is_anthropic:
            return await self._request(
                "POST",
                f"/v2/inference/deployments/{model.deployment_id}/invoke",
                {
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": max_tokens,
                    "messages": messages,
                    "temperature": temperature,
                }
            )
        else:
            return await self._request(
                "POST",
                f"/v2/inference/deployments/{model.deployment_id}/chat/completions",
                {
                    "messages": messages,
                    "max_tokens": max_tokens,
                    "temperature": temperature,
                }
            )
    
    async def embed(
        self,
        texts: Union[str, List[str]],
        model: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Generate embeddings.
        
        Parameters
        ----------
        texts : str or List[str]
            Text(s) to embed.
        model : str, optional
            Specific embedding model.
        
        Returns
        -------
        Dict[str, Any]
            Embeddings response.
        """
        if isinstance(texts, str):
            texts = [texts]
        
        # Select model
        if model:
            deployment = next((m for m in self._deployments if m.deployment_id == model), None)
        else:
            deployment = self.router.select_model(ModelCapability.EMBEDDING)
        
        if not deployment:
            raise ValueError("No embedding model available")
        
        # Rate limiting
        estimated_tokens = sum(len(t) // 4 for t in texts)
        await self.rate_limiter.acquire(estimated_tokens)
        
        result = await self._request(
            "POST",
            f"/v2/inference/deployments/{deployment.deployment_id}/embeddings",
            {"input": texts}
        )
        
        return {
            "embeddings": [d.get("embedding", []) for d in result.get("data", [])],
            "model": deployment.deployment_id,
            "usage": result.get("usage", {}),
        }
    
    def _extract_content(self, result: Dict, is_anthropic: bool) -> str:
        """Extract content from response."""
        if is_anthropic:
            return result.get("content", [{}])[0].get("text", "")
        else:
            return result.get("choices", [{}])[0].get("message", {}).get("content", "")
    
    def _extract_usage(self, result: Dict) -> TokenUsage:
        """Extract token usage from response."""
        usage = result.get("usage", {})
        return TokenUsage(
            prompt_tokens=usage.get("input_tokens", usage.get("prompt_tokens", 0)),
            completion_tokens=usage.get("output_tokens", usage.get("completion_tokens", 0)),
            total_tokens=usage.get("total_tokens", 0),
        )
    
    def get_models(self) -> List[ModelInfo]:
        """Get available models."""
        return self._deployments
    
    def get_stats(self) -> Dict[str, Any]:
        """Get client statistics."""
        return {
            "total_usage": self._total_usage.__dict__,
            "budget_remaining": self.token_budget.get_remaining(),
            "rate_limit_remaining": self.rate_limiter.get_remaining(),
            "cache_stats": self.cache.get_stats() if self.cache else None,
            "models": len(self._deployments),
        }


# =============================================================================
# Singleton Instance
# =============================================================================

_client: Optional[EnhancedAICoreClient] = None


async def get_aicore_client() -> EnhancedAICoreClient:
    """Get or create the enhanced AI Core client."""
    global _client
    
    if _client is None:
        _client = EnhancedAICoreClient()
        await _client.initialize()
    
    return _client