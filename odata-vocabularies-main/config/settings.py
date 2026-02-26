"""
Production Configuration Settings

Centralized configuration for OData Vocabularies Universal Dictionary.
Supports environment variables with sensible defaults.
"""

import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional
from pathlib import Path
import json


@dataclass
class HANAConfig:
    """SAP HANA Cloud Configuration"""
    host: str = ""
    port: int = 443
    user: str = ""
    password: str = ""
    encrypt: bool = True
    ssl_validate_certificate: bool = True
    schema: str = ""
    connection_timeout: int = 30
    
    @classmethod
    def from_env(cls) -> "HANAConfig":
        """Load HANA config from environment variables"""
        return cls(
            host=os.getenv("HANA_HOST", ""),
            port=int(os.getenv("HANA_PORT", "443")),
            user=os.getenv("HANA_USER", ""),
            password=os.getenv("HANA_PASSWORD", ""),
            encrypt=os.getenv("HANA_ENCRYPT", "true").lower() == "true",
            ssl_validate_certificate=os.getenv("HANA_SSL_VALIDATE", "true").lower() == "true",
            schema=os.getenv("HANA_SCHEMA", ""),
            connection_timeout=int(os.getenv("HANA_TIMEOUT", "30"))
        )
    
    def is_configured(self) -> bool:
        """Check if HANA is properly configured"""
        return bool(self.host and self.user and self.password)


@dataclass
class ElasticsearchConfig:
    """Elasticsearch Configuration"""
    hosts: List[str] = field(default_factory=lambda: ["http://localhost:9200"])
    username: str = ""
    password: str = ""
    api_key: str = ""
    cloud_id: str = ""
    index_prefix: str = "odata"
    verify_certs: bool = True
    ca_certs: str = ""
    request_timeout: int = 30
    
    @classmethod
    def from_env(cls) -> "ElasticsearchConfig":
        """Load ES config from environment variables"""
        hosts = os.getenv("ES_HOSTS", "http://localhost:9200")
        return cls(
            hosts=hosts.split(","),
            username=os.getenv("ES_USERNAME", ""),
            password=os.getenv("ES_PASSWORD", ""),
            api_key=os.getenv("ES_API_KEY", ""),
            cloud_id=os.getenv("ES_CLOUD_ID", ""),
            index_prefix=os.getenv("ES_INDEX_PREFIX", "odata"),
            verify_certs=os.getenv("ES_VERIFY_CERTS", "true").lower() == "true",
            ca_certs=os.getenv("ES_CA_CERTS", ""),
            request_timeout=int(os.getenv("ES_TIMEOUT", "30"))
        )
    
    def is_configured(self) -> bool:
        """Check if ES is properly configured"""
        return bool(self.hosts and (self.api_key or (self.username and self.password) or self.cloud_id))


@dataclass
class OpenAIConfig:
    """OpenAI API Configuration for Embeddings"""
    api_key: str = ""
    model: str = "text-embedding-3-small"
    embedding_dimensions: int = 1536
    max_tokens: int = 8191
    batch_size: int = 100
    timeout: int = 60
    
    @classmethod
    def from_env(cls) -> "OpenAIConfig":
        """Load OpenAI config from environment variables"""
        return cls(
            api_key=os.getenv("OPENAI_API_KEY", ""),
            model=os.getenv("OPENAI_EMBEDDING_MODEL", "text-embedding-3-small"),
            embedding_dimensions=int(os.getenv("OPENAI_EMBEDDING_DIM", "1536")),
            max_tokens=int(os.getenv("OPENAI_MAX_TOKENS", "8191")),
            batch_size=int(os.getenv("OPENAI_BATCH_SIZE", "100")),
            timeout=int(os.getenv("OPENAI_TIMEOUT", "60"))
        )
    
    def is_configured(self) -> bool:
        """Check if OpenAI is properly configured"""
        return bool(self.api_key)


