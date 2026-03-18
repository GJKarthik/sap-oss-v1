# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
from typing import Dict, Type, Mapping, Optional, List, Set, Literal, Union, Any, Tuple
import pandas as pd
from definition.base.table import Table
from pandera.errors import SchemaErrors
import os
from pathlib import Path
import json
from definition.base.corruption import corruption_from_pandera
from definition.base.executable_code import CheckLogic, CorruptionLogic, CheckBatch, CorruptorBatch, QueryLogic
from definition.llm.models import TableSchema
from definition.impl.check.rule_based_logic import (
    create_foreign_key_check,
    create_foreign_key_corruption,
    get_corruptors_from_pandera,
    create_pandera_check_placeholder,
)
import random
from loguru import logger
from pydantic import BaseModel, Field
from dataclasses import dataclass, field
from functools import wraps


class ExecutionTimeoutError(Exception):
    """Raised when a database operation exceeds the maximum execution time."""

    pass


def with_timeout(method):
    """Decorator to apply timeout to database methods.

    Uses a thread-safe timeout mechanism that works in both main and non-main threads.
    This allows it to work properly in Gradio and other threaded environments.
    """

    @wraps(method)
    def wrapper(self, *args, **kwargs):
        if not hasattr(self, "max_execution_time"):
            # No timeout configured, run normally
            return method(self, *args, **kwargs)

        timeout_seconds = self.max_execution_time

        import concurrent.futures

        # Use ThreadPoolExecutor for thread-safe timeout
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(method, self, *args, **kwargs)

            try:
                result = future.result(timeout=timeout_seconds)
                return result
            except concurrent.futures.TimeoutError:
                # Try to cancel the future (though it may not stop the running thread)
                future.cancel()
                raise ExecutionTimeoutError(f"{method.__name__} exceeded {timeout_seconds}s timeout")
            except Exception as e:
                # Re-raise any exception from the method itself
                raise e

    return wrapper


def with_token_limit(method):
    """Decorator to limit DataFrame output based on token count using JSON serialization."""

    @wraps(method)
    def wrapper(self, *args, **kwargs):
        result = method(self, *args, **kwargs)

        if not isinstance(result, pd.DataFrame) or not hasattr(self, "max_output_tokens"):
            return result

        max_tokens = self.max_output_tokens
        if max_tokens is None or max_tokens <= 0:
            return result

        total_rows = len(result)
        if total_rows == 0:
            return result

        # Use JSON serialization for more accurate token counting
        import json

        total_chars = 0
        rows_to_keep = []

        for idx in range(total_rows):
            # Convert row to dict and serialize to JSON
            row_dict = result.iloc[idx].to_dict()
            # Convert NaN and other special values to None for JSON serialization
            row_dict = {k: (None if pd.isna(v) else v) for k, v in row_dict.items()}
            row_json = json.dumps(row_dict, default=str)  # Use default=str for non-serializable types
            row_chars = len(row_json)

            # Check if adding this row would exceed the limit
            if total_chars + row_chars + 1 <= max_tokens:  # +1 for newline in JSONL
                rows_to_keep.append(idx)
                total_chars += row_chars + 1
            else:
                # We've hit the limit
                break

        # If no rows fit, keep at least one row
        if not rows_to_keep:
            rows_to_keep = [0]

        truncated_df = result.iloc[rows_to_keep]

        if len(truncated_df) < total_rows:
            logger.debug(
                f"DataFrame truncated from {total_rows} to {len(truncated_df)} rows due to token limit ({max_tokens} chars)"
            )

        return truncated_df

    return wrapper


class TableColumnSchema(BaseModel):
    """Schema information for a table column."""

    table_name: str = Field(description="Name of the table")
    column_name: str = Field(description="Name of the column")
    data_type: str = Field(description="Data type of the column")
    is_primary_key: bool = Field(default=False, description="Whether this column is a primary key")
    is_foreign_key: bool = Field(default=False, description="Whether this column is a foreign key")
    foreign_key_reference: Optional[Tuple[str, str]] = Field(
        default=None, description="If foreign key, tuple of (parent_table, parent_column)"
    )
    is_nullable: bool = Field(default=True, description="Whether this column allows null values")
    constraints: List[str] = Field(default_factory=list, description="List of constraints on this column")
    description: Optional[str] = Field(default=None, description="Description of the column")


class CheckResultSummary(BaseModel):
    """Summary of check results for structured output."""

    total_violations: int = Field(description="Total number of violations found")
    checks_with_violations: List[str] = Field(default_factory=list, description="Checks that found violations")
    checks_without_violations: List[str] = Field(default_factory=list, description="Checks that found no violations")
    failed_checks: List[str] = Field(default_factory=list, description="Checks that failed with errors")
    violation_profiles: Dict[str, Any] = Field(default_factory=dict, description="Violation profiles by check")


