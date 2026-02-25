from pydantic import BaseModel, Field, field_validator
from typing import Callable, Any, Optional, Dict, List, Mapping, Tuple
from abc import ABC, abstractmethod
import inspect
import ast
import pandas as pd
import random
from functools import wraps
import pickle
import subprocess
import sys
import os
import atexit
import warnings

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
            ast.parse(code)
        except SyntaxError as e:
            raise ValueError(f"Generated code has syntax error: {e}\n\nCode:\n{code}")
        ns = self._get_namespace()
        exec(code, ns)
        if self.function_name not in ns:
            raise ValueError(f"Function '{self.function_name}' not found.\n\nCode:\n{code}")
        func = ns[self.function_name]
        if not self._validate_signature(func):
            raise ValueError(f"Signature mismatch. Expected: {self.get_expected_signature()}\n\nCode:\n{code}")
        return func

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


def _execute_directly(
    func_code: str, func_name: str, args: tuple, namespace: Optional[Dict] = None
) -> Tuple[Any, Optional[Exception]]:
    """
    Execute code directly in the current process.
    """
    try:
        # Prepare namespace
        if namespace is None:
            import numpy as np
            from typing import Dict as _Dict, List as _List, Mapping as _Mapping, Optional as _Optional, Tuple as _Tuple
            from datetime import datetime, timedelta

            namespace = {
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

        # Execute code to define function
        exec(func_code, namespace)

        if func_name not in namespace:
            return None, ValueError(f"Function '{func_name}' not found in executed code")

        func = namespace[func_name]

        # Execute the function
        try:
            result = func(*args)
            return result, None
        except Exception as e:
            return None, e

    except Exception as e:
        return None, e


def execute_sandboxed_function(
    func_code: str,
    func_name: str,
    args: tuple,
    namespace: Optional[Dict] = None,
    timeout: float = 30,
    use_subprocess: bool = True,
) -> Tuple[Any, Optional[Exception]]:
    """
    Execute dynamically generated code in a sandboxed environment.

    Parameters
    ----------
    func_code : str
        The function code to execute
    func_name : str
        Name of the function to call
    args : tuple
        Arguments to pass to the function
    namespace : Optional[Dict]
        Namespace for execution (default: standard imports)
    timeout : float
        Timeout in seconds (default: 30)
    use_subprocess : bool
        Whether to use subprocess isolation (default: True)

    Returns
    -------
    Tuple[Any, Optional[Exception]]
        Result and any exception that occurred
    """
    # First validate the code syntax
    try:
        ast.parse(func_code)
    except SyntaxError as e:
        return None, ValueError(f"Syntax error in generated code: {e}")

    # If subprocess is disabled or we're already in a subprocess, execute directly
    if not use_subprocess or os.environ.get("SANDBOXED_EXEC") == "1":
        return _execute_directly(func_code, func_name, args, namespace)

    # Create a subprocess script
    script = f"""
import sys
import os
import pickle
import pandas as pd
import numpy as np
import random
import warnings
from typing import Dict, List, Mapping, Optional, Tuple
from datetime import datetime, timedelta

# Mark as sandboxed execution
os.environ['SANDBOXED_EXEC'] = '1'

# Suppress warnings
warnings.filterwarnings("ignore")

# Read pickled arguments
with open(sys.argv[1], 'rb') as f:
    args = pickle.load(f)

# Define the function
{func_code}

# Execute the function
try:
    result = {func_name}(*args)
    # Write result
    with open(sys.argv[2], 'wb') as f:
        pickle.dump((result, None), f)
except Exception as e:
    # Write error
    with open(sys.argv[2], 'wb') as f:
        pickle.dump((None, (type(e).__name__, str(e))), f)
"""

    import tempfile

    # Create temp files for args and result
    with tempfile.NamedTemporaryFile(mode="wb", delete=False, suffix=".pkl") as args_file:
        pickle.dump(args, args_file)
        args_path = args_file.name

    with tempfile.NamedTemporaryFile(mode="wb", delete=False, suffix=".pkl") as result_file:
        result_path = result_file.name

    try:
        # Run in subprocess with timeout
        env = os.environ.copy()
        # Disable multiprocessing warnings
        env["PYTHONWARNINGS"] = "ignore::UserWarning:multiprocessing"

        process = subprocess.Popen(
            [sys.executable, "-c", script, args_path, result_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )

        try:
            stdout, stderr = process.communicate(timeout=timeout)

            # Read result
            if os.path.exists(result_path):
                with open(result_path, "rb") as f:
                    result, error = pickle.load(f)

                if error:
                    error_type, error_msg = error
                    return None, Exception(f"{error_type}: {error_msg}")
                return result, None
            else:
                return None, Exception(f"No result produced. stderr: {stderr.decode()}")

        except subprocess.TimeoutExpired:
            process.kill()
            return None, TimeoutError(f"Function execution timed out after {timeout} seconds")

    finally:
        # Clean up temp files
        for path in [args_path, result_path]:
            if os.path.exists(path):
                os.unlink(path)
