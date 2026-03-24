# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
from pydantic import BaseModel, Field, field_validator
from typing import Callable, Any, Optional, Dict, List, Mapping, Tuple
from abc import ABC, abstractmethod
import inspect
import ast
import hashlib
import pandas as pd
import random
from functools import wraps
import pickle
import subprocess
import sys
import os
import atexit
import tempfile
import textwrap
import time
import warnings
from datetime import datetime, timezone

from loguru import logger

# Suppress multiprocessing resource tracker warnings
warnings.filterwarnings("ignore", message="resource_tracker: There appear to be")


# Force cleanup of multiprocessing resources on exit
def cleanup_multiprocessing():
    try:
        # Try to terminate any lingering multiprocessing resources
        import multiprocessing.resource_tracker

        multiprocessing.resource_tracker._resource_tracker._stop()
    except:
        pass


atexit.register(cleanup_multiprocessing)

DEFAULT_SANDBOX_TIMEOUT = 30
DEFAULT_SANDBOX_MEMORY_MB = 512
SANDBOX_ALLOWED_IMPORTS = {"pandas", "numpy", "datetime", "re", "json"}
SANDBOX_BLOCKED_CALLS = {
    "__import__",
    "compile",
    "eval",
    "exec",
    "globals",
    "input",
    "locals",
    "open",
    "vars",
}
SANDBOX_BLOCKED_NAMES = {
    "builtins",
    "ctypes",
    "importlib",
    "os",
    "pathlib",
    "resource",
    "shutil",
    "socket",
    "subprocess",
    "sys",
}
SANDBOX_BLOCKED_ATTRIBUTES = {
    "__bases__",
    "__builtins__",
    "__globals__",
    "__mro__",
    "__subclasses__",
    "check_call",
    "check_output",
    "execv",
    "execve",
    "fork",
    "popen",
    "remove",
    "replace",
    "rmdir",
    "run",
    "spawn",
    "system",
    "unlink",
}
SANDBOX_AUDIT_LOG: List[Dict[str, Any]] = []


class SandboxSecurityError(RuntimeError):
    """Raised when generated code violates sandbox policy."""


class SandboxExecutionError(RuntimeError):
    """Raised when sandbox execution fails unexpectedly."""


class SandboxPolicyValidator(ast.NodeVisitor):
    """Reject obviously unsafe imports, calls, and attribute access."""

    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            root = alias.name.split(".")[0]
            if root not in SANDBOX_ALLOWED_IMPORTS:
                raise SandboxSecurityError(f"Import '{alias.name}' is not allowed in sandboxed code")
        self.generic_visit(node)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        root = (node.module or "").split(".")[0]
        if root not in SANDBOX_ALLOWED_IMPORTS:
            raise SandboxSecurityError(f"Import from '{node.module}' is not allowed in sandboxed code")
        self.generic_visit(node)

    def visit_Call(self, node: ast.Call) -> None:
        if isinstance(node.func, ast.Name) and node.func.id in SANDBOX_BLOCKED_CALLS:
            raise SandboxSecurityError(f"Call to '{node.func.id}' is not allowed in sandboxed code")
        if isinstance(node.func, ast.Attribute) and node.func.attr in SANDBOX_BLOCKED_ATTRIBUTES:
            raise SandboxSecurityError(f"Attribute call '{node.func.attr}' is not allowed in sandboxed code")
        self.generic_visit(node)

    def visit_Name(self, node: ast.Name) -> None:
        if node.id in SANDBOX_BLOCKED_NAMES:
            raise SandboxSecurityError(f"Name '{node.id}' is not allowed in sandboxed code")
        self.generic_visit(node)

    def visit_Attribute(self, node: ast.Attribute) -> None:
        if node.attr in SANDBOX_BLOCKED_ATTRIBUTES:
            raise SandboxSecurityError(f"Attribute '{node.attr}' is not allowed in sandboxed code")
        self.generic_visit(node)