@dataclass
class CheckResultStore:
    """Manages check results and their exceptions with synchronized lifecycle."""

    results: Dict[str, Union[pd.DataFrame, Exception]] = field(default_factory=dict)

    def set_result(self, check_name: str, result: Union[pd.DataFrame, Exception]) -> None:
        """Set check result (DataFrame or Exception)."""
        self.results[check_name] = result

    def get_result(self, check_name: str) -> Optional[Union[pd.DataFrame, Exception]]:
        """Get check result (DataFrame or Exception)."""
        return self.results.get(check_name)

    def has_check(self, check_name: str) -> bool:
        """Check if a result exists for the given check name."""
        return check_name in self.results

    def remove_check(self, check_name: str) -> None:
        """Remove check result."""
        self.results.pop(check_name, None)

    def clear(self) -> None:
        """Clear all results."""
        self.results.clear()

    def get_all_results(self) -> Dict[str, Union[pd.DataFrame, Exception]]:
        """Get all check results."""
        return self.results.copy()

    def concat_results(self) -> pd.DataFrame:
        """Concatenate all successful check results into a single DataFrame."""
        from definition.base.corruption import COLUMNS

        non_empty_dfs = [v for v in self.results.values() if isinstance(v, pd.DataFrame) and not v.empty]
        return pd.concat(non_empty_dfs, ignore_index=True) if non_empty_dfs else pd.DataFrame(columns=COLUMNS)

    @property
    def succeeded_checks(self) -> Set[str]:
        """Get checks that executed successfully (returned DataFrame)."""
        return {k for k, v in self.results.items() if isinstance(v, pd.DataFrame)}

    @property
    def failed_checks(self) -> Set[str]:
        """Get checks that failed with exceptions."""
        return {k for k, v in self.results.items() if isinstance(v, Exception)}

    @property
    def checks_without_violations(self) -> Set[str]:
        """Get checks that ran successfully but found no violations."""
        return {k for k, v in self.results.items() if isinstance(v, pd.DataFrame) and v.empty}

    @property
    def checks_with_violations(self) -> Set[str]:
        """Get checks that run successfully and found violations."""
        return {k for k, v in self.results.items() if isinstance(v, pd.DataFrame) and not v.empty}

    def summary(
        self,
        profile_violations: bool = True,
        max_columns: int = 10,
        sample_size: int = 5,
        only_generated_checks: bool = True,
        rule_based_check_names: Optional[Set[str]] = None,
    ) -> "CheckResultSummary":
        """
        Generate a summary of all check results.

        Returns:
        --------
        CheckResultSummary
            Structured summary with check results, violation profiles, and exceptions
        """
        from definition.base.util_profiler import profile_table_data

        rule_based = rule_based_check_names or set()

        # Filter results
        filtered_results = (
            {k: v for k, v in self.results.items() if k not in rule_based} if only_generated_checks else self.results
        )

        # Get checks by status
        checks_with_violations = [k for k, v in filtered_results.items() if isinstance(v, pd.DataFrame) and not v.empty]
        checks_without_violations = [k for k, v in filtered_results.items() if isinstance(v, pd.DataFrame) and v.empty]
        failed_checks = [k for k, v in filtered_results.items() if isinstance(v, Exception)]

        # Calculate total violations
        total_violations = sum(len(v) for v in filtered_results.values() if isinstance(v, pd.DataFrame) and not v.empty)

        # Generate violation profiles
        violation_profiles = (
            {
                check_name: profile_table_data(df, max_columns=max_columns, sample_size=sample_size)
                for check_name, df in (
                    (k, v)
                    for k, v in filtered_results.items()
                    if k in checks_with_violations and isinstance(v, pd.DataFrame)
                )
            }
            if profile_violations
            else {}
        )

        return CheckResultSummary(
            total_violations=total_violations,
            checks_with_violations=checks_with_violations,
            checks_without_violations=checks_without_violations,
            failed_checks=failed_checks,
            violation_profiles=violation_profiles,
        )


# Function call models for tool-like capabilities
class RemoveChecks(BaseModel):
    """Remove unnecessary checks from the database."""

    check_names: List[str] = Field(
        description="List of check names to remove. Only non-rule-based checks can be removed."
    )


class ValidateDatabase(BaseModel):
    """Validate the entire database and return validation violations."""

    type: Literal["validate"] = "validate"


class Corrupt(BaseModel):
    """Corrupt database tables using a corruption strategy."""

    type: Literal["corrupt"] = "corrupt"
    corruptor_name: str = Field(description="Name of the corruption logic function to apply")
    percentage: float = Field(description="Corruption percentage (0.0 to 1.0)", default=0.1)
    rand_seed: Optional[int] = Field(
        default=None, description="Random seed for reproducible corruption. If None, uses default seed 42"
    )


class ListTableSchemas(BaseModel):
    """List all tables and get their schema information."""

    type: Literal["list_table_schemas"] = "list_table_schemas"


class GetCheck(BaseModel):
    """Get a specific check by name."""

    type: Literal["get_check"] = "get_check"
    check_name: str = Field(description="Name of the check to retrieve")


class GetTableColumnSchema(BaseModel):
    """Get schema information for a specific table column."""

    type: Literal["get_table_column_schema"] = "get_table_column_schema"
    table_name: str = Field(description="Name of the table")
    column_name: str = Field(description="Name of the column")


class GetTableData(BaseModel):
    """Get data and profile for a specific table.

    Use GetTableData to get the actual table's data, due to the size limit, limited number of rows will be retrieved
    """

    type: Literal["get_table_data"] = "get_table_data"
    table_name: str = Field(description="Name of the table to retrieve data from")


class ProfileTableData(BaseModel):
    """Generate comprehensive statistics and profile for a table's data.

    Use ProfileTableData to understand data samples before writing checks.
    This helps you see actual data patterns and distributions. Detailed statistics about a table including:
    - Data types and distributions for each column
    - Missing value counts
    - Unique value counts
    - Sample values for each column
    This method is used to generate statistics from the table data without
    retrieving all the raw data, which is especially useful for large tables.
    """

    type: Literal["profile_table_data"] = "profile_table_data"
    table_name: str = Field(description="Name of the table to profile")


class ProfileTableColumnData(BaseModel):
    """Generate detailed statistics and profile for a single column.

    Use ProfileTableColumnData to focus on a specific column's characteristics.
    This provides deeper insights than ProfileTableData for individual columns:
    - Detailed distribution statistics (mean, std, percentiles for numeric)
    - Value counts and frequencies (for categorical/low cardinality)
    - Missing value patterns
    - Sample values
    Useful when you need to understand a specific column in detail without
    profiling the entire table.
    """

    type: Literal["profile_table_column_data"] = "profile_table_column_data"
    table_name: str = Field(description="Name of the table containing the column")
    column_name: str = Field(description="Name of the column to profile")


class ListChecks(BaseModel):
    """List all validation checks."""

    type: Literal["list_checks"] = "list_checks"


class ListCorruptors(BaseModel):
    """List all corruption strategies."""

    type: Literal["list_corruptors"] = "list_corruptors"


class GetValidationResult(BaseModel):
    """Get validation result for a specific check."""

    type: Literal["get_validation_result"] = "get_validation_result"
    check_name: str = Field(description="Name of the check whose results to retrieve")


class Validate(BaseModel):
    """Run validation on the database to check all rule-based and agent-generated checks.

    Use Validate frequently to test your hypotheses.
    Run this after generating new checks to see if they find violations.
    """

    type: Literal["validate"] = "validate"


