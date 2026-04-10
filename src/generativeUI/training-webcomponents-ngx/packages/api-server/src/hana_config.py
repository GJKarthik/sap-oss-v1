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

AICORE_CLIENT_ID: str = env_or_file("AICORE_CLIENT_ID", "")
AICORE_CLIENT_SECRET: str = env_or_file("AICORE_CLIENT_SECRET", "")
AICORE_AUTH_URL: str = env_or_file("AICORE_AUTH_URL", "")
AICORE_BASE_URL: str = env_or_file("AICORE_BASE_URL", "")
AICORE_RESOURCE_GROUP: str = env_or_file("AICORE_RESOURCE_GROUP", "default")
