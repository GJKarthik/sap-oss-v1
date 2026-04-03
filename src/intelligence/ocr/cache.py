"""Content-hash based caching for OCR results.

Avoids re-processing identical documents by keying cached results on a
composite hash of file content + service configuration.
"""

import hashlib
import json
import logging
import os
import threading
from dataclasses import asdict
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)


def _file_hash(file_path: str, algo: str = "sha256") -> str:
    """Compute a hex digest of a file's contents."""
    h = hashlib.new(algo)
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _config_hash(config: Dict[str, Any], algo: str = "sha256") -> str:
    """Compute a hex digest of a JSON-serialisable config dict."""
    raw = json.dumps(config, sort_keys=True, default=str).encode()
    return hashlib.new(algo, raw).hexdigest()


class OCRCache:
    """Thread-safe in-memory cache for OCRResult objects.

    Keys are derived from the SHA-256 of file contents combined with the
    SHA-256 of the service configuration, so any change to the file or
    config parameters invalidates the cache entry.

    Optionally supports a ``max_size`` eviction policy (LRU).
    """

    def __init__(self, max_size: int = 128):
        """
        Args:
            max_size: Maximum number of cached results.  When exceeded the
                      oldest entry is evicted.  0 = unlimited.
        """
        if max_size < 0:
            raise ValueError(f"max_size must be >= 0, got {max_size}")
        self.max_size = max_size
        self._store: Dict[str, Any] = {}
        self._order: list[str] = []
        self._lock = threading.Lock()

    def make_key(self, file_path: str, config: Dict[str, Any]) -> str:
        """Generate a cache key for *file_path* + *config*.

        Args:
            file_path: Path to the document.
            config: Service configuration dict (languages, dpi, etc.).

        Returns:
            Hex cache key string.
        """
        fh = _file_hash(file_path)
        ch = _config_hash(config)
        combined = f"{fh}:{ch}".encode()
        return hashlib.sha256(combined).hexdigest()

    def get(self, key: str) -> Optional[Any]:
        """Retrieve a cached result.

        Args:
            key: Cache key from ``make_key``.

        Returns:
            Cached OCRResult or None.
        """
        with self._lock:
            result = self._store.get(key)
            if result is not None:
                # Move to end (most recently used)
                if key in self._order:
                    self._order.remove(key)
                    self._order.append(key)
                logger.debug("Cache hit: %s", key[:12])
            return result

    def put(self, key: str, result: Any) -> None:
        """Store a result in the cache.

        Args:
            key: Cache key from ``make_key``.
            result: OCRResult to cache.
        """
        with self._lock:
            if key in self._store:
                self._order.remove(key)
            self._store[key] = result
            self._order.append(key)
            # Evict oldest if over capacity
            while self.max_size > 0 and len(self._store) > self.max_size:
                oldest = self._order.pop(0)
                self._store.pop(oldest, None)
                logger.debug("Cache evicted: %s", oldest[:12])

    def invalidate(self, key: str) -> None:
        """Remove a specific entry from the cache."""
        with self._lock:
            self._store.pop(key, None)
            if key in self._order:
                self._order.remove(key)

    def clear(self) -> None:
        """Remove all entries from the cache."""
        with self._lock:
            self._store.clear()
            self._order.clear()

    @property
    def size(self) -> int:
        """Number of entries currently in the cache."""
        return len(self._store)



class DiskCache:
    """SQLite-backed persistent cache for OCR results.

    Uses a single SQLite database file to store serialised OCR results.
    Thread-safe via SQLite's built-in locking.

    Usage::

        cache = DiskCache("/tmp/ocr_cache.db", max_size=256)
        key = cache.make_key(file_path, config_dict)
        cached = cache.get(key)
        if cached is None:
            result = service.process_pdf(file_path)
            cache.put(key, result)
    """

    def __init__(self, db_path: str, max_size: int = 256):
        """
        Args:
            db_path: Path to the SQLite database file (created if missing).
            max_size: Maximum number of cached entries.  0 = unlimited.
        """
        import sqlite3

        if max_size < 0:
            raise ValueError(f"max_size must be >= 0, got {max_size}")
        self.db_path = db_path
        self.max_size = max_size
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = threading.Lock()
        self._init_db()

    def _init_db(self) -> None:
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS ocr_cache ("
                "  key TEXT PRIMARY KEY,"
                "  value TEXT NOT NULL,"
                "  accessed_at REAL NOT NULL"
                ")"
            )
            self._conn.commit()

    def make_key(self, file_path: str, config: Dict[str, Any]) -> str:
        """Generate a cache key (same algorithm as OCRCache)."""
        fh = _file_hash(file_path)
        ch = _config_hash(config)
        combined = f"{fh}:{ch}".encode()
        return hashlib.sha256(combined).hexdigest()

    def get(self, key: str) -> Optional[Any]:
        """Retrieve a cached result from disk.

        Returns:
            Deserialised object or None.
        """
        import time

        with self._lock:
            cur = self._conn.execute(
                "SELECT value FROM ocr_cache WHERE key = ?", (key,)
            )
            row = cur.fetchone()
            if row is not None:
                # Update access time for LRU
                self._conn.execute(
                    "UPDATE ocr_cache SET accessed_at = ? WHERE key = ?",
                    (time.time(), key),
                )
                self._conn.commit()
                logger.debug("Disk cache hit: %s", key[:12])
                return json.loads(row[0])
            return None

    def put(self, key: str, result: Any) -> None:
        """Store a result on disk.

        The result is serialised to JSON.  For ``OCRResult`` objects, call
        ``result.to_dict()`` before passing.
        """
        import time

        serialised = json.dumps(
            result if isinstance(result, (dict, list, str, int, float))
            else (result.to_dict() if hasattr(result, "to_dict") else str(result)),
            default=str,
        )
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO ocr_cache (key, value, accessed_at) "
                "VALUES (?, ?, ?)",
                (key, serialised, time.time()),
            )
            self._conn.commit()
            self._evict()

    def _evict(self) -> None:
        """Evict oldest entries if over capacity (must hold lock)."""
        if self.max_size <= 0:
            return
        cur = self._conn.execute("SELECT COUNT(*) FROM ocr_cache")
        count = cur.fetchone()[0]
        if count > self.max_size:
            excess = count - self.max_size
            self._conn.execute(
                "DELETE FROM ocr_cache WHERE key IN ("
                "  SELECT key FROM ocr_cache ORDER BY accessed_at ASC LIMIT ?"
                ")",
                (excess,),
            )
            self._conn.commit()

    def invalidate(self, key: str) -> None:
        """Remove a specific entry."""
        with self._lock:
            self._conn.execute("DELETE FROM ocr_cache WHERE key = ?", (key,))
            self._conn.commit()

    def clear(self) -> None:
        """Remove all entries."""
        with self._lock:
            self._conn.execute("DELETE FROM ocr_cache")
            self._conn.commit()

    @property
    def size(self) -> int:
        """Number of entries currently in the cache."""
        cur = self._conn.execute("SELECT COUNT(*) FROM ocr_cache")
        return cur.fetchone()[0]

    def close(self) -> None:
        """Close the database connection."""
        self._conn.close()
