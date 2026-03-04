"""Native Zig-backed HippoCPP Python runtime.

This module executes queries through the in-repo Zig mini engine process and
implements a Kuzu-compatible API surface used by the parity harness.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any


_HIPPO_DIR = Path(__file__).resolve().parents[2]
_ZIG_DIR = _HIPPO_DIR / "zig"
_ENGINE_SOURCE = Path(os.environ.get("HIPPOCPP_ZIG_ENGINE_SOURCE", str(_ZIG_DIR / "src/native/mini_engine.zig")))


class QueryResult:
    def __init__(self, columns: list[str], types: list[str], rows: list[list[Any]]):
        self._columns = columns
        self._types = types
        self._rows = rows
        self._cursor = 0

    def get_column_names(self) -> list[str]:
        return list(self._columns)

    def get_column_data_types(self) -> list[str]:
        return list(self._types)

    def has_next(self) -> bool:
        return self._cursor < len(self._rows)

    def get_next(self) -> list[Any]:
        if not self.has_next():
            raise StopIteration("No more rows")
        row = self._rows[self._cursor]
        self._cursor += 1
        return row

    def close(self) -> None:
        return None

    def __enter__(self) -> "QueryResult":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.close()
        return False


class PreparedStatement:
    def __init__(self, query: str):
        self.query = query


class _ZigEngineProcess:
    def __init__(self):
        zig_bin = os.environ.get("HIPPOCPP_ZIG_BIN", "zig")
        cmd = [zig_bin, "run", str(_ENGINE_SOURCE)]
        self._proc = subprocess.Popen(
            cmd,
            cwd=str(_ZIG_DIR),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def execute(self, query: str, parameters: dict[str, Any] | None = None) -> dict[str, Any]:
        if self._proc.poll() is not None:
            stderr = self._proc.stderr.read() if self._proc.stderr else ""
            raise RuntimeError(f"Zig engine process exited early. stderr={stderr}")

        payload = {
            "query": query,
            "parameters": parameters or {},
        }

        assert self._proc.stdin is not None
        assert self._proc.stdout is not None

        self._proc.stdin.write(json.dumps(payload) + "\n")
        self._proc.stdin.flush()

        line = self._proc.stdout.readline()
        if not line:
            stderr = self._proc.stderr.read() if self._proc.stderr else ""
            raise RuntimeError(f"No response from Zig engine. stderr={stderr}")

        response = json.loads(line)
        status = response.get("status")
        if status != "ok":
            raise RuntimeError(str(response.get("error", "Unknown engine error")))
        return response

    def close(self) -> None:
        if self._proc.poll() is not None:
            return

        try:
            if self._proc.stdin is not None:
                self._proc.stdin.write('{"action":"shutdown"}\n')
                self._proc.stdin.flush()
        except Exception:
            pass

        try:
            self._proc.wait(timeout=2)
        except Exception:
            self._proc.kill()


class Database:
    def __init__(self, database_path: str, *args: Any, **kwargs: Any):
        _ = args
        _ = kwargs
        self.database_path = database_path

    def close(self) -> None:
        return None


class Connection:
    def __init__(self, database: Database, *args: Any, **kwargs: Any):
        _ = args
        _ = kwargs
        _ = database
        self._engine = _ZigEngineProcess()

    def prepare(self, query: str) -> PreparedStatement:
        return PreparedStatement(query)

    def execute(self, query_or_statement: str | PreparedStatement, parameters: dict[str, Any] | None = None) -> QueryResult:
        if isinstance(query_or_statement, PreparedStatement):
            query = query_or_statement.query
        else:
            query = query_or_statement

        response = self._engine.execute(query, parameters)
        return QueryResult(
            columns=list(response.get("columns", [])),
            types=list(response.get("types", [])),
            rows=list(response.get("rows", [])),
        )

    def close(self) -> None:
        self._engine.close()
