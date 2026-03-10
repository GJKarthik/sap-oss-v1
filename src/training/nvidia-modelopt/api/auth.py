#!/usr/bin/env python3
"""
API Authentication Module
Validates Bearer tokens and API keys — keys are persisted in SQLite so they
survive service restarts.  Set MODELOPT_AUTH_DB to override the DB path
(use ":memory:" for tests).
"""

import os
import secrets
import hashlib
import logging
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Optional, Dict, Generator

from fastapi import HTTPException, Header, Depends, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

logger = logging.getLogger(__name__)

# Security configuration
DEFAULT_API_KEY = os.getenv("MODELOPT_API_KEY", "")
REQUIRE_AUTH = os.getenv("MODELOPT_REQUIRE_AUTH", "false").lower() == "true"
_AUTH_DB_PATH = os.getenv("MODELOPT_AUTH_DB", "auth_keys.db")

security = HTTPBearer(auto_error=False)

# ---------------------------------------------------------------------------
# SQLite-backed key store
# ---------------------------------------------------------------------------

_CREATE_KEYS_TABLE = """
CREATE TABLE IF NOT EXISTS api_keys (
    key_hash    TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    last_used   TEXT
);
"""


class ApiKeyStore:
    """SQLite-backed store for API key hashes — survives process restarts."""

    def __init__(self, db_path: str = _AUTH_DB_PATH):
        self._db_path = db_path
        self._ensure_schema()

    @contextmanager
    def _conn(self) -> Generator[sqlite3.Connection, None, None]:
        """Open a short-lived connection for a single operation (thread-safe)."""
        conn = sqlite3.connect(self._db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def _ensure_schema(self) -> None:
        try:
            with self._conn() as conn:
                conn.executescript(_CREATE_KEYS_TABLE)
            logger.debug("Auth key store ready (%s)", self._db_path)
        except Exception as exc:
            logger.error("Failed to initialise auth key store: %s", exc)

    def add(self, key_hash: str, name: str) -> None:
        with self._conn() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO api_keys (key_hash, name, created_at) VALUES (?, ?, ?)",
                (key_hash, name, datetime.now(timezone.utc).isoformat()),
            )

    def contains(self, key_hash: str) -> bool:
        with self._conn() as conn:
            cur = conn.execute(
                "SELECT 1 FROM api_keys WHERE key_hash = ?", (key_hash,)
            )
            return cur.fetchone() is not None

    def touch(self, key_hash: str) -> None:
        """Update last_used timestamp for an existing key."""
        with self._conn() as conn:
            conn.execute(
                "UPDATE api_keys SET last_used = ? WHERE key_hash = ?",
                (datetime.now(timezone.utc).isoformat(), key_hash),
            )

    def list_keys(self) -> list:
        with self._conn() as conn:
            cur = conn.execute(
                "SELECT key_hash, name, created_at, last_used FROM api_keys ORDER BY created_at DESC"
            )
            return [dict(r) for r in cur.fetchall()]

    def delete(self, key_hash: str) -> bool:
        with self._conn() as conn:
            cur = conn.execute(
                "DELETE FROM api_keys WHERE key_hash = ?", (key_hash,)
            )
            return cur.rowcount > 0


# Module-level singleton
_key_store: Optional[ApiKeyStore] = None


def get_key_store() -> ApiKeyStore:
    global _key_store
    if _key_store is None:
        _key_store = ApiKeyStore()
    return _key_store


def generate_api_key(name: str = "default") -> str:
    """Generate a new API key and persist its hash to SQLite."""
    key = f"mo-{secrets.token_hex(24)}"
    key_hash = hashlib.sha256(key.encode()).hexdigest()
    get_key_store().add(key_hash, name)
    return key


def validate_api_key(api_key: Optional[str]) -> bool:
    """Validate an API key against the SQLite store."""
    if not api_key:
        return False

    # Check against default env-var key (plaintext comparison — never stored)
    if DEFAULT_API_KEY and api_key == DEFAULT_API_KEY:
        return True

    # Check against persisted key hashes
    key_hash = hashlib.sha256(api_key.encode()).hexdigest()
    store = get_key_store()
    if store.contains(key_hash):
        store.touch(key_hash)
        return True

    return False


def extract_token(authorization: str) -> Optional[str]:
    """Extract token from Authorization header"""
    if not authorization:
        return None
    
    if authorization.startswith("Bearer "):
        return authorization[7:]
    
    return authorization


async def verify_auth(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    authorization: Optional[str] = Header(None),
) -> Optional[str]:
    """
    Dependency to verify authentication
    Returns the API key if valid, None if auth not required
    """
    # Get token from credentials or header
    token = None
    if credentials:
        token = credentials.credentials
    elif authorization:
        token = extract_token(authorization)
    
    # If auth not required and no token, allow access
    if not REQUIRE_AUTH and not token:
        return None
    
    # If auth required, validate token
    if REQUIRE_AUTH:
        if not token:
            raise HTTPException(
                status_code=401,
                detail={
                    "error": {
                        "message": "Missing authentication credentials",
                        "type": "authentication_error",
                        "param": None,
                        "code": "missing_token"
                    }
                }
            )
        
        if not validate_api_key(token):
            raise HTTPException(
                status_code=401,
                detail={
                    "error": {
                        "message": "Invalid API key provided",
                        "type": "authentication_error",
                        "param": None,
                        "code": "invalid_api_key"
                    }
                }
            )
    
    # If token provided but auth not required, still validate
    if token and not validate_api_key(token):
        logger.warning(f"Invalid API key attempted: {token[:10]}...")
    
    return token


class RateLimiter:
    """Simple in-memory rate limiter"""
    
    def __init__(self, requests_per_minute: int = 60):
        self.requests_per_minute = requests_per_minute
        self.requests: Dict[str, list] = {}
    
    def is_allowed(self, client_id: str) -> bool:
        """Check if request is allowed"""
        now = datetime.utcnow()
        window_start = now - timedelta(minutes=1)
        
        # Get or create request list for client
        if client_id not in self.requests:
            self.requests[client_id] = []
        
        # Remove old requests
        self.requests[client_id] = [
            t for t in self.requests[client_id] 
            if t > window_start
        ]
        
        # Check limit
        if len(self.requests[client_id]) >= self.requests_per_minute:
            return False
        
        # Record request
        self.requests[client_id].append(now)
        return True


rate_limiter = RateLimiter()


async def check_rate_limit(request: Request):
    """Dependency to check rate limit"""
    client_ip = request.client.host if request.client else "unknown"
    
    if not rate_limiter.is_allowed(client_ip):
        raise HTTPException(
            status_code=429,
            detail={
                "error": {
                    "message": "Rate limit exceeded. Please try again later.",
                    "type": "rate_limit_error",
                    "param": None,
                    "code": "rate_limit_exceeded"
                }
            }
        )


# Initialize with default key if set
if DEFAULT_API_KEY:
    logger.info("Default API key configured")
else:
    logger.info("No API key required (MODELOPT_REQUIRE_AUTH=false)")