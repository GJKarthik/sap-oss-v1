"""Mangle gRPC client for runtime configuration."""
import logging
import os
import threading
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

_lock = threading.Lock()
_instance = None


class MangleClient:
    """Thread-safe Mangle gRPC client with fallback cache."""

    def __init__(self, host: str = None, port: int = None):
        self.host = host or os.environ.get("MANGLE_GRPC_HOST", "localhost")
        self.port = port or int(os.environ.get("MANGLE_GRPC_PORT", "50051"))
        self._channel = None
        self._stub = None
        self._available = None
        self._cache = ConfigCache()
        self._connect()

    def _connect(self):
        """Attempt gRPC connection."""
        try:
            import grpc
            from hana_ai.mangle.query_pb2_grpc import MangleQueryServiceStub
            from hana_ai.mangle.query_pb2 import QueryRequest
            self._channel = grpc.insecure_channel(f"{self.host}:{self.port}")
            self._stub = MangleQueryServiceStub(self._channel)
            # Quick health check
            try:
                import socket
                with socket.create_connection((self.host, self.port), timeout=0.5):
                    self._available = True
                    logger.info("Mangle gRPC connected at %s:%d", self.host, self.port)
            except (socket.error, OSError):
                self._available = False
                logger.info("Mangle gRPC not available at %s:%d, using cache fallback", self.host, self.port)
        except ImportError:
            self._available = False
            logger.info("grpcio not installed, using config cache fallback")

    def query(self, predicate: str, *args) -> List[Dict]:
        """Query a Mangle predicate. Falls back to cache if gRPC unavailable."""
        if self._available and self._stub:
            try:
                from hana_ai.mangle.query_pb2 import QueryRequest
                request = QueryRequest(predicate=predicate, args=[str(a) for a in args])
                response = self._stub.Query(request, timeout=2.0)
                results = []
                for r in response.results:
                    results.append(dict(r.fields))
                # Update cache with fresh results
                cache_key = f"{predicate}({','.join(str(a) for a in args)})"
                self._cache.set(cache_key, results)
                return results
            except Exception as e:
                logger.warning("Mangle gRPC query failed for %s: %s, using cache", predicate, e)
                self._available = False

        # Fallback to cache
        cache_key = f"{predicate}({','.join(str(a) for a in args)})"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached
        return []

    def close(self):
        """Close the gRPC channel."""
        if self._channel:
            self._channel.close()
            self._channel = None


class ConfigCache:
    """JSON file cache for Mangle query results when gRPC is unavailable."""

    def __init__(self, cache_file: str = None):
        self._cache_file = cache_file or os.path.join(
            os.path.dirname(__file__), ".mangle_cache.json"
        )
        self._data: Dict[str, Any] = {}
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        """Load cache from disk."""
        import json
        try:
            with open(self._cache_file, "r") as f:
                self._data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self._data = {}

    def get(self, key: str) -> Optional[List[Dict]]:
        with self._lock:
            return self._data.get(key)

    def set(self, key: str, value: List[Dict]):
        with self._lock:
            self._data[key] = value
            self._save()

    def _save(self):
        import json
        try:
            with open(self._cache_file, "w") as f:
                json.dump(self._data, f, indent=2, default=str)
        except OSError as e:
            logger.warning("Failed to save Mangle config cache: %s", e)


def _get_instance() -> MangleClient:
    """Get or create the singleton MangleClient."""
    global _instance
    if _instance is None:
        with _lock:
            if _instance is None:
                _instance = MangleClient()
    return _instance


def get_config_value(predicate: str, key: str, default: Any = None) -> Any:
    """Convenience function to query a single config value from Mangle.

    Example: get_config_value("service_port", "mcp_toolkit", 8001)
    """
    client = _get_instance()
    results = client.query(predicate, key)
    if results:
        # Return the first result's value
        first = results[0]
        if isinstance(first, dict):
            # Return the value field or the whole dict
            return first.get("value", first.get(key, default))
        return first
    return default
