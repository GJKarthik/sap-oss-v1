"""
Configuration Management for Mangle Query Service

Day 5 Deliverable: Centralized configuration with environment variable support
- Pydantic-style settings with validation
- Environment variable loading
- Environment-specific presets (dev, staging, prod)
- Secure secret handling

Usage:
    from config.settings import get_settings
    
    settings = get_settings()
    print(settings.elasticsearch_url)
"""

import os
import json
import logging
from typing import Optional, Dict, Any, List, Set
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
import re

logger = logging.getLogger(__name__)


# ========================================
# Environment Enum
# ========================================

class Environment(str, Enum):
    """Deployment environment."""
    
    DEVELOPMENT = "development"
    STAGING = "staging"
    PRODUCTION = "production"
    TEST = "test"


# ========================================
# Configuration Sections
# ========================================

@dataclass
class ServerConfig:
    """HTTP server configuration."""
    
    host: str = "0.0.0.0"
    port: int = 8080
    workers: int = 4
    debug: bool = False
    log_level: str = "INFO"
    cors_origins: List[str] = field(default_factory=lambda: ["*"])
    request_timeout: float = 60.0


@dataclass
class ElasticsearchConfig:
    """Elasticsearch configuration."""
    
    url: str = "http://localhost:9200"
    index_prefix: str = "mangle"
    username: Optional[str] = None
    password: Optional[str] = None
    api_key: Optional[str] = None
    ca_cert_path: Optional[str] = None
    timeout: float = 30.0
    max_retries: int = 3
    pool_size: int = 10
    
    @property
    def has_auth(self) -> bool:
        """Check if authentication is configured."""
        return bool(self.username or self.api_key)


@dataclass
class HANAConfig:
    """SAP HANA Cloud configuration."""
    
    host: str = ""
    port: int = 443
    user: str = ""
    password: str = ""
    schema: str = ""
    encrypt: bool = True
    ssl_trust_store: Optional[str] = None
    connection_pool_size: int = 5
    statement_timeout: int = 300
    
    @property
    def is_configured(self) -> bool:
        """Check if HANA is configured."""
        return bool(self.host and self.user and self.password)
    
    @property
    def connection_string(self) -> str:
        """Get connection string (without password)."""
        if not self.is_configured:
            return ""
        return f"hana://{self.user}@{self.host}:{self.port}/{self.schema}"


@dataclass
class LLMBackendConfig:
    """LLM backend configuration."""
    
    base_url: str = "http://localhost:8000/v1"
    api_key: Optional[str] = None
    model: str = "gpt-4"
    default_temperature: float = 0.7
    max_tokens: int = 4096
    timeout: float = 120.0
    retry_count: int = 2


@dataclass
class AICoreSteamingConfig:
    """SAP AI Core streaming configuration."""
    
    base_url: str = ""
    client_id: str = ""
    client_secret: str = ""
    token_url: str = ""
    deployment_id: str = ""
    resource_group: str = "default"
    timeout: float = 120.0
    
    @property
    def is_configured(self) -> bool:
        """Check if AI Core is configured."""
        return bool(self.base_url and self.client_id and self.client_secret)


@dataclass
class CacheConfig:
    """Caching configuration."""
    
    enabled: bool = True
    ttl_seconds: int = 3600
    max_entries: int = 10000
    semantic_cache_enabled: bool = True
    similarity_threshold: float = 0.95


@dataclass
class ResilienceConfig:
    """Resilience configuration (retry + circuit breaker)."""
    
    # Retry settings
    retry_enabled: bool = True
    max_retries: int = 3
    retry_base_delay: float = 1.0
    retry_max_delay: float = 8.0
    
    # Circuit breaker settings
    circuit_breaker_enabled: bool = True
    cb_failure_threshold: int = 5
    cb_success_threshold: int = 2
    cb_recovery_timeout: float = 30.0
    
    # Timeout settings
    default_timeout: float = 30.0
    llm_timeout: float = 120.0


@dataclass
class SecurityConfig:
    """Security configuration."""
    
    api_key_header: str = "X-API-Key"
    api_keys: Set[str] = field(default_factory=set)
    jwt_enabled: bool = False
    jwt_secret: Optional[str] = None
    jwt_algorithm: str = "HS256"
    rate_limit_enabled: bool = True
    rate_limit_requests: int = 100
    rate_limit_window: int = 60


@dataclass
class ObservabilityConfig:
    """Observability configuration."""
    
    metrics_enabled: bool = True
    metrics_port: int = 9090
    tracing_enabled: bool = False
    tracing_endpoint: str = ""
    log_format: str = "json"
    log_request_body: bool = False
    log_response_body: bool = False


# ========================================
# Main Settings Class
# ========================================

