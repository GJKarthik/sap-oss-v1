"""HippoCPP Python API compatibility layer.

This module provides the canonical `hippocpp` Python API surface while the
native Zig/Mojo execution engine is being migrated. It delegates execution to
the configured backend module and normalizes return types into HippoCPP-owned
wrappers (`Database`, `Connection`, `PreparedStatement`, `QueryResult`).
"""

from __future__ import annotations

import importlib
import os
from typing import Any

_BACKEND_MODULE_NAME = os.environ.get("HIPPOCPP_SEMANTIC_BACKEND", "hippocpp.native_zig")
try:
    _backend = importlib.import_module(_BACKEND_MODULE_NAME)
except Exception:
    if os.environ.get("HIPPOCPP_ALLOW_KUZU_FALLBACK") == "1" and _BACKEND_MODULE_NAME != "kuzu":
        _BACKEND_MODULE_NAME = "kuzu"
        _backend = importlib.import_module(_BACKEND_MODULE_NAME)
    else:
        raise


def backend_module_name() -> str:
    """Return the loaded backend module name."""

    return _BACKEND_MODULE_NAME


def _unwrap_database(database: Any) -> Any:
    if isinstance(database, Database):
        return database._impl
    return database


def _unwrap_prepared(statement: Any) -> Any:
    if isinstance(statement, PreparedStatement):
        return statement._impl
    return statement


def _wrap_query_result(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, list):
        return [QueryResult(entry) for entry in value]
    return QueryResult(value)


class QueryResult:
    """Wrapper around backend query results."""

    def __init__(self, impl: Any):
        self._impl = impl

    def get_column_names(self) -> list[str]:
        return self._impl.get_column_names()

    def get_column_data_types(self) -> list[str]:
        return self._impl.get_column_data_types()

    def has_next(self) -> bool:
        return bool(self._impl.has_next())

    def get_next(self) -> Any:
        return self._impl.get_next()

    def close(self) -> None:
        close = getattr(self._impl, "close", None)
        if callable(close):
            close()

    def __iter__(self):  # type: ignore[override]
        while self.has_next():
            yield self.get_next()

    def __enter__(self) -> "QueryResult":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.close()
        return False

    def __getattr__(self, item: str) -> Any:
        return getattr(self._impl, item)


class PreparedStatement:
    """Wrapper around backend prepared statements."""

    def __init__(self, impl: Any):
        self._impl = impl

    def __getattr__(self, item: str) -> Any:
        return getattr(self._impl, item)


class Database:
    """HippoCPP database handle."""

    def __init__(self, database_path: str, *args: Any, **kwargs: Any):
        self._impl = _backend.Database(database_path, *args, **kwargs)

    def close(self) -> None:
        close = getattr(self._impl, "close", None)
        if callable(close):
            close()

    def __getattr__(self, item: str) -> Any:
        return getattr(self._impl, item)


class Connection:
    """HippoCPP connection handle."""

    def __init__(self, database: Database | Any, *args: Any, **kwargs: Any):
        self._impl = _backend.Connection(_unwrap_database(database), *args, **kwargs)

    def execute(self, query_or_statement: str | PreparedStatement | Any, parameters: dict[str, Any] | None = None) -> Any:
        statement = _unwrap_prepared(query_or_statement)
        if parameters is None:
            result = self._impl.execute(statement)
        else:
            result = self._impl.execute(statement, parameters)
        return _wrap_query_result(result)

    def prepare(self, query: str) -> PreparedStatement:
        return PreparedStatement(self._impl.prepare(query))

    def close(self) -> None:
        close = getattr(self._impl, "close", None)
        if callable(close):
            close()

    def __getattr__(self, item: str) -> Any:
        return getattr(self._impl, item)


def __getattr__(item: str) -> Any:
    """Expose backend symbols not yet wrapped in HippoCPP."""

    return getattr(_backend, item)


__all__ = [
    "Database",
    "Connection",
    "PreparedStatement",
    "QueryResult",
    "backend_module_name",
]
