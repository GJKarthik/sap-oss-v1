"""
Configuration Management with Validation.

Production-ready configuration with:
- Environment variable loading
- Type validation
- Secrets handling
- Configuration validation on startup
"""

import os
import logging
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set
from functools import lru_cache

logger = logging.getLogger(__name__)


def get_env(key: str, default: Any = None, required: bool = False) -> str:
    """Get environment variable with validation."""
    value = os.getenv(key, default)
    if required and value is None:
        raise ConfigurationError(f"Required environment variable {key} is not set")
    return value


def get_env_int(key: str, default: int = 0, required: bool = False) -> int:
    """Get integer environment variable."""
    value = get_env(key, str(default), required)
    try:
        return int(value)
    except ValueError:
        raise ConfigurationError(f"Environment variable {key} must be an integer, got: {value}")


def get_env_float(key: str, default: float = 0.0, required: bool = False) -> float:
    """Get float environment variable."""
    value = get_env(key, str(default), required)
    try:
        return float(value)
    except ValueError:
        raise ConfigurationError(f"Environment variable {key} must be a float, got: {value}")


def get_env_bool(key: str, default: bool = False) -> bool:
    """Get boolean environment variable."""
    value = get_env(key, str(default)).lower()
    return value in ("true", "1", "yes", "on")


def get_env_list(key: str, default: str = "", separator: str = ",") -> List[str]:
    """Get list environment variable."""
    value = get_env(key, default)
    if not value:
        return []
    return [item.strip() for item in value.split(separator) if item.strip()]


class ConfigurationError(Exception):
    """Configuration validation error."""
    pass


@dataclass
class HANASettings:
    """HANA connection settings."""
    host: str = field(default_factory=lambda: get_env("HANA_HOST", ""))
    port: int = field(default_factory=lambda: get_env_int("HANA_PORT", 443))
    user: str = field(default_factory=lambda: get_env("HANA_USER", ""))
    password: str = field(default_factory=lambda: get_env("HANA_PASSWORD", ""))
    encrypt: bool = field(default_factory=lambda: get_env_bool("HANA_ENCRYPT", True))
    internal_embedding_model: str = field(
        default_factory=lambda: get_env("HANA_INTERNAL_EMBEDDING_MODEL", "SAP_NEB_V2")
    )
    default_table: str = field(
        default_factory=lambda: get_env("HANA_DEFAULT_TABLE", "VECTOR_STORE")
    )
    
    def is_configured(self) -> bool:
        """Check if HANA is configured."""
        return bool(self.host and self.user)
    
    def get_connection_string(self) -> str:
        """Get HANA connection string (without password)."""
        return f"hdbcli://{self.user}@{self.host}:{self.port}"
    
    def validate(self) -> List[str]:
        """Validate HANA settings."""
        errors = []
        if self.host and not self.user:
            errors.append("HANA_USER is required when HANA_HOST is set")
        if self.host and not self.password:
            errors.append("HANA_PASSWORD is required when HANA_HOST is set")
        if self.port < 1 or self.port > 65535:
            errors.append(f"HANA_PORT must be 1-65535, got: {self.port}")
        return errors


@dataclass
class ElasticsearchSettings:
    """Elasticsearch settings."""
    url: str = field(default_factory=lambda: get_env("ES_URL", "http://localhost:9200"))
    index_prefix: str = field(default_factory=lambda: get_env("ES_INDEX_PREFIX", "mangle"))
    username: str = field(default_factory=lambda: get_env("ES_USERNAME", ""))
    password: str = field(default_factory=lambda: get_env("ES_PASSWORD", ""))
    timeout: int = field(default_factory=lambda: get_env_int("ES_TIMEOUT", 30))
    
    def validate(self) -> List[str]:
        errors = []
        if not self.url.startswith(("http://", "https://")):
            errors.append(f"ES_URL must start with http:// or https://, got: {self.url}")
        return errors