@dataclass
class Settings:
    """
    Main settings container.
    
    All configuration for the Mangle Query Service.
    """
    
    # Environment
    environment: Environment = Environment.DEVELOPMENT
    service_name: str = "mangle-query-service"
    version: str = "1.0.0"
    
    # Sub-configurations
    server: ServerConfig = field(default_factory=ServerConfig)
    elasticsearch: ElasticsearchConfig = field(default_factory=ElasticsearchConfig)
    hana: HANAConfig = field(default_factory=HANAConfig)
    llm: LLMBackendConfig = field(default_factory=LLMBackendConfig)
    aicore: AICoreSteamingConfig = field(default_factory=AICoreSteamingConfig)
    cache: CacheConfig = field(default_factory=CacheConfig)
    resilience: ResilienceConfig = field(default_factory=ResilienceConfig)
    security: SecurityConfig = field(default_factory=SecurityConfig)
    observability: ObservabilityConfig = field(default_factory=ObservabilityConfig)
    
    @property
    def is_production(self) -> bool:
        """Check if running in production."""
        return self.environment == Environment.PRODUCTION
    
    @property
    def is_development(self) -> bool:
        """Check if running in development."""
        return self.environment == Environment.DEVELOPMENT
    
    def to_dict(self, mask_secrets: bool = True) -> Dict[str, Any]:
        """Convert to dictionary, optionally masking secrets."""
        result = {
            "environment": self.environment.value,
            "service_name": self.service_name,
            "version": self.version,
            "server": {
                "host": self.server.host,
                "port": self.server.port,
                "workers": self.server.workers,
                "debug": self.server.debug,
            },
            "elasticsearch": {
                "url": self.elasticsearch.url,
                "index_prefix": self.elasticsearch.index_prefix,
                "has_auth": self.elasticsearch.has_auth,
            },
            "hana": {
                "is_configured": self.hana.is_configured,
                "connection_string": self.hana.connection_string,
            },
            "llm": {
                "base_url": self.llm.base_url,
                "model": self.llm.model,
            },
            "aicore": {
                "is_configured": self.aicore.is_configured,
                "base_url": self.aicore.base_url if not mask_secrets else "***",
            },
            "cache": {
                "enabled": self.cache.enabled,
                "ttl_seconds": self.cache.ttl_seconds,
            },
            "resilience": {
                "retry_enabled": self.resilience.retry_enabled,
                "circuit_breaker_enabled": self.resilience.circuit_breaker_enabled,
            },
            "security": {
                "rate_limit_enabled": self.security.rate_limit_enabled,
                "jwt_enabled": self.security.jwt_enabled,
            },
            "observability": {
                "metrics_enabled": self.observability.metrics_enabled,
                "tracing_enabled": self.observability.tracing_enabled,
            },
        }
        return result
    
    def validate(self) -> List[str]:
        """Validate configuration, return list of errors."""
        errors = []
        
        # Production-specific validations
        if self.is_production:
            if self.server.debug:
                errors.append("Debug mode must be disabled in production")
            
            if not self.elasticsearch.has_auth:
                errors.append("Elasticsearch authentication required in production")
            
            if "*" in self.server.cors_origins:
                errors.append("Wildcard CORS origins not allowed in production")
            
            if not self.security.api_keys and not self.security.jwt_enabled:
                errors.append("API key or JWT authentication required in production")
            
            if self.observability.log_request_body or self.observability.log_response_body:
                errors.append("Request/response body logging not allowed in production")
        
        # General validations
        if self.server.port < 1 or self.server.port > 65535:
            errors.append(f"Invalid server port: {self.server.port}")
        
        if self.resilience.max_retries < 0:
            errors.append("max_retries cannot be negative")
        
        if self.cache.similarity_threshold < 0 or self.cache.similarity_threshold > 1:
            errors.append("similarity_threshold must be between 0 and 1")
        
        return errors


# ========================================
# Environment Variable Loading
# ========================================

def _get_env(key: str, default: Any = None, cast: type = str) -> Any:
    """Get environment variable with type casting."""
    value = os.environ.get(key, default)
    
    if value is None:
        return default
    
    if cast == bool:
        if isinstance(value, bool):
            return value
        return value.lower() in ("true", "1", "yes", "on")
    
    if cast == list:
        if isinstance(value, list):
            return value
        return [v.strip() for v in value.split(",") if v.strip()]
    
    if cast == set:
        if isinstance(value, set):
            return value
        return {v.strip() for v in value.split(",") if v.strip()}
    
    try:
        return cast(value)
    except (ValueError, TypeError):
        return default


