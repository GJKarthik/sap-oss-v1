from typing import Iterable, Optional, Literal, NamedTuple
import re
import inspect

from pandera import Check  # type: ignore
import pandera as pa
from pandas.api import types as pdt

__all__ = [
    "extract_numeric_bounds",
    "is_numeric_dtype",
    "is_numeric_bounds_check",
    "is_explicitly_non_nullable_field",
    "is_pattern_check",
    "extract_pattern",
    "has_regex_constraint",
    "extract_regex_pattern",
    "is_comparison_check",
    "parse_comparison_check",
    "ComparisonCheckInfo",
    "extract_check_id",
]


def extract_numeric_bounds(checks: Iterable[Check]) -> tuple[float | None, float | None]:
    """Extract *(min_bound, max_bound)* from a collection of Pandera checks.

    If a bound is not present, its value is ``None``.
    """
    min_bound: float | None = None
    max_bound: float | None = None
    for check in checks:
        stats = getattr(check, "statistics", None)
        if not isinstance(stats, dict):
            continue
        if "min_value" in stats:
            min_bound = stats["min_value"]
        if "max_value" in stats:
            max_bound = stats["max_value"]
    return min_bound, max_bound


def is_numeric_dtype(dtype) -> bool:  # type: ignore[valid-type]
    """Return True if *dtype* is considered numeric."""
    return pdt.is_numeric_dtype(dtype)


def is_numeric_bounds_check(check: Check) -> bool:
    """Return True if the check represents numeric bounds (ge, le, gt, lt)."""
    stats = getattr(check, "statistics", None)
    if not isinstance(stats, dict):
        return False

    # Check for numeric bound statistics
    has_bounds = any(key in stats for key in ["min_value", "max_value"])
    return has_bounds


def is_explicitly_non_nullable_field(column_field: pa.Column) -> bool:
    """Return True if the field is explicitly set to non-nullable."""
    return column_field.nullable is False


def is_pattern_check(check: Check) -> bool:
    """Return True if the check represents a regex pattern check."""
    stats = getattr(check, "statistics", None)
    if not isinstance(stats, dict):
        return False

    # Check for pattern statistics
    return "pattern" in stats


def extract_pattern(check: Check) -> str | None:
    """Extract the regex pattern from a pattern check, or None if not a pattern check."""
    stats = getattr(check, "statistics", None)
    if not isinstance(stats, dict):
        return None

    return stats.get("pattern")


def has_regex_constraint(column_field: pa.Column) -> bool:
    """Return True if the field has a regex constraint."""
    regex = getattr(column_field, "regex", None)
    return regex is not None and regex is not False and isinstance(regex, str)


def extract_regex_pattern(column_field: pa.Column) -> str | None:
    """Extract the regex pattern from a column field, or None if no regex constraint."""
    regex = getattr(column_field, "regex", None)
    # Return None if regex is None, False, or not a string
    if regex is None or regex is False or not isinstance(regex, str):
        return None
    return regex


class ComparisonCheckInfo(NamedTuple):
    """Information extracted from a comparison check."""

    table1_column: str
    table2_column: str
    operator: Literal[">", "==", "<", ">=", "<=", "!="]
    table1_name: Optional[str] = None
    table2_name: Optional[str] = None


def _get_original_method_source(check: Check) -> Optional[str]:
    """
    Try to get the original method source from a pandera check by
    examining the closure to find the table class.

    Parameters
    ----------
    check : Check
        The pandera Check to extract the original source from

    Returns
    -------
    Optional[str]
        The source code of the original method, or None if not found
    """
    if not hasattr(check, "_check_fn") or not hasattr(check._check_fn, "__closure__"):
        return None

    if not check._check_fn.__closure__:
        return None

    # Look for a table class in the closure
    for cell in check._check_fn.__closure__:
        try:
            cell_contents = cell.cell_contents
            # Check if this looks like a table class (has the method we're looking for)
            if hasattr(cell_contents, check.name):
                original_method = getattr(cell_contents, check.name)
                return inspect.getsource(original_method)
        except (AttributeError, OSError, TypeError):
            continue

    return None


