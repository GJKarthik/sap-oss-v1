"""
Configuration management for SAP AI Fabric Console API.
Backed by SAP AI Core + HANA Cloud — no PostgreSQL or Redis required.
"""

from functools import lru_cache
from pathlib import Path
from typing import List, Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings

DEFAULT_JWT_SECRET = "change-me-in-production"
DEFAULT_STORE_DATABASE_PATH = Path(__file__).resolve().parents[1] / ".data" / "sap-ai-fabric-console.sqlite3"


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
    store_backend: Literal["sqlite", "hana"] = "sqlite"
    store_database_path: str = str(DEFAULT_STORE_DATABASE_PATH)
    expose_api_docs: bool | None = None
    auth_rate_limit_per_minute: int = 10
    mcp_rate_limit_per_minute: int = 120
    rate_limit_window_seconds: int = 60

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
        is_local_environment = self.environment.lower() in {"development", "dev", "local", "test"}
        backend = self.store_backend.lower()
        object.__setattr__(self, "store_backend", backend)

        if self.expose_api_docs is None:
            object.__setattr__(self, "expose_api_docs", is_local_environment or self.debug)
        if not is_local_environment:
            if self.jwt_secret_key == DEFAULT_JWT_SECRET:
                raise ValueError("JWT_SECRET_KEY must be changed outside development and test environments")

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

        return self


@lru_cache()
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()


settings = get_settings()