def load_settings_from_env() -> Settings:
    """Load settings from environment variables."""
    
    # Determine environment
    env_str = _get_env("MANGLE_ENV", "development")
    try:
        environment = Environment(env_str.lower())
    except ValueError:
        environment = Environment.DEVELOPMENT
    
    settings = Settings(
        environment=environment,
        service_name=_get_env("SERVICE_NAME", "mangle-query-service"),
        version=_get_env("SERVICE_VERSION", "1.0.0"),
        
        server=ServerConfig(
            host=_get_env("SERVER_HOST", "0.0.0.0"),
            port=_get_env("SERVER_PORT", 8080, int),
            workers=_get_env("SERVER_WORKERS", 4, int),
            debug=_get_env("DEBUG", False, bool),
            log_level=_get_env("LOG_LEVEL", "INFO"),
            cors_origins=_get_env("CORS_ORIGINS", ["*"], list),
            request_timeout=_get_env("REQUEST_TIMEOUT", 60.0, float),
        ),
        
        elasticsearch=ElasticsearchConfig(
            url=_get_env("ELASTICSEARCH_URL", "http://localhost:9200"),
            index_prefix=_get_env("ELASTICSEARCH_INDEX_PREFIX", "mangle"),
            username=_get_env("ELASTICSEARCH_USERNAME"),
            password=_get_env("ELASTICSEARCH_PASSWORD"),
            api_key=_get_env("ELASTICSEARCH_API_KEY"),
            ca_cert_path=_get_env("ELASTICSEARCH_CA_CERT"),
            timeout=_get_env("ELASTICSEARCH_TIMEOUT", 30.0, float),
            max_retries=_get_env("ELASTICSEARCH_MAX_RETRIES", 3, int),
            pool_size=_get_env("ELASTICSEARCH_POOL_SIZE", 10, int),
        ),
        
        hana=HANAConfig(
            host=_get_env("HANA_HOST", ""),
            port=_get_env("HANA_PORT", 443, int),
            user=_get_env("HANA_USER", ""),
            password=_get_env("HANA_PASSWORD", ""),
            schema=_get_env("HANA_SCHEMA", ""),
            encrypt=_get_env("HANA_ENCRYPT", True, bool),
            ssl_trust_store=_get_env("HANA_SSL_TRUST_STORE"),
            connection_pool_size=_get_env("HANA_POOL_SIZE", 5, int),
            statement_timeout=_get_env("HANA_STATEMENT_TIMEOUT", 300, int),
        ),
        
        llm=LLMBackendConfig(
            base_url=_get_env("LLM_BASE_URL", "http://localhost:8000/v1"),
            api_key=_get_env("LLM_API_KEY"),
            model=_get_env("LLM_MODEL", "gpt-4"),
            default_temperature=_get_env("LLM_TEMPERATURE", 0.7, float),
            max_tokens=_get_env("LLM_MAX_TOKENS", 4096, int),
            timeout=_get_env("LLM_TIMEOUT", 120.0, float),
            retry_count=_get_env("LLM_RETRY_COUNT", 2, int),
        ),
        
        aicore=AICoreSteamingConfig(
            base_url=_get_env("AICORE_BASE_URL", ""),
            client_id=_get_env("AICORE_CLIENT_ID", ""),
            client_secret=_get_env("AICORE_CLIENT_SECRET", ""),
            token_url=_get_env("AICORE_TOKEN_URL", ""),
            deployment_id=_get_env("AICORE_DEPLOYMENT_ID", ""),
            resource_group=_get_env("AICORE_RESOURCE_GROUP", "default"),
            timeout=_get_env("AICORE_TIMEOUT", 120.0, float),
        ),
        
        cache=CacheConfig(
            enabled=_get_env("CACHE_ENABLED", True, bool),
            ttl_seconds=_get_env("CACHE_TTL", 3600, int),
            max_entries=_get_env("CACHE_MAX_ENTRIES", 10000, int),
            semantic_cache_enabled=_get_env("SEMANTIC_CACHE_ENABLED", True, bool),
            similarity_threshold=_get_env("SEMANTIC_CACHE_THRESHOLD", 0.95, float),
        ),
        
        resilience=ResilienceConfig(
            retry_enabled=_get_env("RETRY_ENABLED", True, bool),
            max_retries=_get_env("MAX_RETRIES", 3, int),
            retry_base_delay=_get_env("RETRY_BASE_DELAY", 1.0, float),
            retry_max_delay=_get_env("RETRY_MAX_DELAY", 8.0, float),
            circuit_breaker_enabled=_get_env("CIRCUIT_BREAKER_ENABLED", True, bool),
            cb_failure_threshold=_get_env("CB_FAILURE_THRESHOLD", 5, int),
            cb_success_threshold=_get_env("CB_SUCCESS_THRESHOLD", 2, int),
            cb_recovery_timeout=_get_env("CB_RECOVERY_TIMEOUT", 30.0, float),
            default_timeout=_get_env("DEFAULT_TIMEOUT", 30.0, float),
            llm_timeout=_get_env("LLM_TIMEOUT", 120.0, float),
        ),
        
        security=SecurityConfig(
            api_key_header=_get_env("API_KEY_HEADER", "X-API-Key"),
            api_keys=_get_env("API_KEYS", set(), set),
            jwt_enabled=_get_env("JWT_ENABLED", False, bool),
            jwt_secret=_get_env("JWT_SECRET"),
            jwt_algorithm=_get_env("JWT_ALGORITHM", "HS256"),
            rate_limit_enabled=_get_env("RATE_LIMIT_ENABLED", True, bool),
            rate_limit_requests=_get_env("RATE_LIMIT_REQUESTS", 100, int),
            rate_limit_window=_get_env("RATE_LIMIT_WINDOW", 60, int),
        ),
        
        observability=ObservabilityConfig(
            metrics_enabled=_get_env("METRICS_ENABLED", True, bool),
            metrics_port=_get_env("METRICS_PORT", 9090, int),
            tracing_enabled=_get_env("TRACING_ENABLED", False, bool),
            tracing_endpoint=_get_env("TRACING_ENDPOINT", ""),
            log_format=_get_env("LOG_FORMAT", "json"),
            log_request_body=_get_env("LOG_REQUEST_BODY", False, bool),
            log_response_body=_get_env("LOG_RESPONSE_BODY", False, bool),
        ),
    )
    
    return settings


