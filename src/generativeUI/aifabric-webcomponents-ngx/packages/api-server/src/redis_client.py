"""
Persistent token revocation helpers backed by the configured shared store.
"""

from .store import get_store

# ---------------------------------------------------------------------------
# Lifecycle stubs (no-ops — kept so main.py callers need no changes)
# ---------------------------------------------------------------------------


async def init_redis() -> None:
    """No-op compatibility hook — token revocation is handled by the shared store."""


async def close_redis() -> None:
    """No-op compatibility hook — token revocation is handled by the shared store."""


# ---------------------------------------------------------------------------
# Token revocation helpers
# ---------------------------------------------------------------------------


async def revoke_token(jti: str, expire_seconds: int) -> None:
    """Add a token JTI to the persistent revocation store."""
    get_store().revoke_jti(jti, expire_seconds)


async def is_token_revoked(jti: str) -> bool:
    """Return True if the token JTI has been revoked."""
    return get_store().is_jti_revoked(jti)


# ---------------------------------------------------------------------------
# Health helper
# ---------------------------------------------------------------------------


async def check_redis() -> str:
    """Compatibility health check for the persistent token revocation store."""
    return "ok"
