# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Base class for check generation agents with common tool handling logic."""

from abc import ABC, abstractmethod
from typing import Dict, Optional, Any, Set
import json
import pandas as pd
from loguru import logger

from definition.base.executable_code import CheckLogic
from definition.base.database import Database
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMSessionConfig


class BaseCheckGenerationAgent(ABC):
    """
    Abstract base class for check generation agents.
    
    Provides common infrastructure for:
    - Database interaction
    - LLM session management
    - Tool response handling
    - Progress tracking
    
    Subclasses implement version-specific behavior through abstract methods.
    """

    def __init__(
        self,
        database: Database,
        session_manager: LLMSessionManager,
        config: LLMSessionConfig,
        session_id: Optional[str] = None,
    ):
        """
        Initialize the base check generation agent.

        Parameters
        ----------
        database : Database
            The database to generate checks for
        session_manager : LLMSessionManager
            Manager for LLM sessions
        config : LLMSessionConfig
            Configuration for the LLM session
        session_id : Optional[str]
            Optional session ID, will be auto-generated if not provided
        """
        self.database = database
        self.session_manager = session_manager
        self.base_config = config
        self._session_id = session_id
        self.generated_checks: Dict[str, CheckLogic] = {}

    @property
    def session_id(self) -> str:
        """Get the session ID for this agent."""
        if self._session_id:
            return self._session_id
        return f"{self.database.database_id}_check_generator_{self.version}"

    @property
    @abstractmethod
    def version(self) -> str:
        """Return the agent version identifier (e.g., 'v1', 'v2', 'v3')."""
        pass

    @abstractmethod
    def get_system_prompt(self) -> str:
        """Return the system prompt for this agent version."""
        pass

    @abstractmethod
    def generate_checks(
        self,
        user_message: Optional[str] = None,
        max_iterations: int = 100,
        progress_callback: Optional[Any] = None,
    ) -> Dict[str, CheckLogic]:
        """
        Generate validation checks for the database.

        Parameters
        ----------
        user_message : Optional[str]
            Optional user message for context
        max_iterations : int
            Maximum number of iterations (for iterative agents)
        progress_callback : Optional[Any]
            Optional callback for progress updates

        Returns
        -------
        Dict[str, CheckLogic]
            Generated validation checks mapped by function name
        """
        pass

    # =========================================================================
    # Common Tool Handlers
    # =========================================================================

    def handle_list_table_schemas(self, progress_callback: Optional[Any] = None) -> str:
        """
        Handle ListTableSchemas tool call.
        
        Returns a JSON representation of all table schemas in the database.
        """
        if progress_callback:
            progress_callback.on_tool_call("ListTableSchemas", {})

        schemas_dict = self.database.list_table_schemas()
        schemas_json = [json.loads(s.model_dump_json()) for s in schemas_dict.values()]
        
        result = f"Table schemas:\n```json\n{json.dumps(schemas_json, indent=2)}\n```\nContinue analysis."
        
        if progress_callback:
            progress_callback.on_tool_result("ListTableSchemas", f"Retrieved {len(schemas_dict)} table schemas")
        
        return result

    def handle_list_checks(self, progress_callback: Optional[Any] = None) -> str:
        """
        Handle ListChecks tool call.
        
        Returns a JSON representation of all registered checks.
        """
        if progress_callback:
            progress_callback.on_tool_call("ListChecks", {})

        checks_mapping = self.database.list_checks()
        check_details = {name: check.to_dict() for name, check in checks_mapping.items()}
        
        result = f"""Found {len(checks_mapping)} checks:\n```json\n{json.dumps(check_details, indent=2)}\n```
AVOID REPEATEDLY CALLING THIS METHOD! Please proceed with generation using AddChecks, validation, or use GenerationFinished if you are done."""
        
        if progress_callback:
            progress_callback.on_tool_result("ListChecks", f"Found {len(checks_mapping)} checks")
        
        return result

    def handle_get_check(self, check_name: str, progress_callback: Optional[Any] = None) -> str:
        """
        Handle GetCheck tool call.
        
        Returns details for a specific check.
        """
        if progress_callback:
            progress_callback.on_tool_call("GetCheck", {"check_name": check_name})

        try:
            checks = self.database.list_checks()
            if check_name in checks:
                check = checks[check_name]
                check_dict = check.to_dict()
                result = f"Check '{check_name}':\n```json\n{json.dumps(check_dict, indent=2)}\n```"
                if progress_callback:
                    progress_callback.on_tool_result("GetCheck", f"Retrieved check {check_name}")
            else:
                result = f"Check '{check_name}' not found."
                if progress_callback:
                    progress_callback.on_tool_result("GetCheck", f"Check {check_name} not found")
        except Exception as e:
            result = f"Failed to get check: {e}"
            logger.warning(f"GetCheck failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("GetCheck", f"Failed: {e}")

        return result

    def handle_get_validation_result(self, check_name: str, progress_callback: Optional[Any] = None) -> str:
        """
        Handle GetValidationResult tool call.
        
        Returns validation results for a specific check.
        """
        if progress_callback:
            progress_callback.on_tool_call("GetValidationResult", {"check_name": check_name})

        result_data = self.database.check_result_store.get_result(check_name)
        
        if isinstance(result_data, pd.DataFrame) and not result_data.empty:
            result_str = result_data.to_string()
            result = f"Validation result for '{check_name}':\n```\n{result_str}\n```"
            if progress_callback:
                progress_callback.on_tool_result(
                    "GetValidationResult", f"Found {len(result_data)} violations for {check_name}"
                )
        elif isinstance(result_data, Exception):
            result = f"Check '{check_name}' failed with error: {result_data}"
            if progress_callback:
                progress_callback.on_tool_result("GetValidationResult", f"Check {check_name} failed with error")
        else:
            status = "passed" if self.database.check_result_store.has_check(check_name) else "not found"
            result = f"Check '{check_name}' {status}."
            if progress_callback:
                progress_callback.on_tool_result("GetValidationResult", f"Check {check_name} {status}")
        
        return result

    def handle_validate(self, progress_callback: Optional[Any] = None) -> str:
        """
        Handle Validate tool call.
        
        Runs all validation checks and returns a summary.
        """
        if progress_callback:
            progress_callback.on_tool_call("Validate", None)

        try:
            results = self.database.validate()
        except Exception as e:
            error_msg = "Validation timed out" if "timeout" in str(e).lower() else str(e)
            result = f"Validation failed: {error_msg}. Try validating individual checks or continue with generation."
            logger.warning(f"Validate failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("Validate", f"Failed: {error_msg}")
            return result

        # Count violations and exceptions
        violations = {k: v for k, v in results.items() if isinstance(v, pd.DataFrame) and not v.empty}
        exceptions = {k: v for k, v in results.items() if isinstance(v, Exception)}

        # Generate summary
        summary = self.database.check_result_store.summary(
            profile_violations=True,
            max_columns=10,
            sample_size=5,
            only_generated_checks=True,
            rule_based_check_names=set(self.database.rule_based_checks.keys()),
        )
        result = summary.model_dump_json(indent=2)

        if progress_callback:
            violation_msg = f"Found {len(violations)} checks with violations"
            if exceptions:
                violation_msg += f", {len(exceptions)} checks failed"
            progress_callback.on_tool_result("Validate", violation_msg)

        return result

    def handle_get_table_data(self, table_name: str, progress_callback: Optional[Any] = None) -> str:
        """
        Handle GetTableData tool call.
        
        Returns data from a specific table in JSONL format.
        """
        if progress_callback:
            progress_callback.on_tool_call("GetTableData", {"table_name": table_name})

        try:
            original_df = self.database.table_data.get(table_name)
            df = self.database.get_table_data(table_name)

            # Convert DataFrame to JSONL format
            jsonl_lines = []
            for _, row in df.iterrows():
                row_dict = row.to_dict()
                # Convert NaN and other special values to None for JSON serialization
                row_dict = {k: (None if pd.isna(v) else v) for k, v in row_dict.items()}
                jsonl_lines.append(json.dumps(row_dict, default=str))
            df_jsonl = "\n".join(jsonl_lines)

            # Check if data was truncated
            if original_df is not None and len(df) < len(original_df):
                result = f"Table '{table_name}' data (RESULT TRUNCATED: showing {len(df)} of {len(original_df)} total rows):\n```jsonl\n{df_jsonl}\n```"
            else:
                result = f"Table '{table_name}' data:\n```jsonl\n{df_jsonl}\n```"

            if progress_callback:
                progress_callback.on_tool_result("GetTableData", f"Retrieved {len(df)} rows from {table_name}")

        except Exception as e:
            error_msg = "Operation timed out" if "timeout" in str(e).lower() else str(e)
            result = f"Failed to get table {table_name}: {error_msg}. Try a different approach or continue with available information."
            logger.warning(f"GetTableData failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("GetTableData", f"Failed: {error_msg}")

        return result

    def handle_profile_table_data(self, table_name: str, progress_callback: Optional[Any] = None) -> str:
        """
        Handle ProfileTableData tool call.
        
        Returns profiling statistics for a table.
        """
        if progress_callback:
            progress_callback.on_tool_call("ProfileTableData", {"table_name": table_name})

        try:
            profile_result = self.database.profile_table_data(table_name)
            result = f"Profile of table '{table_name}':\n```json\n{json.dumps(profile_result, indent=2, default=str)}\n```"

            if progress_callback:
                progress_callback.on_tool_result("ProfileTableData", f"Profile generated for {table_name}")

        except Exception as e:
            result = f"Failed to profile table '{table_name}': {e}"
            logger.warning(f"ProfileTableData failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("ProfileTableData", f"Failed: {e}")

        return result

    def handle_profile_table_column_data(
        self, table_name: str, column_name: str, progress_callback: Optional[Any] = None
    ) -> str:
        """
        Handle ProfileTableColumnData tool call.
        
        Returns detailed profiling statistics for a specific column.
        """
        if progress_callback:
            progress_callback.on_tool_call(
                "ProfileTableColumnData", {"table_name": table_name, "column_name": column_name}
            )

        try:
            profile_result = self.database.profile_table_column_data(table_name, column_name)
            result = f"Profile of column '{table_name}.{column_name}':\n```json\n{json.dumps(profile_result, indent=2, default=str)}\n```"

            if progress_callback:
                progress_callback.on_tool_result(
                    "ProfileTableColumnData", f"Profile generated for {table_name}.{column_name}"
                )

        except Exception as e:
            result = f"Failed to profile column '{table_name}.{column_name}': {e}"
            logger.warning(f"ProfileTableColumnData failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("ProfileTableColumnData", f"Failed: {e}")

        return result

    def handle_get_table_column_schema(
        self, table_name: str, column_name: str, progress_callback: Optional[Any] = None
    ) -> str:
        """
        Handle GetTableColumnSchema tool call.
        
        Returns schema information for a specific column.
        """
        if progress_callback:
            progress_callback.on_tool_call(
                "GetTableColumnSchema", {"table_name": table_name, "column_name": column_name}
            )

        try:
            schemas = self.database.list_table_schemas()
            table_schema = schemas.get(table_name)
            
            if not table_schema:
                result = f"Table '{table_name}' not found in database schema."
            else:
                schema_dict = json.loads(table_schema.table_schema_json)
                column_info = schema_dict.get("columns", {}).get(column_name)

                if column_info:
                    result = f"Column schema for '{table_name}.{column_name}':\n```json\n{json.dumps(column_info, indent=2)}\n```"
                else:
                    result = f"Column '{column_name}' not found in table '{table_name}'."

            if progress_callback:
                progress_callback.on_tool_result(
                    "GetTableColumnSchema", f"Retrieved schema for {table_name}.{column_name}"
                )

        except Exception as e:
            result = f"Failed to get column schema: {e}"
            logger.warning(f"GetTableColumnSchema failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("GetTableColumnSchema", f"Failed: {e}")

        return result

    def handle_execute_query(self, query: Any, progress_callback: Optional[Any] = None) -> str:
        """
        Handle ExecuteQuery tool call.
        
        Executes a custom query function on the database.
        """
        if progress_callback:
            progress_callback.on_tool_call("ExecuteQuery", {"query_name": query.function_name})

        try:
            result_df = self.database.execute_query(query)

            if progress_callback and hasattr(progress_callback, "on_query_executed"):
                query_json = query.to_dict()
                progress_callback.on_query_executed(query.function_name, query_json)

            result_str = result_df.to_string()

            max_tokens = getattr(self.database, "max_output_tokens", None)
            if max_tokens and len(result_str) >= (max_tokens * 0.9):
                result = f"""Query '{query.function_name}' executed successfully (RESULT MAY BE TRUNCATED):
```
{result_str}
```
Use these query results to inform your check generation strategy."""
            else:
                result = f"""Query '{query.function_name}' executed successfully:
```
{result_str}
```
Use these query results to inform your check generation strategy."""

            if progress_callback:
                progress_callback.on_tool_result("ExecuteQuery", f"Query returned {len(result_df)} rows")

        except Exception as e:
            result = f"Query '{query.function_name}' failed: {e}"
            logger.warning(f"ExecuteQuery failed: {e}")
            if progress_callback:
                progress_callback.on_tool_result("ExecuteQuery", f"Failed: {e}")

        return result

    def handle_remove_checks(
        self, check_names: list, progress_callback: Optional[Any] = None
    ) -> str:
        """
        Handle RemoveChecks tool call.
        
        Removes specified checks from the database.
        """
        if progress_callback:
            progress_callback.on_tool_call("RemoveChecks", {"check_names": check_names})

        removed_checks = self.database.remove_checks(check_names)

        if removed_checks:
            # Also remove from generated_checks tracking
            for check_name in removed_checks:
                self.generated_checks.pop(check_name, None)

            result = f"""Removed {len(removed_checks)} checks: {removed_checks}.
Current progress: {len(self.generated_checks)} checks generated.
Generate new checks to replace the removed ones or use GenerationFinished if you have enough."""
            logger.info(f"Removed {len(removed_checks)} checks: {removed_checks}")
        else:
            result = f"""No checks were removed (checks may be rule-based or not found).
Current progress: {len(self.generated_checks)} checks generated.
Generate new checks, validate existing ones, or use GenerationFinished if you have enough."""
            logger.warning(f"Failed to remove any checks from: {check_names}")

        if progress_callback:
            progress_callback.on_tool_result("RemoveChecks", f"Removed {len(removed_checks)} checks")

        return result

    # =========================================================================
    # Utility Methods
    # =========================================================================

    def get_rule_based_check_names(self) -> Set[str]:
        """Return the set of rule-based check names."""
        return set(self.database.rule_based_checks.keys())

    def add_generated_check(self, check: CheckLogic) -> None:
        """Add a check to both local tracking and the database."""
        self.generated_checks[check.function_name] = check
        self.database.add_checks({check.function_name: check})

    def add_generated_checks(self, checks: Dict[str, CheckLogic]) -> None:
        """Add multiple checks to both local tracking and the database."""
        self.generated_checks.update(checks)
        self.database.add_checks(checks)