# ========================================
# Environment Presets
# ========================================

def get_development_settings() -> Settings:
    """Get development environment settings."""
    return Settings(
        environment=Environment.DEVELOPMENT,
        server=ServerConfig(
            debug=True,
            log_level="DEBUG",
            workers=1,
        ),
        cache=CacheConfig(
            enabled=False,
            ttl_seconds=60,
        ),
        resilience=ResilienceConfig(
            circuit_breaker_enabled=False,
            max_retries=1,
        ),
        security=SecurityConfig(
            rate_limit_enabled=False,
        ),
        observability=ObservabilityConfig(
            log_format="text",
            log_request_body=True,
            log_response_body=True,
        ),
    )


def get_staging_settings() -> Settings:
    """Get staging environment settings."""
    return Settings(
        environment=Environment.STAGING,
        server=ServerConfig(
            debug=False,
            log_level="INFO",
            workers=2,
        ),
        cache=CacheConfig(
            enabled=True,
            ttl_seconds=1800,
        ),
        resilience=ResilienceConfig(
            circuit_breaker_enabled=True,
            cb_failure_threshold=10,
        ),
        observability=ObservabilityConfig(
            tracing_enabled=True,
        ),
    )


def get_production_settings() -> Settings:
    """Get production environment settings."""
    return Settings(
        environment=Environment.PRODUCTION,
        server=ServerConfig(
            debug=False,
            log_level="WARNING",
            workers=4,
            cors_origins=[],
        ),
        cache=CacheConfig(
            enabled=True,
            ttl_seconds=3600,
            max_entries=50000,
        ),
        resilience=ResilienceConfig(
            circuit_breaker_enabled=True,
            cb_failure_threshold=5,
            cb_recovery_timeout=60.0,
        ),
        security=SecurityConfig(
            rate_limit_enabled=True,
            rate_limit_requests=1000,
        ),
        observability=ObservabilityConfig(
            metrics_enabled=True,
            tracing_enabled=True,
            log_format="json",
            log_request_body=False,
            log_response_body=False,
        ),
    )


# ========================================
# Singleton Pattern
# ========================================

_settings: Optional[Settings] = None


def get_settings(reload: bool = False) -> Settings:
    """
    Get application settings (singleton).
    
    Args:
        reload: Force reload from environment
    
    Returns:
        Settings instance
    """
    global _settings
    
    if _settings is None or reload:
        _settings = load_settings_from_env()
        
        # Validate settings
        errors = _settings.validate()
        if errors:
            for error in errors:
                logger.warning(f"Configuration warning: {error}")
            
            if _settings.is_production:
                raise ValueError(f"Configuration errors in production: {errors}")
    
    return _settings


def reset_settings() -> None:
    """Reset settings singleton (for testing)."""
    global _settings
    _settings = None


# ========================================
# Exports
# ========================================

__all__ = [
    "Environment",
    "ServerConfig",
    "ElasticsearchConfig",
    "HANAConfig",
    "LLMBackendConfig",
    "AICoreSteamingConfig",
    "CacheConfig",
    "ResilienceConfig",
    "SecurityConfig",
    "ObservabilityConfig",
    "Settings",
    "get_settings",
    "reset_settings",
    "load_settings_from_env",
    "get_development_settings",
    "get_staging_settings",
    "get_production_settings",
]