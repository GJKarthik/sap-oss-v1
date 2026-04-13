"""
Shared runtime configuration.

Secrets can be provided either directly via ENV or through Docker-style
`*_FILE` variables that point at mounted secret files.
"""

from .runtime_env import bool_env_or_file, env_or_file, int_env_or_file


HANA_HOST: str = env_or_file("HANA_HOST", "localhost")
HANA_PORT: int = int_env_or_file("HANA_PORT", 443)
HANA_USER: str = env_or_file("HANA_USER", "")
HANA_PASSWORD: str = env_or_file("HANA_PASSWORD", "")
HANA_ENCRYPT: bool = bool_env_or_file("HANA_ENCRYPT", True)

VLLM_URL: str = env_or_file("VLLM_URL", "http://vllm:8080")
# Optional dedicated TurboQuant / vLLM inference host for health checks (falls back to VLLM_URL).
VLLM_TURBOQUANT_URL: str = env_or_file("VLLM_TURBOQUANT_URL", "")
# Optional PAL / AI Core PAL proxy base URL for readiness probes (same logical target as gateway AI_CORE_PAL_UPSTREAM).
PAL_UPSTREAM_URL: str = env_or_file("PAL_UPSTREAM_URL", "")

AICORE_CLIENT_ID: str = env_or_file("AICORE_CLIENT_ID", "")
AICORE_CLIENT_SECRET: str = env_or_file("AICORE_CLIENT_SECRET", "")
AICORE_AUTH_URL: str = env_or_file("AICORE_AUTH_URL", "")
AICORE_BASE_URL: str = env_or_file("AICORE_BASE_URL", "")
# Optional OpenAI/Anthropic-compatible proxy URL for chat (overrides AICORE_BASE_URL for LLMRouter).
AICORE_ANTHROPIC_URL: str = env_or_file("AICORE_ANTHROPIC_URL", "")
AICORE_RESOURCE_GROUP: str = env_or_file("AICORE_RESOURCE_GROUP", "default")


def vllm_probe_base_url() -> str:
    """Base URL for GET /health against the vLLM / TurboQuant deployment."""
    if VLLM_TURBOQUANT_URL.strip():
        return VLLM_TURBOQUANT_URL.strip().rstrip("/")
    return VLLM_URL.rstrip("/")


def aicore_fully_configured() -> bool:
    return bool(
        AICORE_CLIENT_ID.strip()
        and AICORE_CLIENT_SECRET.strip()
        and AICORE_AUTH_URL.strip()
        and AICORE_BASE_URL.strip()
    )


def aicore_anthropic_proxy_base() -> str:
    """Base URL for `/v1/chat/completions` style calls (LLMRouter)."""
    if AICORE_ANTHROPIC_URL.strip():
        return AICORE_ANTHROPIC_URL.strip().rstrip("/")
    if AICORE_BASE_URL.strip():
        return AICORE_BASE_URL.strip().rstrip("/")
    return "http://aicore-proxy:8080"
