from __future__ import annotations

import os
from pathlib import Path


def env_or_file(name: str, default: str = "") -> str:
    value = os.getenv(name)
    if value not in (None, ""):
        return value

    file_var = f"{name}_FILE"
    file_path = os.getenv(file_var)
    if file_path:
        return Path(file_path).read_text(encoding="utf-8").strip()

    return default


def int_env_or_file(name: str, default: int) -> int:
    return int(env_or_file(name, str(default)))


def bool_env_or_file(name: str, default: bool) -> bool:
    raw = env_or_file(name, "true" if default else "false").strip().lower()
    return raw in {"1", "true", "yes", "on"}
