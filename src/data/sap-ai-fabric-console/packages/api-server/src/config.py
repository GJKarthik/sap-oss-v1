"""
Configuration management for SAP AI Fabric Console API.
Backed by SAP AI Core + HANA Cloud — no PostgreSQL or Redis required.
"""

from functools import lru_cache
from pathlib import Path
from typing import List, Literal
from urllib.parse import urlparse

from pydantic import model_validator
from pydantic_settings import BaseSettings

DEFAULT_JWT_SECRET = "change-me-in-production"
DEFAULT_STORE_DATABASE_PATH = Path(__file__).resolve().parents[1] / ".data" / "sap-ai-fabric-console.sqlite3"
LOCAL_ENVIRONMENTS = {"development", "dev", "local", "test"}


def _is_local_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.hostname in {"localhost", "127.0.0.1"}


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # Application
    app_name: str = "SAP AI Fabric Console API"
    debug: bool = False
    environment: str = "development"

    # Server
    host: str = "0.0.0.0"
    port: int = 8000

    # CORS
    cors_origins: List[str] = [
        "http://localhost:3000",
        "http://localhost:3001",
        "http://localhost:4200",
        "http://localhost:4202",
        "http://localhost:5173",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:3001",
        "http://127.0.0.1:4200",
        "http://127.0.0.1:4202",
        "http://127.0.0.1:5173",
    ]

    # JWT Authentication — jwt_secret_key MUST be set via env var
    jwt_secret_key: str = DEFAULT_JWT_SECRET
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 30
    jwt_refresh_token_expire_days: int = 7
    bootstrap_admin_username: str = ""
    bootstrap_admin_password: str = ""
    bootstrap_admin_email: str = "admin@sap-ai-fabric.local"
    seed_reference_data: bool | None = None
    store_backend: Literal["sqlite", "hana"] = "sqlite"
    store_database_path: str = str(DEFAULT_STORE_DATABASE_PATH)
    expose_api_docs: bool | None = None
    auth_rate_limit_per_minute: int = 10
    mcp_rate_limit_per_minute: int = 120
    rate_limit_window_seconds: int = 60
    require_mcp_dependencies: bool | None = None
    mcp_healthcheck_timeout_seconds: float = 5.0

    # SAP AI Core
    aicore_client_id: str = ""
    aicore_client_secret: str = ""
    aicore_auth_url: str = ""
    aicore_base_url: str = ""
    aicore_resource_group: str = "default"

    # HANA Cloud Vector Engine
    hana_host: str = ""
    hana_port: int = 443
    hana_user: str = ""
    hana_password: str = ""
    hana_encrypt: bool = True
    hana_store_schema: str = ""
    hana_store_table_prefix: str = "SAP_AIFABRIC"

    # MCP service endpoints (used by metrics health probes)
    langchain_mcp_url: str = "http://localhost:9140/mcp"
    streaming_mcp_url: str = "http://localhost:9190/mcp"

    # Logging
    log_level: str = "INFO"
    log_format: str = "json"

    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "case_sensitive": False,
    }

    @model_validator(mode="after")
    def validate_security_settings(self) -> "Settings":
        """Reject insecure defaults outside local development and tests."""
        is_local_environment = self.environment.lower() in LOCAL_ENVIRONMENTS
        backend = self.store_backend.lower()
        object.__setattr__(self, "store_backend", backend)

        if self.expose_api_docs is None:
            object.__setattr__(self, "expose_api_docs", is_local_environment or self.debug)
        if self.seed_reference_data is None:
            object.__setattr__(self, "seed_reference_data", is_local_environment)
        if self.require_mcp_dependencies is None:
            object.__setattr__(self, "require_mcp_dependencies", not is_local_environment)
        if not is_local_environment:
            if self.jwt_secret_key == DEFAULT_JWT_SECRET:
                raise ValueError("JWT_SECRET_KEY must be changed outside development and test environments")
            if backend != "hana":
                raise ValueError("STORE_BACKEND must be set to 'hana' outside development and test environments")
            username = self.bootstrap_admin_username.strip()
            password = self.bootstrap_admin_password
            if bool(username) != bool(password):
                raise ValueError(
                    "BOOTSTRAP_ADMIN_USERNAME and BOOTSTRAP_ADMIN_PASSWORD must be provided together"
                )
            if password:
                if password == "changeme":
                    raise ValueError("BOOTSTRAP_ADMIN_PASSWORD must not use the demo default password")
                if len(password) < 12:
                    raise ValueError("BOOTSTRAP_ADMIN_PASSWORD must be at least 12 characters long")

        if backend == "hana":
            missing = [
                field_name
                for field_name, value in (
                    ("HANA_HOST", self.hana_host),
                    ("HANA_USER", self.hana_user),
                    ("HANA_PASSWORD", self.hana_password),
                )
                if not value
            ]
            if missing:
                raise ValueError(
                    "HANA store backend requires the following settings: " + ", ".join(missing)
                )
            cleaned_prefix = "".join(
                character if character.isalnum() or character == "_" else "_"
                for character in self.hana_store_table_prefix
            ).strip("_").upper()
            if not cleaned_prefix:
                raise ValueError("HANA_STORE_TABLE_PREFIX must contain at least one alphanumeric character")
            object.__setattr__(self, "hana_store_table_prefix", cleaned_prefix)

        if self.require_mcp_dependencies:
            missing_upstreams = [
                field_name
                for field_name, value in (
                    ("LANGCHAIN_MCP_URL", self.langchain_mcp_url),
                    ("STREAMING_MCP_URL", self.streaming_mcp_url),
                )
                if not value
            ]
            if missing_upstreams:
                raise ValueError(
                    "MCP dependency checks require the following settings: " + ", ".join(missing_upstreams)
                )
            if not is_local_environment:
                local_upstreams = [
                    field_name
                    for field_name, value in (
                        ("LANGCHAIN_MCP_URL", self.langchain_mcp_url),
                        ("STREAMING_MCP_URL", self.streaming_mcp_url),
                    )
                    if _is_local_url(value)
                ]
                if local_upstreams:
                    raise ValueError(
                        "Production MCP upstreams must not point to localhost: " + ", ".join(local_upstreams)
                    )

        return self


@lru_cache()
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()


settings = get_settings()