@dataclass
class AuthConfig:
    """API Authentication Configuration"""
    enabled: bool = False
    api_keys: List[str] = field(default_factory=list)
    jwt_secret: str = ""
    jwt_algorithm: str = "HS256"
    jwt_expiry_hours: int = 24
    oauth_provider: str = ""
    oauth_client_id: str = ""
    oauth_client_secret: str = ""
    oauth_token_url: str = ""
    rate_limit_enabled: bool = True
    rate_limit_requests: int = 100
    rate_limit_window_seconds: int = 60
    
    @classmethod
    def from_env(cls) -> "AuthConfig":
        """Load auth config from environment variables"""
        api_keys = os.getenv("API_KEYS", "")
        return cls(
            enabled=os.getenv("AUTH_ENABLED", "false").lower() == "true",
            api_keys=api_keys.split(",") if api_keys else [],
            jwt_secret=os.getenv("JWT_SECRET", ""),
            jwt_algorithm=os.getenv("JWT_ALGORITHM", "HS256"),
            jwt_expiry_hours=int(os.getenv("JWT_EXPIRY_HOURS", "24")),
            oauth_provider=os.getenv("OAUTH_PROVIDER", ""),
            oauth_client_id=os.getenv("OAUTH_CLIENT_ID", ""),
            oauth_client_secret=os.getenv("OAUTH_CLIENT_SECRET", ""),
            oauth_token_url=os.getenv("OAUTH_TOKEN_URL", ""),
            rate_limit_enabled=os.getenv("RATE_LIMIT_ENABLED", "true").lower() == "true",
            rate_limit_requests=int(os.getenv("RATE_LIMIT_REQUESTS", "100")),
            rate_limit_window_seconds=int(os.getenv("RATE_LIMIT_WINDOW", "60"))
        )
    
    def is_configured(self) -> bool:
        """Check if auth is properly configured"""
        return self.enabled and (bool(self.api_keys) or bool(self.jwt_secret) or bool(self.oauth_client_id))


@dataclass
class AuditConfig:
    """Audit Logging Configuration"""
    enabled: bool = True
    log_dir: str = "_audit_logs"
    max_entries_memory: int = 10000
    flush_interval_seconds: int = 60
    syslog_enabled: bool = False
    syslog_host: str = ""
    syslog_port: int = 514
    syslog_facility: str = "local0"
    elasticsearch_enabled: bool = False
    elasticsearch_index: str = "odata-audit"
    retention_days: int = 90
    
    @classmethod
    def from_env(cls) -> "AuditConfig":
        """Load audit config from environment variables"""
        return cls(
            enabled=os.getenv("AUDIT_ENABLED", "true").lower() == "true",
            log_dir=os.getenv("AUDIT_LOG_DIR", "_audit_logs"),
            max_entries_memory=int(os.getenv("AUDIT_MAX_ENTRIES", "10000")),
            flush_interval_seconds=int(os.getenv("AUDIT_FLUSH_INTERVAL", "60")),
            syslog_enabled=os.getenv("AUDIT_SYSLOG_ENABLED", "false").lower() == "true",
            syslog_host=os.getenv("AUDIT_SYSLOG_HOST", ""),
            syslog_port=int(os.getenv("AUDIT_SYSLOG_PORT", "514")),
            syslog_facility=os.getenv("AUDIT_SYSLOG_FACILITY", "local0"),
            elasticsearch_enabled=os.getenv("AUDIT_ES_ENABLED", "false").lower() == "true",
            elasticsearch_index=os.getenv("AUDIT_ES_INDEX", "odata-audit"),
            retention_days=int(os.getenv("AUDIT_RETENTION_DAYS", "90"))
        )


@dataclass
class ServerConfig:
    """MCP Server Configuration"""
    port: int = 9150
    host: str = "0.0.0.0"
    log_level: str = "INFO"
    cors_enabled: bool = True
    cors_origins: List[str] = field(default_factory=lambda: ["*"])
    ssl_enabled: bool = False
    ssl_cert_file: str = ""
    ssl_key_file: str = ""
    max_request_size: int = 10 * 1024 * 1024  # 10MB
    workers: int = 4
    
    @classmethod
    def from_env(cls) -> "ServerConfig":
        """Load server config from environment variables"""
        cors_origins = os.getenv("CORS_ORIGINS", "*")
        return cls(
            port=int(os.getenv("MCP_PORT", "9150")),
            host=os.getenv("MCP_HOST", "0.0.0.0"),
            log_level=os.getenv("LOG_LEVEL", "INFO"),
            cors_enabled=os.getenv("CORS_ENABLED", "true").lower() == "true",
            cors_origins=cors_origins.split(","),
            ssl_enabled=os.getenv("SSL_ENABLED", "false").lower() == "true",
            ssl_cert_file=os.getenv("SSL_CERT_FILE", ""),
            ssl_key_file=os.getenv("SSL_KEY_FILE", ""),
            max_request_size=int(os.getenv("MAX_REQUEST_SIZE", str(10 * 1024 * 1024))),
            workers=int(os.getenv("SERVER_WORKERS", "4"))
        )