def is_comparison_check(check: Check) -> bool:
    """
    Determine if a pandera Check represents a column comparison that can be
    converted to our columns_comparison_validation function.

    This function analyzes the check function source code to detect
    column comparison patterns.

    Parameters
    ----------
    check : Check
        The pandera Check to analyze

    Returns
    -------
    bool
        True if the check can be parsed as a comparison check
    """
    if not hasattr(check, "_check_fn") or not callable(check._check_fn):
        return False

    try:
        source = inspect.getsource(check._check_fn)
    except (OSError, TypeError):
        # Can't get source code
        return False

    # If the source is a pandera adapter function, try to get the original method
    if "def _adapter" in source and hasattr(check, "name"):
        original_source = _get_original_method_source(check)
        if original_source:
            source = original_source

    # Look for comparison operators between DataFrame column accesses
    # Patterns like: df["col1"] > df["col2"], df.col1 == df.col2, etc.
    comparison_patterns = [
        r'df\["[^"]+"\]\s*([><=!]+)\s*df\["[^"]+"\]',  # df["col1"] > df["col2"]
        r"df\['[^']+'\]\s*([><=!]+)\s*df\['[^']+'\]",  # df['col1'] > df['col2']
        r"df\.[a-zA-Z_][a-zA-Z0-9_]*\s*([><=!]+)\s*df\.[a-zA-Z_][a-zA-Z0-9_]*",  # df.col1 > df.col2
    ]

    for pattern in comparison_patterns:
        if re.search(pattern, source):
            return True

    return False


def parse_comparison_check(check: Check) -> Optional[ComparisonCheckInfo]:
    """
    Parse a pandera Check to extract comparison information that can be used
    with columns_comparison_validation.

    Parameters
    ----------
    check : Check
        The pandera Check to parse

    Returns
    -------
    Optional[ComparisonCheckInfo]
        Parsed comparison information, or None if the check cannot be parsed
    """
    if not is_comparison_check(check):
        return None

    try:
        source = inspect.getsource(check._check_fn)
    except (OSError, TypeError):
        # Can't get source code
        return None

    # If the source is a pandera adapter function, try to get the original method
    if "def _adapter" in source and hasattr(check, "name"):
        original_source = _get_original_method_source(check)
        if original_source:
            source = original_source

    # Pattern to match df["col1"] operator df["col2"] or df.col1 operator df.col2
    patterns = [
        r'df\["([^"]+)"\]\s*([><=!]+)\s*df\["([^"]+)"\]',  # df["col1"] > df["col2"]
        r"df\['([^']+)'\]\s*([><=!]+)\s*df\['([^']+)'\]",  # df['col1'] > df['col2']
        r"df\.([a-zA-Z_][a-zA-Z0-9_]*)\s*([><=!]+)\s*df\.([a-zA-Z_][a-zA-Z0-9_]*)",  # df.col1 > df.col2
    ]

    for pattern in patterns:
        match = re.search(pattern, source)
        if match:
            col1, operator, col2 = match.groups()

            # Validate operator
            if operator in [">", "==", "<", ">=", "<=", "!="]:
                return ComparisonCheckInfo(
                    table1_column=col1,
                    table2_column=col2,
                    operator=operator,  # type: ignore
                    table1_name=None,  # Will be filled in by the caller
                    table2_name=None,  # Will be filled in by the caller
                )

    return None


def extract_check_id(check: Check, fallback_prefix: str = "check") -> str:
    """
    Extract a unique identifier from a pandera Check object.

    Uses check.name as it works consistently across all check types.

    Parameters
    ----------
    check : Check
        The pandera Check object to extract ID from
    fallback_prefix : str
        Prefix to use for generated fallback ID

    Returns
    -------
    str
        A unique identifier for the check
    """
    # Use check.name - it works consistently for both dataframe and field checks
    if hasattr(check, "name") and check.name:
        if isinstance(check.name, str) and check.name.strip():
            return check.name.strip()

    # Fallback: Generate a unique ID based on check object
    check_id = id(check)
    return f"{fallback_prefix}_{check_id}"
