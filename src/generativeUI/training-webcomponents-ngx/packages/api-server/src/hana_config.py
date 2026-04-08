"""
Shared HANA Cloud connection configuration.

All modules that need HANA credentials should import from here
instead of reading os.getenv() independently.
"""

import os


HANA_HOST: str = os.getenv("HANA_HOST", "localhost")
HANA_PORT: int = int(os.getenv("HANA_PORT", "443"))
HANA_USER: str = os.getenv("HANA_USER", "")
HANA_PASSWORD: str = os.getenv("HANA_PASSWORD", "")
HANA_ENCRYPT: bool = os.getenv("HANA_ENCRYPT", "true").lower() == "true"

VLLM_URL: str = os.getenv("VLLM_URL", "http://vllm:8080")
