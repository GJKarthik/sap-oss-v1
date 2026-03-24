# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
LLM Router for Data Cleaning Copilot

Implements Mangle-based routing rules for directing LLM requests to either:
- SAP AI Core (cloud) - for public/internal data
- vLLM (on-premise) - for PII/confidential data

This module enforces data classification rules from mangle/domain/agents.mg
"""

import json
import os
import re
from typing import Any, Optional, Tuple, List
import urllib.request
import urllib.error

# =============================================================================
# PII Detection Configuration
# From mangle/domain/agents.mg - pii_keyword declarations
# =============================================================================

PII_KEYWORDS = frozenset([
    # Personal identifiers
    "customer", "personal", "confidential", "pii",
    "ssn", "social_security", "social security",
    "credit_card", "credit card", "cc_number",
    "bank_account", "bank account",
    "passport", "driver_license", "driver license",
    "date_of_birth", "date of birth", "dob",
    # Contact info
    "email", "phone", "telephone", "mobile",
    "address", "street", "zip", "postal",
    # Financial
    "salary", "compensation", "income", "wage",
    # Health
    "health", "medical", "diagnosis", "patient",
    # Identity
    "national_id", "national id", "tax_id", "tax id",
])

# Additional regex patterns for detecting PII
PII_PATTERNS = [
    re.compile(r'\b\d{3}-\d{2}-\d{4}\b'),  # SSN format
    re.compile(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'),  # Credit card
    re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b'),  # Email
]

# Data security classifications that require on-premise processing
ONPREM_REQUIRED_CLASSES = frozenset(["confidential", "restricted", "pii"])


# =============================================================================
# Backend Configuration
# =============================================================================

class LLMBackend:
    """Represents an LLM backend endpoint."""
    
    def __init__(self, name: str, url: str, backend_type: str):
        self.name = name
        self.url = url.rstrip("/")
        self.backend_type = backend_type  # "cloud", "onprem", "local"
        self._healthy = True
    
    def is_available(self) -> bool:
        """Check if backend is currently available."""
        return self._healthy
    
    def mark_unhealthy(self):
        self._healthy = False
    
    def mark_healthy(self):
        self._healthy = True


class LLMRouter:
    """
    Routes LLM requests based on data classification and Mangle rules.
    
    Routing logic (from mangle/domain/agents.mg):
    1. If query contains PII keywords → route to vLLM (on-premise)
    2. If data classification is confidential/restricted → route to vLLM
    3. Otherwise → route to AI Core (cloud)
    """
    
    def __init__(self):
        # AI Core backend (cloud)
        self.aicore = LLMBackend(
            name="aicore",
            url=os.environ.get("AICORE_BASE_URL", ""),
            backend_type="cloud"
        )
        
        # vLLM backend (on-premise)
        self.vllm = LLMBackend(
            name="vllm",
            url=os.environ.get("VLLM_URL", os.environ.get("PRIVATE_LLM_URL", "http://localhost:8080")),
            backend_type="onprem"
        )
        
        # Ollama backend (local development)
        self.ollama = LLMBackend(
            name="ollama",
            url=os.environ.get("OLLAMA_URL", "http://localhost:11434"),
            backend_type="local"
        )
        
        # Default backend preference
        self.default_backend = os.environ.get("DEFAULT_LLM_BACKEND", "aicore")
        
        # Whether to enforce PII routing (can be disabled for testing)
        self.enforce_pii_routing = os.environ.get("ENFORCE_PII_ROUTING", "true").lower() == "true"
        
        # AI Core credentials
        self._aicore_token = None
        self._aicore_token_expiry = 0
    
    def contains_pii(self, text: str) -> Tuple[bool, List[str]]:
        """
        Check if text contains PII based on keywords and patterns.
        
        Returns:
            Tuple of (contains_pii: bool, detected_indicators: list[str])
        """
        if not text:
            return False, []
        
        text_lower = text.lower()
        detected = []
        
        # Check keywords
        for keyword in PII_KEYWORDS:
            if keyword in text_lower:
                detected.append(f"keyword:{keyword}")
        
        # Check patterns
        for i, pattern in enumerate(PII_PATTERNS):
            if pattern.search(text):
                detected.append(f"pattern:{i}")
        
        return len(detected) > 0, detected
    
    def classify_data(self, context: dict) -> str:
        """
        Classify data based on context metadata.
        
        Args:
            context: Dict with optional keys like 'data_class', 'table_name', 'schema'
            
        Returns:
            Classification string: 'public', 'internal', 'confidential', or 'restricted'
        """
        # Explicit classification from context
        explicit_class = context.get("data_class", "").lower()
        if explicit_class in ("public", "internal", "confidential", "restricted"):
            return explicit_class
        
        # Infer from table name
        table_name = context.get("table_name", "").lower()
        if any(kw in table_name for kw in ["customer", "employee", "user", "person"]):
            return "confidential"
        if any(kw in table_name for kw in ["financial", "salary", "payment", "transaction"]):
            return "confidential"
        
        # Infer from schema columns
        schema = context.get("schema", {})
        columns = schema.get("columns", []) if isinstance(schema, dict) else []
        col_names = [c.get("name", "").lower() for c in columns if isinstance(c, dict)]
        
        pii_col_count = sum(1 for name in col_names if any(kw in name for kw in PII_KEYWORDS))
        if pii_col_count > 0:
            return "confidential"
        
        return "internal"  # Default to internal
    
    def route_request(
        self,
        prompt: str,
        messages: list = None,
        context: dict = None
    ) -> Tuple[LLMBackend, dict]:
        """
        Determine which backend to route the request to.
        
        Implements routing rules from mangle/domain/agents.mg:
        - route_to_backend(Query, vllm) :- contains_pii(Query).
        - route_to_backend(Query, vllm) :- query_data_class(Query, Class), requires_onprem(Class).
        - route_to_backend(Query, aicore) :- default.
        
        Args:
            prompt: The raw prompt text
            messages: List of messages for chat completion
            context: Additional context (table_name, schema, data_class)
            
        Returns:
            Tuple of (selected_backend, routing_metadata)
        """
        context = context or {}
        routing_meta = {
            "contains_pii": False,
            "pii_indicators": [],
            "data_class": "internal",
            "routing_reason": "",
            "backend": "",
        }
        
        # Combine all text for PII analysis
        all_text = prompt or ""
        if messages:
            for msg in messages:
                if isinstance(msg, dict):
                    all_text += " " + str(msg.get("content", ""))
        
        # Check for PII
        has_pii, pii_indicators = self.contains_pii(all_text)
        routing_meta["contains_pii"] = has_pii
        routing_meta["pii_indicators"] = pii_indicators
        
        # Classify data
        data_class = self.classify_data(context)
        routing_meta["data_class"] = data_class
        
        # Apply routing rules
        if self.enforce_pii_routing:
            # Rule 1: PII detected → vLLM
            if has_pii:
                routing_meta["routing_reason"] = "pii_detected"
                routing_meta["backend"] = "vllm"
                return self.vllm, routing_meta
            
            # Rule 2: Confidential/restricted data → vLLM
            if data_class in ONPREM_REQUIRED_CLASSES:
                routing_meta["routing_reason"] = f"data_class_{data_class}"
                routing_meta["backend"] = "vllm"
                return self.vllm, routing_meta
        
        # Default routing based on configured default
        routing_meta["routing_reason"] = "default"
        
        if self.default_backend == "vllm" and self.vllm.is_available():
            routing_meta["backend"] = "vllm"
            return self.vllm, routing_meta
        elif self.default_backend == "ollama" and self.ollama.is_available():
            routing_meta["backend"] = "ollama"
            return self.ollama, routing_meta
        else:
            routing_meta["backend"] = "aicore"
            return self.aicore, routing_meta
    
    def _get_aicore_token(self) -> str:
        """Get cached or fresh AI Core OAuth token."""
        import time
        import base64
        
        if self._aicore_token and time.time() < self._aicore_token_expiry:
            return self._aicore_token
        
        client_id = os.environ.get("AICORE_CLIENT_ID", "")
        client_secret = os.environ.get("AICORE_CLIENT_SECRET", "")
        auth_url = os.environ.get("AICORE_AUTH_URL", "")
        
        if not all([client_id, client_secret, auth_url]):
            return ""
        
        auth = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        req = urllib.request.Request(
            auth_url,
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": f"Basic {auth}",
                "Content-Type": "application/x-www-form-urlencoded"
            },
            method="POST",
        )
        
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.loads(resp.read().decode())
                self._aicore_token = result["access_token"]
                self._aicore_token_expiry = time.time() + result.get("expires_in", 3600) - 60
                return self._aicore_token
        except Exception:
            return ""
    
    def call_vllm(self, messages: list, **kwargs) -> dict:
        """
        Call vLLM backend with OpenAI-compatible API.
        
        Args:
            messages: Chat messages in OpenAI format
            **kwargs: Additional parameters (max_tokens, temperature, etc.)
            
        Returns:
            Response dict with 'content' key
        """
        payload = {
            "model": os.environ.get("VLLM_MODEL", "default"),
            "messages": messages,
            "max_tokens": kwargs.get("max_tokens", 1024),
            "temperature": kwargs.get("temperature", 0.7),
        }
        
        req = urllib.request.Request(
            f"{self.vllm.url}/v1/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read().decode())
                content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
                return {"content": content, "backend": "vllm", "model": payload["model"]}
        except Exception as e:
            self.vllm.mark_unhealthy()
            return {"content": "", "error": str(e), "backend": "vllm"}
    
    def call_aicore(self, messages: list, deployment_id: str = None, **kwargs) -> dict:
        """
        Call SAP AI Core backend.
        
        Args:
            messages: Chat messages
            deployment_id: Specific deployment to use (optional)
            **kwargs: Additional parameters
            
        Returns:
            Response dict with 'content' key
        """
        token = self._get_aicore_token()
        if not token:
            return {"content": "", "error": "AI Core authentication failed", "backend": "aicore"}
        
        base_url = os.environ.get("AICORE_BASE_URL", "")
        resource_group = os.environ.get("AICORE_RESOURCE_GROUP", "default")
        
        # Get deployment if not specified
        if not deployment_id:
            try:
                req = urllib.request.Request(
                    f"{base_url}/v2/lm/deployments",
                    headers={
                        "Authorization": f"Bearer {token}",
                        "AI-Resource-Group": resource_group,
                    },
                )
                with urllib.request.urlopen(req, timeout=30) as resp:
                    deployments = json.loads(resp.read().decode())
                    resources = deployments.get("resources", [])
                    if not resources:
                        return {"content": "", "error": "No AI Core deployments available", "backend": "aicore"}
                    deployment_id = resources[0].get("id")
            except Exception as e:
                return {"content": "", "error": f"Failed to get deployments: {e}", "backend": "aicore"}
        
        # Call chat completion
        payload = {
            "messages": messages,
            "max_tokens": kwargs.get("max_tokens", 1024),
        }
        
        try:
            req = urllib.request.Request(
                f"{base_url}/v2/inference/deployments/{deployment_id}/chat/completions",
                data=json.dumps(payload).encode(),
                headers={
                    "Authorization": f"Bearer {token}",
                    "AI-Resource-Group": resource_group,
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read().decode())
                content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
                return {"content": content, "backend": "aicore", "deployment": deployment_id}
        except Exception as e:
            self.aicore.mark_unhealthy()
            return {"content": "", "error": str(e), "backend": "aicore"}
    
    def chat(
        self,
        messages: list,
        context: dict = None,
        **kwargs
    ) -> dict:
        """
        High-level chat completion with automatic routing.
        
        This is the main entry point that:
        1. Analyzes the request for PII
        2. Routes to appropriate backend
        3. Returns response with routing metadata
        
        Args:
            messages: Chat messages
            context: Optional context for data classification
            **kwargs: LLM parameters
            
        Returns:
            Dict with 'content', 'backend', 'routing' keys
        """
        # Combine message content for routing analysis
        prompt = " ".join(
            str(m.get("content", "")) for m in messages if isinstance(m, dict)
        )
        
        # Route the request
        backend, routing_meta = self.route_request(prompt, messages, context)
        
        # Call appropriate backend
        if backend.name == "vllm":
            result = self.call_vllm(messages, **kwargs)
        elif backend.name == "aicore":
            result = self.call_aicore(messages, **kwargs)
        else:
            result = {"content": "", "error": f"Unknown backend: {backend.name}"}
        
        # Add routing metadata
        result["routing"] = routing_meta
        return result


# Singleton router instance
_router: Optional[LLMRouter] = None


def get_router() -> LLMRouter:
    """Get or create the global LLM router instance."""
    global _router
    if _router is None:
        _router = LLMRouter()
    return _router


# =============================================================================
# Convenience functions
# =============================================================================

def route_and_chat(messages: list, context: dict = None, **kwargs) -> dict:
    """
    Route and execute a chat completion with PII-aware routing.
    
    Example:
        >>> result = route_and_chat([
        ...     {"role": "user", "content": "Analyze customer SSN data"}
        ... ])
        >>> result['routing']['backend']  # 'vllm' (routed to on-prem due to PII)
    """
    return get_router().chat(messages, context, **kwargs)


def check_pii(text: str) -> dict:
    """
    Check text for PII indicators.
    
    Returns:
        Dict with 'contains_pii', 'indicators', 'recommended_backend' keys
    """
    router = get_router()
    has_pii, indicators = router.contains_pii(text)
    return {
        "contains_pii": has_pii,
        "indicators": indicators,
        "recommended_backend": "vllm" if has_pii else "aicore",
    }