def _code_hash(func_code: str) -> str:
    return hashlib.sha256(func_code.encode("utf-8")).hexdigest()


def _record_sandbox_audit(
    *,
    func_name: str,
    func_code: str,
    outcome: str,
    timeout: float,
    memory_limit_mb: int,
    detail: Optional[str] = None,
) -> None:
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "function_name": func_name,
        "code_hash": _code_hash(func_code),
        "outcome": outcome,
        "timeout_seconds": timeout,
        "memory_limit_mb": memory_limit_mb,
    }
    if detail:
        entry["detail"] = detail[:500]
    SANDBOX_AUDIT_LOG.append(entry)

    log_message = f"Sandbox execution {outcome} for {func_name} ({entry['code_hash'][:12]})"
    if detail:
        log_message = f"{log_message}: {entry['detail']}"
    if outcome == "success":
        logger.info(log_message)
    else:
        logger.warning(log_message)


def get_sandbox_audit_log() -> List[Dict[str, Any]]:
    """Return sandbox audit entries for inspection/tests."""
    return list(SANDBOX_AUDIT_LOG)


def clear_sandbox_audit_log() -> None:
    """Clear in-memory sandbox audit entries."""
    SANDBOX_AUDIT_LOG.clear()


def _validate_generated_code(func_code: str, func_name: str) -> ast.Module:
    try:
        module_ast = ast.parse(func_code)
    except SyntaxError as exc:
        raise ValueError(f"Syntax error in generated code: {exc}") from exc

    SandboxPolicyValidator().visit(module_ast)

    function_names = {
        node.name for node in module_ast.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    if func_name not in function_names:
        raise ValueError(f"Function '{func_name}' not found in generated code")

    return module_ast


SANDBOX_RUNNER_SCRIPT = textwrap.dedent(
    """
    import builtins
    import json
    import os
    import pickle
    import socket
    import sys
    import traceback
    from datetime import datetime, timedelta
    from typing import Dict, List, Mapping, Optional, Tuple

    SANDBOX_DIR = os.path.abspath(sys.argv[1])

    import numpy as np
    import pandas as pd
    import random
    import re
    ALLOWED_IMPORTS = {"pandas", "numpy", "datetime", "re", "json"}
    ORIGINAL_IMPORT = builtins.__import__
    ORIGINAL_OPEN = builtins.open


    def _blocked(*_args, **_kwargs):
        raise PermissionError("Filesystem, process, or network access is blocked in the sandbox")


    def _safe_print(*args, **kwargs):
        kwargs.setdefault("file", sys.stderr)
        return builtins.print(*args, **kwargs)


    def _safe_open(file, *args, **kwargs):
        candidate = os.path.abspath(file)
        sandbox_prefix = SANDBOX_DIR + os.sep
        if candidate != SANDBOX_DIR and not candidate.startswith(sandbox_prefix):
            raise PermissionError(f"Sandboxed code may only access files in {SANDBOX_DIR}")
        return ORIGINAL_OPEN(file, *args, **kwargs)


    def _restricted_import(name, globals=None, locals=None, fromlist=(), level=0):
        root = name.split(".")[0]
        if root not in ALLOWED_IMPORTS:
            raise ImportError(f"Import '{name}' is blocked in sandboxed code")
        return ORIGINAL_IMPORT(name, globals, locals, fromlist, level)


    socket.socket = _blocked
    socket.create_connection = _blocked
    socket.getaddrinfo = _blocked

    for attr in ("read_csv", "read_excel", "read_json", "read_parquet", "read_pickle", "read_sql", "read_html", "read_xml"):
        if hasattr(pd, attr):
            setattr(pd, attr, _blocked)

    for attr in ("to_csv", "to_excel", "to_json", "to_parquet", "to_pickle", "to_sql", "to_html"):
        if hasattr(pd.DataFrame, attr):
            setattr(pd.DataFrame, attr, _blocked)
        if hasattr(pd.Series, attr):
            setattr(pd.Series, attr, _blocked)

    for attr in ("load", "loadtxt", "save", "savetxt", "savez", "savez_compressed"):
        if hasattr(np, attr):
            setattr(np, attr, _blocked)

    payload = pickle.loads(sys.stdin.buffer.read())
    namespace = {
        "__builtins__": {
            "__import__": _restricted_import,
            "abs": abs,
            "all": all,
            "any": any,
            "bool": bool,
            "bytearray": bytearray,
            "bytes": bytes,
            "dict": dict,
            "enumerate": enumerate,
            "Exception": Exception,
            "filter": filter,
            "float": float,
            "int": int,
            "isinstance": isinstance,
            "len": len,
            "list": list,
            "max": max,
            "min": min,
            "print": _safe_print,
            "range": range,
            "round": round,
            "set": set,
            "sorted": sorted,
            "str": str,
            "sum": sum,
            "tuple": tuple,
            "ValueError": ValueError,
            "zip": zip,
            "open": _safe_open,
        },
        "__name__": "__sandbox__",
        "pd": pd,
        "np": np,
        "random": random,
        "Dict": Dict,
        "List": List,
        "Mapping": Mapping,
        "Optional": Optional,
        "Tuple": Tuple,
        "datetime": datetime,
        "timedelta": timedelta,
        "re": re,
        "json": json,
    }

    try:
        exec(payload["code"], namespace, namespace)
        result = namespace[payload["func_name"]](*payload["args"])
        pickle.dump({"ok": True, "result": result}, sys.stdout.buffer)
        sys.stdout.buffer.flush()
    except Exception as exc:
        pickle.dump(
            {
                "ok": False,
                "error_type": type(exc).__name__,
                "error_message": str(exc),
                "traceback": traceback.format_exc(),
            },
            sys.stdout.buffer,
        )
        sys.stdout.buffer.flush()
    """
)


def _get_process_rss_bytes(process_id: int) -> Optional[int]:
    """Return current RSS usage for a process in bytes, if available."""
    try:
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(process_id)],
            capture_output=True,
            text=True,
            check=False,
            timeout=1,
        )
    except Exception:
        return None

    if result.returncode != 0:
        return None

    rss_kb = result.stdout.strip()
    if not rss_kb:
        return None

    try:
        return int(rss_kb) * 1024
    except ValueError:
        return None