@dataclass
class Settings:
    """Complete Application Settings"""
    hana: HANAConfig = field(default_factory=HANAConfig)
    elasticsearch: ElasticsearchConfig = field(default_factory=ElasticsearchConfig)
    openai: OpenAIConfig = field(default_factory=OpenAIConfig)
    auth: AuthConfig = field(default_factory=AuthConfig)
    audit: AuditConfig = field(default_factory=AuditConfig)
    server: ServerConfig = field(default_factory=ServerConfig)
    
    # Paths
    vocabularies_dir: str = ""
    embeddings_dir: str = ""
    mangle_dir: str = ""
    
    @classmethod
    def from_env(cls) -> "Settings":
        """Load all settings from environment variables"""
        base_dir = Path(__file__).parent.parent
        return cls(
            hana=HANAConfig.from_env(),
            elasticsearch=ElasticsearchConfig.from_env(),
            openai=OpenAIConfig.from_env(),
            auth=AuthConfig.from_env(),
            audit=AuditConfig.from_env(),
            server=ServerConfig.from_env(),
            vocabularies_dir=os.getenv("VOCABULARIES_DIR", str(base_dir / "vocabularies")),
            embeddings_dir=os.getenv("EMBEDDINGS_DIR", str(base_dir / "_embeddings")),
            mangle_dir=os.getenv("MANGLE_DIR", str(base_dir / "mangle"))
        )
    
    @classmethod
    def from_file(cls, config_file: str) -> "Settings":
        """Load settings from JSON config file"""
        with open(config_file, "r") as f:
            data = json.load(f)
        
        settings = cls.from_env()
        
        # Override with file values
        if "hana" in data:
            for key, value in data["hana"].items():
                if hasattr(settings.hana, key):
                    setattr(settings.hana, key, value)
        
        if "elasticsearch" in data:
            for key, value in data["elasticsearch"].items():
                if hasattr(settings.elasticsearch, key):
                    setattr(settings.elasticsearch, key, value)
        
        if "openai" in data:
            for key, value in data["openai"].items():
                if hasattr(settings.openai, key):
                    setattr(settings.openai, key, value)
        
        if "auth" in data:
            for key, value in data["auth"].items():
                if hasattr(settings.auth, key):
                    setattr(settings.auth, key, value)
        
        if "audit" in data:
            for key, value in data["audit"].items():
                if hasattr(settings.audit, key):
                    setattr(settings.audit, key, value)
        
        if "server" in data:
            for key, value in data["server"].items():
                if hasattr(settings.server, key):
                    setattr(settings.server, key, value)
        
        return settings
    
    def to_dict(self) -> Dict:
        """Convert settings to dictionary (masking sensitive values)"""
        return {
            "hana": {
                "host": self.hana.host,
                "port": self.hana.port,
                "user": self.hana.user,
                "password": "***" if self.hana.password else "",
                "schema": self.hana.schema,
                "configured": self.hana.is_configured()
            },
            "elasticsearch": {
                "hosts": self.elasticsearch.hosts,
                "username": self.elasticsearch.username,
                "index_prefix": self.elasticsearch.index_prefix,
                "configured": self.elasticsearch.is_configured()
            },
            "openai": {
                "model": self.openai.model,
                "embedding_dimensions": self.openai.embedding_dimensions,
                "configured": self.openai.is_configured()
            },
            "auth": {
                "enabled": self.auth.enabled,
                "rate_limit_enabled": self.auth.rate_limit_enabled,
                "configured": self.auth.is_configured()
            },
            "audit": {
                "enabled": self.audit.enabled,
                "log_dir": self.audit.log_dir,
                "syslog_enabled": self.audit.syslog_enabled,
                "elasticsearch_enabled": self.audit.elasticsearch_enabled
            },
            "server": {
                "port": self.server.port,
                "host": self.server.host,
                "log_level": self.server.log_level,
                "ssl_enabled": self.server.ssl_enabled
            }
        }
    
    def validate(self) -> Dict[str, List[str]]:
        """Validate settings and return any issues"""
        issues = {"errors": [], "warnings": []}
        
        # Check HANA
        if not self.hana.is_configured():
            issues["warnings"].append("HANA not configured - HANA integration disabled")
        
        # Check Elasticsearch
        if not self.elasticsearch.is_configured():
            issues["warnings"].append("Elasticsearch not configured - ES features disabled")
        
        # Check OpenAI
        if not self.openai.is_configured():
            issues["warnings"].append("OpenAI not configured - using placeholder embeddings")
        
        # Check Auth
        if not self.auth.enabled:
            issues["warnings"].append("Authentication disabled - API is publicly accessible")
        elif not self.auth.is_configured():
            issues["errors"].append("Auth enabled but no credentials configured")
        
        # Check paths
        if not Path(self.vocabularies_dir).exists():
            issues["errors"].append(f"Vocabularies directory not found: {self.vocabularies_dir}")
        
        return issues


# Singleton instance
_settings: Optional[Settings] = None


def get_settings(config_file: str = None) -> Settings:
    """Get or create the Settings singleton"""
    global _settings
    if _settings is None:
        if config_file and Path(config_file).exists():
            _settings = Settings.from_file(config_file)
        else:
            _settings = Settings.from_env()
    return _settings


def reload_settings(config_file: str = None) -> Settings:
    """Force reload settings"""
    global _settings
    _settings = None
    return get_settings(config_file)