@dataclass
class CacheSettings:
    """Cache settings."""
    max_size: int = field(default_factory=lambda: get_env_int("HANA_CACHE_MAX_SIZE", 10000))
    ttl_seconds: int = field(default_factory=lambda: get_env_int("HANA_CACHE_TTL_SECONDS", 3600))
    similarity_threshold: float = field(
        default_factory=lambda: get_env_float("SEMANTIC_SIMILARITY_THRESHOLD", 0.92)
    )
    
    def validate(self) -> List[str]:
        errors = []
        if self.max_size < 0:
            errors.append(f"HANA_CACHE_MAX_SIZE must be >= 0, got: {self.max_size}")
        if self.ttl_seconds < 0:
            errors.append(f"HANA_CACHE_TTL_SECONDS must be >= 0, got: {self.ttl_seconds}")
        if not 0 <= self.similarity_threshold <= 1:
            errors.append(f"SEMANTIC_SIMILARITY_THRESHOLD must be 0-1, got: {self.similarity_threshold}")
        return errors


@dataclass
class CircuitBreakerSettings:
    """Circuit breaker settings."""
    failure_threshold: int = field(default_factory=lambda: get_env_int("HANA_CB_FAILURE_THRESHOLD", 5))
    recovery_timeout: float = field(default_factory=lambda: get_env_float("HANA_CB_RECOVERY_TIMEOUT", 30.0))
    half_open_requests: int = field(default_factory=lambda: get_env_int("HANA_CB_HALF_OPEN_REQUESTS", 3))
    success_threshold: int = field(default_factory=lambda: get_env_int("HANA_CB_SUCCESS_THRESHOLD", 2))
    
    def validate(self) -> List[str]:
        errors = []
        if self.failure_threshold < 1:
            errors.append(f"HANA_CB_FAILURE_THRESHOLD must be >= 1, got: {self.failure_threshold}")
        if self.recovery_timeout < 0:
            errors.append(f"HANA_CB_RECOVERY_TIMEOUT must be >= 0, got: {self.recovery_timeout}")
        return errors


@dataclass
class RateLimitSettings:
    """Rate limiting settings."""
    global_limit: int = field(default_factory=lambda: get_env_int("RATE_LIMIT_GLOBAL", 1000))
    per_client_limit: int = field(default_factory=lambda: get_env_int("RATE_LIMIT_PER_CLIENT", 100))
    burst_multiplier: float = field(default_factory=lambda: get_env_float("RATE_LIMIT_BURST_MULTIPLIER", 1.5))
    adaptive: bool = field(default_factory=lambda: get_env_bool("RATE_LIMIT_ADAPTIVE", True))
    
    def validate(self) -> List[str]:
        errors = []
        if self.global_limit < 1:
            errors.append(f"RATE_LIMIT_GLOBAL must be >= 1, got: {self.global_limit}")
        if self.per_client_limit < 1:
            errors.append(f"RATE_LIMIT_PER_CLIENT must be >= 1, got: {self.per_client_limit}")
        return errors


@dataclass
class ObservabilitySettings:
    """Observability settings."""
    otel_enabled: bool = field(default_factory=lambda: get_env_bool("OTEL_ENABLED", True))
    otel_endpoint: str = field(
        default_factory=lambda: get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
    )
    metrics_enabled: bool = field(default_factory=lambda: get_env_bool("METRICS_ENABLED", True))
    metrics_port: int = field(default_factory=lambda: get_env_int("METRICS_PORT", 9090))
    log_level: str = field(default_factory=lambda: get_env("LOG_LEVEL", "INFO"))
    log_format: str = field(default_factory=lambda: get_env("LOG_FORMAT", "json"))
    
    def validate(self) -> List[str]:
        errors = []
        valid_levels = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
        if self.log_level.upper() not in valid_levels:
            errors.append(f"LOG_LEVEL must be one of {valid_levels}, got: {self.log_level}")
        return errors