# ===== Callable type aliases =====
ValidationFunction = Callable[
    [Mapping[str, pd.DataFrame]],  # Input: all tables as {table_name: DataFrame}
    Dict[str, pd.Series],  # Output: {"table.column": Series of violations}
]

CorruptionFunction = Callable[
    [
        Mapping[str, pd.DataFrame],  # Input: all tables
        random.Random,  # RNG for reproducibility
        float,  # Corruption percentage (0.0 to 1.0)
    ],
    Mapping[str, pd.DataFrame],  # Output: modified tables
]

QueryFunction = Callable[
    [Mapping[str, pd.DataFrame]],  # Input: all tables
    pd.DataFrame,  # Output: query result
]


class StructuredFunction(BaseModel, ABC):
    """
    IMPORTANT for LLMs:
    - Use `body_lines` ONLY.
    - Each entry is ONE Python line and MUST include the intended leading spaces.
      Typical base indent inside a function is 4 spaces; add multiples of 4 for nesting.
    """

    imports: List[str] = Field(default_factory=list, description="Each item is a full import line.")
    function_name: str = Field(description="snake_case name.")
    description: str = Field(description="What this function does.")
    parameters: str = Field(description="Parameters WITHOUT parentheses, e.g. 'tables: Mapping[str, pd.DataFrame]'.")
    body_lines: List[str] = Field(
        description="Ordered lines of the function body, with indentation included in each line."
    )
    return_statement: str = Field(description="Expression ONLY (no 'return').")
    sql: str = Field(default="", description="The corresponding SQL query for the logic")

    @field_validator("imports")
    @classmethod
    def _normalize_imports(cls, v: List[str]) -> List[str]:
        return [line.strip() for line in v if isinstance(line, str) and line.strip()]

    @field_validator("return_statement")
    @classmethod
    def _strip_return_prefix(cls, v: str) -> str:
        v = v.strip()
        return v[7:].strip() if v.startswith("return ") else ("" if v == "return" else v)

    def to_code(self) -> str:
        """
        Assemble exactly as given. If body_lines have no leading indentation,
        add a base indent of 4 spaces to each non-empty line so Python sees
        a valid block after the function header.
        """
        imports_block = "\n".join(self.imports) if self.imports else ""
        header = f"def {self.function_name}({self.parameters}):"

        # Join body lines
        lines = self.body_lines or []
        # Detect whether non-empty lines already start with whitespace
        non_empty = [ln for ln in lines if ln.strip() != ""]
        already_indented = all(ln.startswith((" ", "\t")) for ln in non_empty) if non_empty else False

        if not non_empty:
            body_text = "    pass"
        else:
            if already_indented:
                # Use as-is
                body_text = "\n".join(lines).rstrip()
            else:
                # Add base indent to each non-empty line
                body_text = "\n".join(("    " + ln if ln.strip() else ln) for ln in lines).rstrip()

        # Return line at base indent
        ret_line = f"    return {self.return_statement}".rstrip()

        parts = []
        if imports_block:
            parts += [imports_block, ""]
        parts += [header, body_text, ret_line]
        return "\n".join(parts)

    def to_function(self) -> Callable:
        code = self.to_code()
        try:
            _validate_generated_code(code, self.function_name)
        except Exception as e:
            raise ValueError(f"Generated code is not sandbox-safe: {e}\n\nCode:\n{code}") from e

        def sandboxed_callable(*args):
            result, error = execute_sandboxed_function(
                func_code=code,
                func_name=self.function_name,
                args=args,
                timeout=DEFAULT_SANDBOX_TIMEOUT,
                memory_limit_mb=DEFAULT_SANDBOX_MEMORY_MB,
            )
            if error:
                raise error
            return result

        return sandboxed_callable

    def _get_namespace(self) -> Dict[str, Any]:
        import numpy as np
        from typing import Dict as _Dict, List as _List, Mapping as _Mapping, Optional as _Optional, Tuple as _Tuple
        from datetime import datetime, timedelta

        return {
            "pd": pd,
            "np": np,
            "random": random,
            "Dict": _Dict,
            "List": _List,
            "Mapping": _Mapping,
            "Optional": _Optional,
            "Tuple": _Tuple,
            "datetime": datetime,
            "timedelta": timedelta,
        }

    def to_dict(self) -> Dict[str, Any]:
        """Convert the function to a JSON-serializable dictionary."""
        return {
            "function_name": self.function_name,
            "description": self.description,
            "scope": getattr(self, "scope", None),
            "sql": self.sql if self.sql else None,
            "parameters": self.parameters,
            "imports": self.imports,
            "body_lines": self.body_lines,
            "return_statement": self.return_statement,
        }

    @abstractmethod
    def get_expected_signature(self) -> str: ...
    @abstractmethod
    def _validate_signature(self, func: Callable) -> bool: ...