class ExportValidationResult(BaseModel):
    """Export validation results by concatenating all violation DataFrames into a CSV file."""

    type: Literal["export_validation_result"] = "export_validation_result"
    directory: str = Field(description="Directory path to save the concatenated violations CSV file")
    override_existing_files: bool = Field(default=True, description="Whether to override existing files if they exist")


class Evaluate(BaseModel):
    """Evaluate detection performance by comparing current check results against ground truth."""

    type: Literal["evaluate"] = "evaluate"
    ground_truth_file: str = Field(
        description="Path to ground truth violations CSV file (in corruption DataFrame format)"
    )


# V3 Agent specific models
class GetTableSchema(BaseModel):
    """Get detailed schema information for a specific table."""

    type: Literal["get_table_schema"] = "get_table_schema"
    table_name: str = Field(description="Name of the table to get schema for")


class ListValidationResults(BaseModel):
    """List all validation results with violation counts."""

    type: Literal["list_validation_results"] = "list_validation_results"
    include_empty: bool = Field(default=False, description="Include checks with no violations")


class ExecuteQuery(BaseModel):
    """Execute a custom query on the database tables to analyze data patterns.

    Use ExecuteQuery to:
    - Find distribution of values in key columns
    - Identify orphaned records or broken relationships
    - Detect unusual patterns or outliers
    - Validate business rules across multiple tables
    """

    type: Literal["execute_query"] = "execute_query"
    query: QueryLogic = Field(
        description="""Execute a custom query function to analyze data patterns across tables.

    Purpose: Allows flexible data exploration and analysis for informed check generation.
    
    IMPORTANT query FORMAT GUIDELINES:
    - Generate a QueryLogic function that returns a pandas DataFrame
    - Function should analyze specific patterns, relationships, or anomalies
    - Can access multiple tables via the 'tables' dictionary parameter
    - Return meaningful results that inform validation strategy
    
    Example query structures:
    - Count unique values in specific columns
    - Find mismatched foreign key relationships
    - Calculate statistics across related tables
    - Identify suspicious data patterns
    - Analyze value distributions
    
    The query should return a DataFrame with clear column names that describe
    the analysis results. This helps inform what checks to generate."""
    )


class AddChecks(BaseModel):
    """Add multiple checks to the database."""

    type: Literal["add_checks"] = "add_checks"
    checks: CheckBatch = Field(
        description="""Generate new validation checks to improve coverage.

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
    - The returned indices must point to exact rows in original input table"""
    )


class GenerationFinished(BaseModel):
    """Signal that check generation is complete."""

    type: Literal["generation_finished"] = "generation_finished"


DatabaseFunctionCall = Union[
    ValidateDatabase,
    Corrupt,
    ListChecks,
    ListCorruptors,
    GetValidationResult,
    ExportValidationResult,
    Evaluate,
    ListTableSchemas,
    GetCheck,
    GetTableColumnSchema,
    GetTableData,
    GetTableSchema,
    ListValidationResults,
    AddChecks,
    ExecuteQuery,
]


class MultipleDatabaseCalls(BaseModel):
    calls: List[DatabaseFunctionCall] = Field(description="List of database function calls to execute")


# Agent tool call models
CheckAgentToolCall = Union[
    ListChecks,
    GetValidationResult,
    ListTableSchemas,
    GetTableData,
    ProfileTableData,
    ProfileTableColumnData,
    AddChecks,  # Use AddChecks instead of CheckBatch for consistency
    Validate,
    # RemoveChecks,
    GetCheck,
    GetTableColumnSchema,
    ExecuteQuery,
    GenerationFinished,  # For V2 agent termination
]


class CheckAgentToolResponse(BaseModel):
    """Wrapper for agent tool responses to handle Union types properly."""

    tool: CheckAgentToolCall = Field(description="The tool call from the agent")


# V3 Agent tool call models
CheckAgentV3ToolCall = Union[
    ListTableSchemas,
    GetTableSchema,
    GetTableColumnSchema,
    GetTableData,
    ListChecks,
    GetCheck,
    GetValidationResult,
    ListValidationResults,
    AddChecks,
    RemoveChecks,
    Validate,
    GenerationFinished,
]


class CheckAgentV3ToolResponse(BaseModel):
    """Wrapper for V3 agent tool responses."""

    tool: CheckAgentV3ToolCall = Field(description="The tool call from the V3 agent")


# Corruption agent tool call models
CorruptionAgentToolCall = Union[ListTableSchemas, GetTableData, CorruptorBatch, GetTableColumnSchema]


class CorruptorAgentToolResponse(BaseModel):
    """Wrapper for corruption agent tool responses."""

    tool: CorruptionAgentToolCall = Field(description="The tool call from the corruption agent")


