"""
Configuration management for SAP AI Fabric Console API
"""

from typing import List
from pydantic_settings import BaseSettings
from functools import lru_cache


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
        "http://localhost:5173",
    ]

    # JWT Authentication — jwt_secret_key MUST be set via env var
    jwt_secret_key: str
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 30
    jwt_refresh_token_expire_days: int = 7

    # Database
    database_url: str = "postgresql+asyncpg://localhost:5432/sap_ai_fabric"
    database_echo: bool = False

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # Kubernetes
    k8s_in_cluster: bool = False
    k8s_namespace: str = "default"
    kserve_namespace: str = "kserve-inference"

    # KServe / vLLM
    vllm_endpoint: str = "http://localhost:8080"
    default_model: str = "mistral-7b"

    # HANA Vector Store
    hana_host: str = "localhost"
    hana_port: int = 443
    hana_user: str = ""
    hana_password: str = ""
    hana_encrypt: bool = True

    # Prometheus
    prometheus_url: str = "http://localhost:9090"

    # Logging
    log_level: str = "INFO"
    log_format: str = "json"

    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "case_sensitive": False,
    }


@lru_cache()
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()


settings = get_settings()