class CheckLogic(StructuredFunction):
    """Structured model for validation function generation."""

    scope: List[Tuple[str, str]] = Field(
        description="List of (table_name, column_name) tuples this validation operates on."
    )

    def get_expected_signature(self) -> str:
        return "def validation_function(tables: Mapping[str, pd.DataFrame]) -> Dict[str, pd.Series]"

    def _validate_signature(self, func: Callable) -> bool:
        sig = inspect.signature(func)
        return len(sig.parameters) == 1

    def to_validation_function(self) -> ValidationFunction:
        func = self.to_function()

        def wrapped(tables: Mapping[str, pd.DataFrame]) -> Dict[str, pd.Series]:
            try:
                result = func(tables)
                if not isinstance(result, dict):
                    return {}
                for k, v in list(result.items()):
                    if not isinstance(v, pd.Series):
                        result[k] = pd.Series(v)
                return result
            except Exception as e:
                print(f"Validation function error in {self.function_name}: {e}")
                return {}

        return wrapped


class CorruptionLogic(StructuredFunction):
    """Structured model for corruption function generation."""

    scope: List[Tuple[str, str]] = Field(description="List of (table_name, column_name) tuples this corruptor affects.")
    corruption_percentage: float = Field(
        default=0.1,
        ge=0.0,
        le=1.0,
        description="Default corruption percentage to apply when per-column value is missing.",
    )

    def get_expected_signature(self) -> str:
        return (
            "def corruption_function("
            "table_data: Mapping[str, pd.DataFrame], "
            "rand: random.Random, "
            "percentage: float"
            ") -> Mapping[str, pd.DataFrame]"
        )

    def _validate_signature(self, func: Callable) -> bool:
        sig = inspect.signature(func)
        return len(sig.parameters) == 3

    def to_corruption_function(self) -> CorruptionFunction:
        func = self.to_function()

        def wrapped(
            table_data: Mapping[str, pd.DataFrame], rand: random.Random, percentage: float
        ) -> Mapping[str, pd.DataFrame]:
            try:
                table_copy = {k: v.copy() for k, v in table_data.items()}
                result = func(table_copy, rand, percentage)
                return result if isinstance(result, dict) else table_data
            except Exception as e:
                print(f"Corruption function error in {self.function_name}: {e}")
                return table_data

        return wrapped