class Database:
    def __init__(
        self,
        database_id: str,
        max_execution_time: int = 30,
        max_output_tokens: Optional[int] = None,
        table_scopes: Optional[Set[str]] = None,
        max_sandbox_memory_mb: int = 512,
    ):
        self.database_id = database_id
        self.table_classes: Dict[str, Type[Table]] = {}
        self.table_data: Dict[str, pd.DataFrame] = {}
        self.checks: Dict[str, CheckLogic] = {}  # Stores agent-generated checks
        self.corruptors: Dict[str, CorruptionLogic] = {}  # Stores agent-generated corruptors
        self.rule_based_checks: Dict[str, CheckLogic] = {}  # Stores rule-based checks (read-only after initialization)
        self.max_execution_time = max_execution_time  # Maximum execution time in seconds for each method
        self.max_sandbox_memory_mb = max_sandbox_memory_mb  # Max memory per generated-code subprocess
        self.max_output_tokens = max_output_tokens  # Maximum character count for DataFrame outputs
        self.table_scopes = table_scopes or set()  # Set of table names to limit operations to

        # Check results bookkeeping with exception tracking
        self.check_result_store = CheckResultStore()

    @property
    def id(self) -> str:
        """Get the database identifier."""
        return self.database_id

    @property
    def check_generator_session_id(self) -> str:
        """Get the check generator session ID."""
        return f"{self.database_id}_check_generator"

    @property
    def corruptor_generator_session_id(self) -> str:
        """Get the corruptor generator session ID."""
        return f"{self.database_id}_corruptor_generator"

    @property
    def get_table_scopes(self) -> Set[str]:
        """Get the table scopes for this database."""
        return self.table_scopes

    def create_table(self, table_name: str, table_class: Type[Table]) -> None:
        """
        Register a Table class
        """
        if table_name in self.table_classes:
            raise ValueError(f"Table {table_name!r} already exists")

        # validate FK metadata
        for fk_col, (ref_table_name, ref_col) in table_class.foreign_keys().items():
            # Skip validation for self-referential foreign keys
            if ref_table_name == table_name:
                # Just check that the referenced column exists in the current table
                if ref_col not in table_class.__annotations__:
                    raise ValueError(
                        f"{table_name}.{fk_col} FK → {ref_table_name}.{ref_col}: referenced column does not exist"
                    )
                continue

            # Check if referenced table is registered
            if ref_table_name not in self.table_classes:
                raise ValueError(
                    f"{table_name}.{fk_col} FK → {ref_table_name}.{ref_col}: "
                    "referenced table is not yet registered in this Database"
                )

            # Check if referenced column exists in the referenced table
            ref_table_class = self.table_classes[ref_table_name]
            if ref_col not in ref_table_class.__annotations__:
                raise ValueError(
                    f"{table_name}.{fk_col} FK → {ref_table_name}.{ref_col}: referenced column does not exist"
                )
        self.table_classes[table_name] = table_class

    def _filter_tables(self, tables: Dict[str, Any]) -> Dict[str, Any]:
        """Filter tables based on table_scopes if set."""
        if not self.table_scopes:
            return tables
        return {k: v for k, v in tables.items() if k in self.table_scopes}

    @property
    def scoped_table_classes(self) -> Dict[str, Type[Table]]:
        """Get table classes filtered by table_scopes."""
        return self._filter_tables(self.table_classes)

    @property
    def scoped_table_data(self) -> Dict[str, pd.DataFrame]:
        """Get table data filtered by table_scopes."""
        return self._filter_tables(self.table_data)

    def list_table_schemas(self) -> Mapping[str, TableSchema]:
        """Return table schemas for all tables."""
        return {
            table_name: table_class.to_context(table_name)
            for table_name, table_class in self.scoped_table_classes.items()
        }

    def get_check(self, check_name: str) -> Optional[CheckLogic]:
        """Get a specific check by name.

        Parameters
        ----------
        check_name : str
            Name of the check to retrieve

        Returns
        -------
        Optional[CheckLogic]
            The check if it exists, None otherwise
        """
        # First check in agent-generated checks
        if check_name in self.checks:
            return self.checks[check_name]
        # Then check in rule-based checks
        if check_name in self.rule_based_checks:
            return self.rule_based_checks[check_name]
        return None

    def get_table_column_schema(self, table_name: str, column_name: str) -> Optional[TableColumnSchema]:
        """Get schema information for a specific table column.

        Parameters
        ----------
        table_name : str
            Name of the table
        column_name : str
            Name of the column

        Returns
        -------
        Optional[TableColumnSchema]
            Column schema information if the column exists, None otherwise
        """
        # Check if table exists
        if table_name not in self.table_classes:
            return None

        table_class = self.table_classes[table_name]

        # Check if column exists
        columns = table_class.columns()
        if column_name not in columns:
            return None

        # Get column schema from pandera
        col_schema = columns[column_name]

        # Check if it's a primary key
        primary_keys = table_class.primary_keys() if hasattr(table_class, "primary_keys") else []
        is_pk = column_name in primary_keys

        # Check if it's a foreign key
        foreign_keys = table_class.foreign_keys() if hasattr(table_class, "foreign_keys") else {}
        is_fk = column_name in foreign_keys
        fk_reference = foreign_keys.get(column_name) if is_fk else None

        # Get data type
        data_type = str(col_schema.dtype) if hasattr(col_schema, "dtype") else "object"

        # Get nullable status
        is_nullable = col_schema.nullable if hasattr(col_schema, "nullable") else True

        # Get constraints
        constraints = []
        if hasattr(col_schema, "checks") and col_schema.checks:
            for check in col_schema.checks:
                if hasattr(check, "name") and check.name:
                    constraints.append(check.name)

        # Get description
        description = col_schema.description if hasattr(col_schema, "description") else None

        return TableColumnSchema(
            table_name=table_name,
            column_name=column_name,
            data_type=data_type,
            is_primary_key=is_pk,
            is_foreign_key=is_fk,
            foreign_key_reference=fk_reference,
            is_nullable=is_nullable,
            constraints=constraints,
            description=description,
        )

    @with_timeout
    @with_token_limit
    def get_table_data(self, table_name: str) -> pd.DataFrame:
        """Fetch the DataFrame stored for table_cls (or raise)."""
        if table_name not in self.table_classes:
            raise ValueError(f"Table {table_name} not found")
        if self.table_scopes and table_name not in self.table_scopes:
            raise ValueError(f"Table {table_name} not in allowed scopes")
        return self.table_data[table_name]

    def profile_table_data(self, table_name: str, max_columns: int = 20, sample_size: int = 10) -> Dict[str, Any]:
        """
        Generate comprehensive statistics and profile for a table's data.

        Parameters
        ----------
        table_name : str
            Name of the table to profile
        max_columns : int
            Maximum number of columns to profile (default 20)
        sample_size : int
            Number of sample values to include per column (default 10)

        Returns
        -------
        Dict[str, Any]
            Dictionary containing table statistics and column profiles

        Raises
        ------
        ValueError
            If table_name is not found in the database
        """
        if table_name not in self.table_classes:
            raise ValueError(f"Table {table_name} not found")

        if self.table_scopes and table_name not in self.table_scopes:
            raise ValueError(f"Table {table_name} not in allowed scopes")
        df = self.table_data.get(table_name)
        if df is None or df.empty:
            return {"error": f"No data available for table {table_name}"}

        # Use the profile_table_data utility function
        from definition.base.util_profiler import profile_table_data

        return profile_table_data(df, max_columns=max_columns, sample_size=sample_size)

    def profile_table_column_data(self, table_name: str, column_name: str, sample_size: int = 10) -> Dict[str, Any]:
        """
        Generate detailed statistics and profile for a single column.

        Parameters
        ----------
        table_name : str
            Name of the table containing the column
        column_name : str
            Name of the column to profile
        sample_size : int
            Number of sample values to include (default 10)

        Returns
        -------
        Dict[str, Any]
            Dictionary containing detailed column statistics and profile

        Raises
        ------
        ValueError
            If table_name is not found or column_name is not in the table
        """
        if table_name not in self.table_classes:
            raise ValueError(f"Table {table_name} not found")

        if self.table_scopes and table_name not in self.table_scopes:
            raise ValueError(f"Table {table_name} not in allowed scopes")
        df = self.table_data.get(table_name)
        if df is None or df.empty:
            return {"error": f"No data available for table {table_name}"}

        # Use the profile_table_column_data utility function
        from definition.base.util_profiler import profile_table_column_data

        return profile_table_column_data(df, column_name, sample_size=sample_size)

    def set_table_data(self, table_name: str, dataframe: pd.DataFrame) -> None:
        """Set the DataFrame for a specific table.

        Parameters
        ----------
        table_name : str
            Name of the table to set data for
        dataframe : pd.DataFrame
            The DataFrame to store for this table

        Raises
        ------
        ValueError
            If table_name is not registered in this database
        """
        if table_name not in self.table_classes:
            raise ValueError(f"Table {table_name} not found in database")
        self.table_data[table_name] = dataframe

    def load_table_data_from_csv(self, table_name: str, path: str | os.PathLike[str], **kwargs) -> None:
        """Load the data from a CSV file into the table."""
        if table_name not in self.table_classes:
            raise ValueError(f"Table {table_name} not found")
        df, _ = self.table_classes[table_name].load_from_csv(path, **kwargs)
        self.table_data[table_name] = df

    def load_table_data_from_relbench(self, database_name: str) -> None:
        """Load table data from a RelBench dataset.

        Parameters
        ----------
        database_name : str
            Name of the RelBench database (e.g., 'rel-stack', 'rel-amazon')

        Raises
        ------
        ImportError
            If relbench is not installed
        ValueError
            If database loading fails
        """
        try:
            from relbench.datasets import get_dataset
        except ImportError:
            raise ImportError("relbench package is not installed. Install with: pip install relbench")

        # Load the dataset
        dataset = get_dataset(database_name)
        db = dataset.get_db()

        # Create case-insensitive mapping for table names
        relbench_table_map = {name.lower(): name for name in db.table_dict.keys()}

        # Load data for each registered table
        loaded_tables = []
        for table_name in self.scoped_table_classes.keys():
            # Try exact match first, then case-insensitive match
            relbench_name = None
            if table_name in db.table_dict:
                relbench_name = table_name
            elif table_name.lower() in relbench_table_map:
                relbench_name = relbench_table_map[table_name.lower()]

            if relbench_name:
                # Get the DataFrame from RelBench
                relbench_table = db.table_dict[relbench_name]
                df = relbench_table.df.copy()

                # Store the data
                self.table_data[table_name] = df
                loaded_tables.append(table_name)
                logger.debug(f"Loaded {table_name} from RelBench (as {relbench_name}): {len(df)} rows")
            else:
                logger.warning(f"Table {table_name} not found in RelBench database {database_name}")

        logger.info(f"Loaded {len(loaded_tables)} tables from RelBench database {database_name}")

    def get_table_schema(self, table_name: str) -> Dict[str, Any]:
        """Get detailed schema information for a specific table.

        Parameters
        ----------
        table_name : str
            Name of the table

        Returns
        -------
        Dict[str, Any]
            Detailed schema information including columns, keys, and constraints
        """
        if table_name not in self.table_classes:
            raise ValueError(f"Table {table_name} not found")

        table_class = self.table_classes[table_name]
        columns = table_class.columns()

        # Get primary and foreign keys
        primary_keys = table_class.primary_keys() if hasattr(table_class, "primary_keys") else []
        foreign_keys = table_class.foreign_keys() if hasattr(table_class, "foreign_keys") else []

        # Build column information
        column_info = {}
        for col_name, col_schema in columns.items():
            column_info[col_name] = {
                "data_type": str(col_schema.dtype),
                "nullable": col_schema.nullable,
                "is_primary_key": col_name in primary_keys,
                "is_foreign_key": any(fk[0] == col_name for fk in foreign_keys),
                "description": getattr(col_schema, "description", None),
            }

        return {
            "table_name": table_name,
            "columns": column_info,
            "primary_keys": primary_keys,
            "foreign_keys": foreign_keys,
            "row_count": len(self.table_data.get(table_name, pd.DataFrame())),
        }

    def list_validation_results(self, include_empty: bool = False) -> Dict[str, Dict[str, Any]]:
        """List all validation results with violation counts.

        Parameters
        ----------
        include_empty : bool
            Whether to include checks with no violations

        Returns
        -------
        Dict[str, Dict[str, Any]]
            Mapping of check names to result information
        """
        results = {}

        for check_name, result in self.check_result_store.get_all_results().items():
            if isinstance(result, Exception):
                results[check_name] = {"status": "error", "error": str(result), "violation_count": 0}
            elif isinstance(result, pd.DataFrame):
                violation_count = len(result)
                if include_empty or violation_count > 0:
                    results[check_name] = {
                        "status": "success",
                        "violation_count": violation_count,
                        "has_violations": violation_count > 0,
                    }

        return results

    def derive_rule_based_checks(self) -> None:
        """Derive and store all rule-based checks including pandera validation checks."""
        checks: Dict[str, CheckLogic] = {}

        # Generate pandera validation checks for each table
        for table_name, table_class in self.scoped_table_classes.items():
            # Get unique check names from the table schema
            schema = table_class.to_schema()

            # Collect column-level checks with column scope
            for column_name, col_schema in table_class.columns().items():
                if hasattr(col_schema, "checks") and col_schema.checks:
                    for check in col_schema.checks:
                        check_name = getattr(check, "name", None) or str(check)
                        if check_name:
                            # Create check name with table_column_checkname pattern
                            full_check_name = f"{table_name}_{column_name}_{check_name}"

                            checks[full_check_name] = create_pandera_check_placeholder(
                                table_name, full_check_name, column_name=column_name
                            )

            # Collect dataframe-level checks (no specific column scope)
            if hasattr(schema, "checks") and schema.checks:
                for check in schema.checks:
                    check_name = getattr(check, "name", None) or str(check)
                    if check_name:
                        # Dataframe-level check, no column in name
                        full_check_name = f"{table_name}_{check_name}"
                        checks[full_check_name] = create_pandera_check_placeholder(table_name, full_check_name)

        # Generate foreign key checks
        for child_table_name, child_table_class in self.scoped_table_classes.items():
            for fk_column, (parent_table_name, parent_column) in child_table_class.foreign_keys().items():
                # Only create FK check if the parent table is also in scope (or no scopes are set)
                if not self.table_scopes or parent_table_name in self.table_scopes:
                    # Create the FK check logic
                    fk_check = create_foreign_key_check(
                        child_table_name=child_table_name,
                        child_fk_column=fk_column,
                        parent_table_name=parent_table_name,
                        parent_column=parent_column,
                    )
                    checks[fk_check.function_name] = fk_check
                else:
                    logger.debug(
                        f"Skipping FK check for {child_table_name}.{fk_column} -> {parent_table_name}.{parent_column} (parent table not in scope)"
                    )

        # Store the derived checks
        self.rule_based_checks = checks

    @property
    def generated_checks(self) -> Dict[str, CheckLogic]:
        """Return all non-rule-based, generated checks."""
        return {name: check for name, check in self.checks.items() if name not in self.rule_based_checks}

    def get_rule_based_corruptors(self) -> Dict[str, CorruptionLogic]:
        """Return all rule-based corruptors generated from pandera constraints (calculated on demand)."""
        corruptors: Dict[str, CorruptionLogic] = {}

        # Generate corruptors from pandera constraints for each table
        for table_name, table_class in self.scoped_table_classes.items():
            table_corruptors = get_corruptors_from_pandera(table_name, table_class)
            for corruptor in table_corruptors:
                corruptors[corruptor.function_name] = corruptor

        # Generate foreign key corruptors based on foreign key relationships
        for child_table_name, child_table_class in self.scoped_table_classes.items():
            for fk_column, (parent_table_name, parent_column) in child_table_class.foreign_keys().items():
                fk_corruptor = create_foreign_key_corruption(
                    child_table_name=child_table_name,
                    child_column=fk_column,
                    parent_table_name=parent_table_name,
                    parent_column=parent_column,
                )
                corruptors[fk_corruptor.function_name] = fk_corruptor

        return corruptors

    def _execute_check(self, check_name: str, check: CheckLogic) -> Tuple[pd.DataFrame, Optional[Exception]]:
        """
        Execute a check on the table data.

        Parameters
        ----------
        check_name : str
            Name of the check to execute
        check : CheckLogic
            The check logic to execute

        Returns
        -------
        Tuple[pd.DataFrame, Optional[Exception]]
            Violations found by this check and any exception that occurred
        """
        from definition.base.corruption import corruption_from_validation_func
        from definition.base.executable_code import execute_sandboxed_function

        # Get only tables in check scope
        scope_tables = {table for table, _ in check.scope} if check.scope else set(self.scoped_table_data.keys())
        filtered_data = {
            table: self.scoped_table_data[table] for table in scope_tables if table in self.scoped_table_data
        }

        # Execute the check in sandbox
        try:
            code = check.to_code()
            result, error = execute_sandboxed_function(
                func_code=code,
                func_name=check.function_name,
                args=(filtered_data,),
                namespace=check._get_namespace(),
                timeout=self.max_execution_time,
                memory_limit_mb=self.max_sandbox_memory_mb,
            )

            if error:
                logger.warning(f"Check '{check_name}' failed: {error}")
                return pd.DataFrame(), error

            violations_df = corruption_from_validation_func(result, check_name, filtered_data)
            return violations_df, None
        except Exception as e:
            logger.warning(f"Check '{check_name}' failed: {e}")
            return pd.DataFrame(), e

    @with_timeout
    def validate(self) -> Dict[str, Union[pd.DataFrame, Exception]]:
        """
        Execute all the checks to validate the database.

        Returns
        -------
        Dict[str, Union[pd.DataFrame, Exception]]
            Dictionary mapping check names to their results (DataFrame for violations or Exception for errors)
        """
        # Clear previous results
        self.check_result_store.clear()

        # 1. First run pandera validation and store results grouped by check name and column
        for table_name, table_data in self.scoped_table_data.items():
            if table_name not in self.scoped_table_classes:
                continue

            # Skip validation for empty tables
            if table_data.empty:
                continue

            table_class = self.scoped_table_classes[table_name]

            try:
                # Use pandera's native validation with lazy=True to capture all errors
                schema = table_class.to_schema()
                schema.validate(table_data, lazy=True)

            except SchemaErrors as schema_errors:
                # Convert pandera errors to our standard format
                violations_df = corruption_from_pandera(table_name, schema_errors)

                if not violations_df.empty:
                    # Group by both check name and column name for more granular tracking
                    grouped = violations_df.groupby(["check", "column"])
                    for (check_name, column_name), group_df in grouped:
                        result_key = f"{table_name}_{check_name}_{column_name}"
                        self.check_result_store.set_result(result_key, group_df)

            except Exception as e:
                # Handle other validation errors gracefully
                print(f"Warning: Pandera validation failed for table '{table_name}': {e}")
                continue

        # 2. Collect all checks to execute (rule-based + agent-generated)
        all_checks = dict(self.rule_based_checks)
        if self.checks:
            all_checks.update(self.checks)

        # 3. Execute checks directly without topological ordering
        for check_name, check in all_checks.items():
            # Skip pandera placeholder checks as they were already executed
            if (
                check_name.startswith(tuple(self.scoped_table_classes.keys()))
                and check.body_lines == ["    return {}"]
                and self.check_result_store.has_check(check_name)
            ):
                # Already executed as part of pandera validation
                continue

            # Execute the check
            violations, exception = self._execute_check(check_name, check)

            # Store result (either DataFrame or Exception)
            self.check_result_store.set_result(check_name, exception if exception else violations)

        # Return all results (both DataFrames and Exceptions)
        return self.check_result_store.get_all_results()

    def export_validation_result(self, directory: str, override_existing_files: bool = True) -> None:
        """
        Export validation results by concatenating all violation DataFrames.

        Parameters
        ----------
        directory : str
            Directory to save the concatenated violations DataFrame
        override_existing_files : bool
            Whether to override existing files
        """
        from pathlib import Path

        # Create directory if it doesn't exist
        output_dir = Path(directory)
        output_dir.mkdir(parents=True, exist_ok=True)

        # Check if file exists and override_existing_files is False
        output_file = output_dir / "violations.csv"
        if output_file.exists() and not override_existing_files:
            logger.warning(f"File {output_file} already exists and override_existing_files is False. Skipping export.")
            return

        # Concatenate all violation DataFrames
        non_empty_results = {
            k: v for k, v in self.check_result_store.results.items() if isinstance(v, pd.DataFrame) and not v.empty
        }
        if not non_empty_results:
            # Create empty DataFrame with standard columns
            from definition.base.corruption import COLUMNS

            all_violations = pd.DataFrame(columns=COLUMNS)
        else:
            # Concatenate all non-empty DataFrames
            dfs_to_concat = list(non_empty_results.values())
            if dfs_to_concat:
                all_violations = pd.concat(dfs_to_concat, ignore_index=True)
            else:
                from definition.base.corruption import COLUMNS

                all_violations = pd.DataFrame(columns=COLUMNS)

        all_violations.to_csv(output_file, index=False)
        logger.info(f"Exported {len(all_violations)} violations to {output_file}")

    def evaluate(self, ground_truth_file: str) -> pd.DataFrame:
        """
        Evaluate detection performance by comparing check results against ground truth.

        Parameters
        ----------
        ground_truth_file : str
            Path to ground truth violations CSV file (in corruption DataFrame format)

        Returns
        -------
        pd.DataFrame
            Evaluation report with metrics for each check and overall performance
        """
        from definition.benchmark.eval.evaluator import Evaluation, load_violations_from_file

        # Load ground truth from file
        ground_truth = load_violations_from_file(ground_truth_file)
        logger.info(f"Loaded {len(ground_truth)} ground truth violations from {ground_truth_file}")

        # Get predictions from current check results
        predictions = self.check_result_store.concat_results()
        logger.info(f"Current check results contain {len(predictions)} predicted violations")

        # Create evaluator and generate report for only LLM-generated checks
        evaluator = Evaluation(ground_truth, predictions)

        # Get only LLM-generated check names (exclude rule-based checks)
        llm_check_names = set(self.checks.keys())

        # Get all check results to determine runnability
        all_check_results = self.check_result_store.get_all_results()

        # Generate report only for LLM-generated checks
        report = evaluator.generate_report_for_checks(check_names=llm_check_names, check_results=all_check_results)

        # Log summary
        overall_row = report[report["check_name"] == "OVERALL"].iloc[0] if len(report) > 0 else None
        if overall_row is not None:
            logger.info(
                f"Evaluation Results - Precision: {overall_row['precision']:.4f}, "
                f"Recall: {overall_row['recall']:.4f}, F1: {overall_row['f1_score']:.4f}"
            )

        return report

    def export(self, directory: str, override_existing_files: bool = True) -> None:
        """
        Export all table data to CSV files in the specified directory.

        Parameters
        ----------
        directory : str
            Directory path where CSV files will be saved
        override_existing_files : bool, default True
            If True, will overwrite existing files. If False, will raise error if file exists.

        Raises
        ------
        ValueError
            If override_existing_files is False and a file already exists
        FileNotFoundError
            If the directory doesn't exist and can't be created
        """
        # Create directory if it doesn't exist
        directory_path = Path(directory)
        directory_path.mkdir(parents=True, exist_ok=True)

        # Export each table
        for table_name, table_data in self.scoped_table_data.items():
            # Create filename
            filename = f"{table_name}.csv"
            file_path = directory_path / filename

            # Check if file exists and override is disabled
            if not override_existing_files and file_path.exists():
                raise ValueError(f"File '{file_path}' already exists and override_existing_files is False")

            # Export to CSV with original column names
            table_data.to_csv(file_path, index=False)

        print(f"Exported {len(self.table_data)} tables to directory: {directory_path.absolute()}")

    def corrupt(
        self, corruptor_name: str, percentage: float = 0.1, rand: Optional[random.Random] = None
    ) -> Mapping[str, pd.DataFrame]:
        """
        High-level API to corrupt table data using a specified corruptor.

        Parameters
        ----------
        corruptor_name : str
            Name of the corruption logic function to apply.
            Must match exactly one corruptor from rule_based_corruptors or llm_corruptors.
        percentage : float
            Corruption percentage (0.0 to 1.0). Default is 0.1 (10%).
            Specifies how many rows the corruptor should corrupt.
        rand : Optional[random.Random]
            Random number generator for reproducible corruption. If None, creates a new one with seed 42.

        Returns
        -------
        Mapping[str, pd.DataFrame]
            All table data with corruption applied

        Raises
        ------
        ValueError
            If corruptor name doesn't exist or matches multiple corruptors
        """
        # Validate percentage
        if not 0.0 <= percentage <= 1.0:
            raise ValueError(f"Percentage must be between 0.0 and 1.0, got {percentage}")

        # Find the corruptor
        matching_corruptors = []

        # Check rule-based corruptors
        rule_based_corruptors = self.get_rule_based_corruptors()
        if corruptor_name in rule_based_corruptors:
            matching_corruptors.append(rule_based_corruptors[corruptor_name])

        # Check LLM corruptors (use cache if available)
        if self.corruptors and corruptor_name in self.corruptors:
            matching_corruptors.append(self.corruptors[corruptor_name])

        # Validate we found exactly one corruptor
        if len(matching_corruptors) == 0:
            # List available corruptor names
            available_names = set(rule_based_corruptors.keys())
            if self.corruptors:
                available_names.update(self.corruptors.keys())

            raise ValueError(
                f"No corruptor found with name '{corruptor_name}'. "
                f"Available corruptor names: {sorted(available_names) if available_names else 'None'}"
            )
        elif len(matching_corruptors) > 1:
            raise ValueError(
                f"Multiple corruptors found with name '{corruptor_name}'. "
                f"This should not happen - corruptor names must be unique."
            )

        corruptor = matching_corruptors[0]

        # Use provided random generator or create a default one
        if rand is None:
            rand = random.Random(42)

        # Apply the corruption
        try:
            corruption_fn = corruptor.to_corruption_function()
            result_data = corruption_fn(self.table_data, rand, percentage)

            # Update the database's table_data with the corrupted data
            for table_name, corrupted_df in result_data.items():
                if table_name in self.table_data:
                    self.table_data[table_name] = corrupted_df
                    logger.debug(f"Updated table '{table_name}' with corrupted data")

            return result_data
        except Exception as e:
            logger.error(f"Corruptor '{corruptor_name}' failed: {e}")
            raise RuntimeError(f"Failed to apply corruptor '{corruptor_name}': {e}") from e

    def set_table_column_data(self, table_name: str, column_name: str, column_data: pd.Series) -> None:
        """
        Set data for a specific column in a table.

        Parameters
        ----------
        table_name : str
            Name of the table
        column_name : str
            Name of the column (can be CSV column name or table attribute name)
        column_data : pd.Series
            The new column data

        Raises
        ------
        ValueError
            If table doesn't exist or column data doesn't match table length
        """
        if table_name not in self.table_classes:
            raise ValueError(f"Table '{table_name}' not found")

        if table_name not in self.table_data:
            raise ValueError(f"No data loaded for table '{table_name}'")

        table_data = self.table_data[table_name]
        table_class = self.table_classes[table_name]

        # Handle both CSV column names and table attribute names
        actual_column_name = column_name

        if actual_column_name not in table_data.columns:
            available_columns = list(table_data.columns)
            table_attrs = list(table_class.__annotations__.keys())
            raise ValueError(
                f"Column '{column_name}' not found in table '{table_name}'. "
                f"Available CSV columns: {available_columns}. "
                f"Available table attributes: {table_attrs}"
            )

        if len(column_data) != len(table_data):
            raise ValueError(f"Column data length ({len(column_data)}) doesn't match table length ({len(table_data)})")

        # Update the column
        self.table_data[table_name][actual_column_name] = column_data

    def list_checks(self) -> Mapping[str, CheckLogic]:
        """
        Retrieve all validation checks.

        Returns
        -------
        Mapping[str, CheckLogic]
            Mapping from check name to CheckLogic for all checks
        """
        # Combine rule-based and agent-generated checks
        all_checks = {}
        all_checks.update(self.rule_based_checks)
        all_checks.update(self.checks)
        return all_checks

    def list_corruptors(self) -> Mapping[str, CorruptionLogic]:
        """
        Retrieve all corruptors.

        Returns
        -------
        Mapping[str, CorruptionLogic]
            Mapping from corruptor name to CorruptionLogic for all corruptors
        """
        # Combine rule-based and agent-generated corruptors
        all_corruptors = {}
        all_corruptors.update(self.get_rule_based_corruptors())
        all_corruptors.update(self.corruptors)
        return all_corruptors

    def add_checks(self, checks: Dict[str, CheckLogic]) -> None:
        """
        Add new validation checks to the database dynamically.

        Parameters
        ----------
        checks : Dict[str, CheckLogic]
            Dictionary of CheckLogic objects to add, keyed by function name
        """
        if not checks:
            return

        # Add to cached LLM checks
        for check_name, check in checks.items():
            # Add to cache
            self.checks[check_name] = check

            logger.debug(f"Added check '{check_name}' to database")

    def remove_checks(self, check_names: List[str]) -> List[str]:
        """
        Remove checks from the database. Only non-rule-based checks can be removed.
        Also removes all descendant checks in the dependency graph.

        Parameters
        ----------
        check_names : List[str]
            List of check names to remove

        Returns
        -------
        List[str]
            List of check names that were actually removed (including descendants)
        """
        removed_checks = []

        for check_name in check_names:
            # Skip if it's a rule-based check
            if check_name in self.rule_based_checks:
                logger.warning(f"Cannot remove rule-based check '{check_name}'")
                continue

            # Skip if check doesn't exist
            if check_name not in self.checks:
                logger.warning(f"Check '{check_name}' not found")
                continue

            # Remove the check
            del self.checks[check_name]
            removed_checks.append(check_name)
            logger.debug(f"Removed check '{check_name}'")

        # Clear check results for removed checks
        for check_name in removed_checks:
            if check_name in self.check_result_store.results:
                del self.check_result_store.results[check_name]

        return removed_checks

    def add_corruptors(self, corruptors: Dict[str, CorruptionLogic]) -> None:
        """
        Add new corruption strategies to the database dynamically.

        Parameters
        ----------
        corruptors : Dict[str, CorruptionLogic]
            Dictionary of CorruptionLogic objects to add, keyed by function name
        """
        if not corruptors:
            return

        # Add to cached corruptors
        for corruptor_name, corruptor in corruptors.items():
            self.corruptors[corruptor_name] = corruptor
            logger.debug(f"Added corruptor '{corruptor_name}' to database")

    @with_timeout
    @with_token_limit
    def execute_query(self, query: QueryLogic) -> pd.DataFrame:
        """
        Execute a custom query function on the database tables.

        Parameters
        ----------
        query : QueryLogic
            Query logic object containing the function to execute

        Returns
        -------
        pd.DataFrame
            Result of the query execution
        """
        from definition.base.executable_code import execute_sandboxed_function

        # Get the code and execute in sandbox
        code = query.to_code()
        result, error = execute_sandboxed_function(
            func_code=code,
            func_name=query.function_name,
            args=(self.scoped_table_data,),
            namespace=query._get_namespace(),
            timeout=30,
            memory_limit_mb=self.max_sandbox_memory_mb,
        )

        if error:
            raise error

        # Ensure result is a DataFrame
        if not isinstance(result, pd.DataFrame):
            raise ValueError(f"Query must return a pandas DataFrame, got {type(result)}")

        logger.debug(f"Executed query '{query.function_name}', returned {len(result)} rows")
        return result