@dataclass
class ServerSettings:
    """Server settings."""
    host: str = field(default_factory=lambda: get_env("HOST", "0.0.0.0"))
    port: int = field(default_factory=lambda: get_env_int("PORT", 8080))
    workers: int = field(default_factory=lambda: get_env_int("WORKERS", 1))
    cors_origins: List[str] = field(default_factory=lambda: get_env_list("CORS_ORIGINS", "*"))
    mcp_host: str = field(default_factory=lambda: get_env("MCP_HOST", "0.0.0.0"))
    mcp_port: int = field(default_factory=lambda: get_env_int("MCP_PORT", 9150))
    
    def validate(self) -> List[str]:
        errors = []
        if self.port < 1 or self.port > 65535:
            errors.append(f"PORT must be 1-65535, got: {self.port}")
        if self.workers < 1:
            errors.append(f"WORKERS must be >= 1, got: {self.workers}")
        return errors


@dataclass
class Settings:
    """Complete application settings."""
    hana: HANASettings = field(default_factory=HANASettings)
    elasticsearch: ElasticsearchSettings = field(default_factory=ElasticsearchSettings)
    cache: CacheSettings = field(default_factory=CacheSettings)
    circuit_breaker: CircuitBreakerSettings = field(default_factory=CircuitBreakerSettings)
    rate_limit: RateLimitSettings = field(default_factory=RateLimitSettings)
    observability: ObservabilitySettings = field(default_factory=ObservabilitySettings)
    server: ServerSettings = field(default_factory=ServerSettings)
    
    # Feature flags
    query_rewrite_enabled: bool = field(default_factory=lambda: get_env_bool("QUERY_REWRITE_ENABLED", True))
    rerank_enabled: bool = field(default_factory=lambda: get_env_bool("RERANK_ENABLED", True))
    speculative_enabled: bool = field(default_factory=lambda: get_env_bool("SPECULATIVE_ENABLED", True))
    
    def validate(self) -> List[str]:
        """Validate all settings."""
        errors = []
        errors.extend(self.hana.validate())
        errors.extend(self.elasticsearch.validate())
        errors.extend(self.cache.validate())
        errors.extend(self.circuit_breaker.validate())
        errors.extend(self.rate_limit.validate())
        errors.extend(self.observability.validate())
        errors.extend(self.server.validate())
        return errors
    
    def validate_or_raise(self) -> None:
        """Validate settings and raise if invalid."""
        errors = self.validate()
        if errors:
            for error in errors:
                logger.error(f"Configuration error: {error}")
            raise ConfigurationError(f"Configuration validation failed: {errors}")
    
    def to_dict(self, include_secrets: bool = False) -> Dict[str, Any]:
        """Convert settings to dictionary."""
        result = {
            "hana": {
                "host": self.hana.host,
                "port": self.hana.port,
                "user": self.hana.user,
                "encrypt": self.hana.encrypt,
                "default_table": self.hana.default_table,
            },
            "elasticsearch": {
                "url": self.elasticsearch.url,
                "index_prefix": self.elasticsearch.index_prefix,
            },
            "cache": {
                "max_size": self.cache.max_size,
                "ttl_seconds": self.cache.ttl_seconds,
                "similarity_threshold": self.cache.similarity_threshold,
            },
            "circuit_breaker": {
                "failure_threshold": self.circuit_breaker.failure_threshold,
                "recovery_timeout": self.circuit_breaker.recovery_timeout,
            },
            "rate_limit": {
                "global_limit": self.rate_limit.global_limit,
                "per_client_limit": self.rate_limit.per_client_limit,
            },
            "server": {
                "host": self.server.host,
                "port": self.server.port,
                "workers": self.server.workers,
            },
            "features": {
                "query_rewrite": self.query_rewrite_enabled,
                "rerank": self.rerank_enabled,
                "speculative": self.speculative_enabled,
            }
        }
        
        if include_secrets:
            result["hana"]["password"] = "***REDACTED***"
            result["elasticsearch"]["password"] = "***REDACTED***" if self.elasticsearch.password else None
        
        return result


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Get cached settings singleton."""
    settings = Settings()
    settings.validate_or_raise()
    return settings


def reload_settings() -> Settings:
    """Reload settings (clears cache)."""
    get_settings.cache_clear()
    return get_settings()