class QueryLogic(StructuredFunction):
    """Structured model for query function generation."""

    expected_columns: Optional[List[str]] = Field(
        default=None, description="Optional: list of expected columns in the returned DataFrame."
    )

    def get_expected_signature(self) -> str:
        return "def query_function(tables: Mapping[str, pd.DataFrame]) -> pd.DataFrame"

    def _validate_signature(self, func: Callable) -> bool:
        sig = inspect.signature(func)
        return len(sig.parameters) == 1

    def to_query_function(self) -> QueryFunction:
        func = self.to_function()

        def wrapped(tables: Mapping[str, pd.DataFrame]) -> pd.DataFrame:
            try:
                result = func(tables)
                if not isinstance(result, pd.DataFrame):
                    return pd.DataFrame()
                if self.expected_columns:
                    missing = set(self.expected_columns) - set(result.columns)
                    if missing:
                        print(f"Warning: Missing expected columns: {missing}")
                return result
            except Exception as e:
                print(f"Query function error in {self.function_name}: {e}")
                return pd.DataFrame()

        return wrapped


# Batches
class CheckBatch(BaseModel):
    """Generate new validation checks to improve coverage.

    IMPORTANT body_lines FORMAT GUIDELINES:
    - Write each statement as ONE line in the list
    - INCLUDE proper indentation (spaces) in each line string based on nesting level
    - Base indent inside function: 4 spaces
    - Add 4 more spaces for each nested level (if/for/while blocks)
    - Empty lines should be empty strings

    Example body_lines format:
    [
        "violations = {}",
        "customer_df = tables.get('KNA1', pd.DataFrame())",
        "if not customer_df.empty:",
        "    if 'KUNNR' in customer_df.columns:",
        "        duplicates = customer_df['KUNNR'].duplicated()",
        "        if duplicates.any():",
        "            invalid_series = pd.Series(customer_df.index[duplicates].tolist())",
        "            invalid_series.name = 'KUNNR'",
        "            violations['KNA1'] = invalid_series"
    ]

    CRITICAL - Preserving Row Indices:
    - ALWAYS preserve original row indices in returned pd.Series
    - When using merge/join: save original index first with reset_index(names='original_index')
    - Return saved original indices, NOT merged DataFrame indices
    - The returned indices must point to exact rows in original input table
    """

    checks: List[CheckLogic] = Field(description="Multiple structured validation check functions.")


class CorruptorBatch(BaseModel):
    """Generate corruption strategies for corrupting the table data in a certain way.

    IMPORTANT body_lines FORMAT GUIDELINES:
    - Write each statement as ONE line in the list
    - INCLUDE proper indentation (spaces) in each line string based on nesting level
    - Base indent inside function: 4 spaces
    - Add 4 more spaces for each nested level (if/for/while blocks)
    - Empty lines should be empty strings

    Example body_lines format:
    [
        "modified_tables = {}",
        "if 'KNA1' in table_data:",
        "    df = table_data['KNA1'].copy()",
        "    column = 'KUNNR'",
        "    if column in df.columns:",
        "        num_corrupt = int(len(df) * percentage)",
        "        if num_corrupt > 0:",
        "            corrupt_indices = rand.sample(range(len(df)), num_corrupt)",
        "            df.loc[corrupt_indices, column] = ''",
        "            modified_tables['KNA1'] = df",
        "if not modified_tables:",
        "    return {}"
    ]

    CRITICAL Guidelines:
    - ALWAYS use provided 'rand' (random.Random) for reproducibility
    - Start with empty dict: modified_tables = {}
    - Only copy and include tables that are actually corrupted
    - Return empty dict if no corruption occurs
    - Use 'percentage' parameter to control corruption amount (0.0 to 1.0)
    """

    corruptors: List[CorruptionLogic] = Field(description="Multiple structured corruption functions.")


# ===== Sandboxed Execution Utilities =====


def sandboxed_execute(timeout: Optional[float] = 30):
    """
    Decorator to execute a function in a sandboxed subprocess.

    Parameters
    ----------
    timeout : Optional[float]
        Timeout in seconds (default: 30)

    Usage
    -----
    @sandboxed_execute(timeout=10)
    def my_function(data):
        return process(data)
    """

    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            # For now, we'll execute directly with proper error handling
            # Full subprocess isolation can be enabled if needed
            try:
                return func(*args, **kwargs)
            except Exception as e:
                raise e

        return wrapper

    return decorator


def execute_sandboxed_function(
    func_code: str,
    func_name: str,
    args: tuple,
    namespace: Optional[Dict] = None,
    timeout: float = DEFAULT_SANDBOX_TIMEOUT,
    memory_limit_mb: int = DEFAULT_SANDBOX_MEMORY_MB,
    use_subprocess: bool = True,
) -> Tuple[Any, Optional[Exception]]:
    """
    Execute dynamically generated code in a sandboxed subprocess environment.

    SECURITY NOTE: All LLM-generated code MUST be executed via subprocess isolation.
    The use_subprocess parameter is retained for API compatibility but in-process
    execution is permanently disabled to prevent arbitrary code execution attacks.

    Parameters
    ----------
    func_code : str
        The function code to execute
    func_name : str
        Name of the function to call
    args : tuple
        Arguments to pass to the function
    namespace : Optional[Dict]
        Namespace for execution (ignored - subprocess uses fixed safe namespace)
    timeout : float
        Timeout in seconds (default: 30)
    memory_limit_mb : int
        Maximum memory allowed in MB (default: 512)
    use_subprocess : bool
        DEPRECATED - Always True. In-process execution is permanently disabled.
        This parameter is retained only for API compatibility.

    Returns
    -------
    Tuple[Any, Optional[Exception]]
        Result and any exception that occurred
    """
    # SECURITY: Always enforce subprocess isolation regardless of parameter
    # In-process exec() of LLM-generated code is a critical security vulnerability
    if not use_subprocess:
        logger.warning(
            "use_subprocess=False was requested but is permanently disabled for security. "
            "All generated code executes in subprocess isolation."
        )

    try:
        _validate_generated_code(func_code, func_name)
    except Exception as exc:
        _record_sandbox_audit(
            func_name=func_name,
            func_code=func_code,
            outcome="blocked",
            timeout=timeout,
            memory_limit_mb=memory_limit_mb,
            detail=str(exc),
        )
        return None, exc if isinstance(exc, Exception) else ValueError(str(exc))

    _ = namespace  # Retained for backwards-compatible call sites; sandbox uses a fixed safe namespace.

    payload = pickle.dumps(
        {"code": func_code, "func_name": func_name, "args": args},
        protocol=pickle.HIGHEST_PROTOCOL,
    )
    memory_limit_bytes = memory_limit_mb * 1024 * 1024

    with tempfile.TemporaryDirectory(prefix="dcc-sandbox-") as sandbox_dir:
        env = os.environ.copy()
        env.update(
            {
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONIOENCODING": "utf-8",
            }
        )

        try:
            process = subprocess.Popen(
                [sys.executable, "-c", SANDBOX_RUNNER_SCRIPT, sandbox_dir],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=sandbox_dir,
                env=env,
            )
        except Exception as exc:
            error = SandboxExecutionError(f"Failed to start sandbox process: {exc}")
            _record_sandbox_audit(
                func_name=func_name,
                func_code=func_code,
                outcome="failed",
                timeout=timeout,
                memory_limit_mb=memory_limit_mb,
                detail=str(error),
            )
            return None, error

        assert process.stdin is not None
        process.stdin.write(payload)
        process.stdin.close()

        start_time = time.monotonic()
        while process.poll() is None:
            if time.monotonic() - start_time > timeout:
                process.kill()
                process.communicate()
                error = TimeoutError(f"Function execution timed out after {timeout} seconds")
                _record_sandbox_audit(
                    func_name=func_name,
                    func_code=func_code,
                    outcome="timeout",
                    timeout=timeout,
                    memory_limit_mb=memory_limit_mb,
                    detail=str(error),
                )
                return None, error

            rss_bytes = _get_process_rss_bytes(process.pid)
            if rss_bytes is not None and rss_bytes > memory_limit_bytes:
                process.kill()
                process.communicate()
                error = MemoryError(f"Function execution exceeded {memory_limit_mb} MB memory limit")
                _record_sandbox_audit(
                    func_name=func_name,
                    func_code=func_code,
                    outcome="memory_limit_exceeded",
                    timeout=timeout,
                    memory_limit_mb=memory_limit_mb,
                    detail=str(error),
                )
                return None, error

            time.sleep(0.05)

        stdout, stderr = process.communicate()
        stderr_text = stderr.decode("utf-8", errors="replace").strip()

        if process.returncode != 0:
            detail = stderr_text or f"sandbox process exited with code {process.returncode}"
            error = SandboxExecutionError(detail)
            _record_sandbox_audit(
                func_name=func_name,
                func_code=func_code,
                outcome="failed",
                timeout=timeout,
                memory_limit_mb=memory_limit_mb,
                detail=detail,
            )
            return None, error

        try:
            response = pickle.loads(stdout)
        except Exception as exc:
            detail = stderr_text or f"Invalid sandbox response: {exc}"
            error = SandboxExecutionError(detail)
            _record_sandbox_audit(
                func_name=func_name,
                func_code=func_code,
                outcome="failed",
                timeout=timeout,
                memory_limit_mb=memory_limit_mb,
                detail=detail,
            )
            return None, error

        if response.get("ok"):
            _record_sandbox_audit(
                func_name=func_name,
                func_code=func_code,
                outcome="success",
                timeout=timeout,
                memory_limit_mb=memory_limit_mb,
                detail=stderr_text or None,
            )
            return response.get("result"), None

        detail = response.get("error_message") or response.get("traceback") or stderr_text or "Sandbox execution failed"
        error = Exception(f"{response.get('error_type', 'SandboxError')}: {detail}")
        _record_sandbox_audit(
            func_name=func_name,
            func_code=func_code,
            outcome="error",
            timeout=timeout,
            memory_limit_mb=memory_limit_mb,
            detail=detail,
        )
        return None, error
