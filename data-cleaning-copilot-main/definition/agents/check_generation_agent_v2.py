# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""V2 Check Generation Agent - Iterative generation with tool usage."""

from typing import Dict, Optional, Any
from loguru import logger
from definition.base.executable_code import CheckLogic
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMSessionConfig
from definition.base.prompt_builder import check_generation_prompt_v2
from definition.base.database import (
    Database,
    CheckAgentToolCall,
    CheckAgentToolResponse,
    ListTableSchemas,
    ListChecks,
    GetValidationResult,
    AddChecks,
    Validate,
    GetTableData,
    RemoveChecks,
    ExecuteQuery,
    GenerationFinished,
    ProfileTableData,
    ProfileTableColumnData,
    GetTableColumnSchema,
    GetCheck,
)
from definition.base.util_toolcalls import extract_tool_descriptions
import json
import pandas as pd


class CheckGenerationAgentV2:
    """Agent for generating validation checks using v2 mode (iterative with tools)."""

    def __init__(
        self,
        database: Database,
        session_manager: LLMSessionManager,
        config: LLMSessionConfig,
        session_id: Optional[str] = None,
    ):
        """
        Initialize the v2 check generation agent.

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
        self.session_id = session_id or f"{database.database_id}_check_generator_v2"

        # V2 prompt (with tools) - no additional context
        tool_descriptions = extract_tool_descriptions(CheckAgentToolCall)
        system_message = check_generation_prompt_v2(tool_descriptions)

        # Update config with system message
        self.config = config.model_copy(update={"system_message": system_message})

        # Register session
        self.session_manager.register_session(self.session_id, self.config)
        logger.debug(f"Initialized CheckGenerationAgentV2 with session {self.session_id}")

    def generate_checks(
        self, user_message: Optional[str] = None, max_iterations: int = 100, progress_callback: Optional[Any] = None
    ) -> Dict[str, CheckLogic]:
        """
        Generate checks using iterative agent with tool calls.

        Parameters
        ----------
        user_message : Optional[str]
            Optional user message for context
        max_iterations : int
            Maximum number of iterations for the agent
        progress_callback : Optional[Any]
            Optional callback for progress updates

        Returns
        -------
        Dict[str, CheckLogic]
            Generated validation checks mapped by function name
        """
        logger.info(f"Generating checks using V2 agent iteration (max {max_iterations} iterations)")

        # Build initial prompt
        if user_message:
            prompt = f"""
        {user_message}
        """
        else:
            prompt = "Generate validation checks for this database."

        current_iteration = 0
        total_checks_generated = 0
        generated_checks = {}  # Track generated checks to return

        try:
            while current_iteration < max_iterations:
                current_iteration += 1

                if progress_callback:
                    progress_callback.on_iteration_start(current_iteration)

                # Send message to LLM
                response = self.session_manager.send_message(
                    session_id=self.session_id, message=prompt, response_format=CheckAgentToolResponse
                )

                if not isinstance(response.output, CheckAgentToolResponse):
                    logger.warning(f"Unexpected response type: {type(response.output)}")
                    break

                tool_response = response.output.tool

                # Handle tool responses
                prompt = self._handle_tool_response(
                    tool_response, generated_checks, total_checks_generated, progress_callback
                )

                # Update total count
                total_checks_generated = len(generated_checks)

                # Check for completion conditions
                if prompt is None:  # Agent signaled completion (GenerationFinished)
                    break

            # Add all generated checks to database
            if generated_checks:
                self.database.add_checks(generated_checks)

            return generated_checks

        except Exception as e:
            logger.error(f"Check generation failed: {e}")
            if progress_callback:
                progress_callback.on_error(str(e))
            return generated_checks

    def _handle_tool_response(
        self,
        tool_response: Any,
        generated_checks: Dict[str, CheckLogic],
        total_checks_generated: int,
        progress_callback: Optional[Any],
    ) -> Optional[str]:
        """
        Handle a tool response from the agent.

        Returns the next prompt or None if done.
        """
        match tool_response:
            case ListTableSchemas():
                if progress_callback:
                    progress_callback.on_tool_call("ListTableSchemas", {})
                schemas_dict = self.database.list_table_schemas()
                schemas_json = [json.loads(s.model_dump_json()) for s in schemas_dict.values()]
                prompt = f"Table schemas:\n```json\n{json.dumps(schemas_json, indent=2)}\n```\nContinue analysis."
                if progress_callback:
                    progress_callback.on_tool_result("ListTableSchemas", f"Retrieved {len(schemas_dict)} table schemas")
                return prompt

            case ListChecks():
                if progress_callback:
                    progress_callback.on_tool_call("ListChecks", {})
                checks_mapping = self.database.list_checks()
                check_details = {name: check.to_dict() for name, check in checks_mapping.items()}
                prompt = f"""Found {len(checks_mapping)} checks:\n```json\n{json.dumps(check_details, indent=2)}\n```
AVOID REPEATLY CALLING THIS METHOD! Please proceed with generation using AddChecks, validation, or use GenerationFinished if you are done."""
                if progress_callback:
                    progress_callback.on_tool_result("ListChecks", f"Found {len(checks_mapping)} checks")
                return prompt

            case GetValidationResult(check_name=check_name):
                if progress_callback:
                    progress_callback.on_tool_call("GetValidationResult", {"check_name": check_name})
                result = self.database.check_result_store.get_result(check_name)
                if isinstance(result, pd.DataFrame) and not result.empty:
                    result_str = result.to_string()
                    prompt = f"Validation result for '{check_name}':\n```\n{result_str}\n```"
                    if progress_callback:
                        progress_callback.on_tool_result(
                            "GetValidationResult", f"Found {len(result)} violations for {check_name}"
                        )
                elif isinstance(result, Exception):
                    prompt = f"Check '{check_name}' failed with error: {result}"
                    if progress_callback:
                        progress_callback.on_tool_result("GetValidationResult", f"Check {check_name} failed with error")
                else:
                    status = "passed" if self.database.check_result_store.has_check(check_name) else "not found"
                    prompt = f"Check '{check_name}' {status}."
                    if progress_callback:
                        progress_callback.on_tool_result("GetValidationResult", f"Check {check_name} {status}")
                return prompt

            case AddChecks(checks=checks):
                check_names = []
                # checks is a CheckBatch object with a .checks attribute
                for check in checks.checks:
                    check_name = check.function_name
                    generated_checks[check_name] = check
                    check_names.append(check_name)
                # Add checks to database immediately
                self.database.add_checks({c.function_name: c for c in checks.checks})
                if progress_callback:
                    progress_callback.on_items_generated("checks", len(checks.checks), check_names)
                logger.info(f"Added {len(checks.checks)} new checks (total: {len(generated_checks)})")
                return f"Added {len(checks.checks)} checks. Total: {len(generated_checks)} checks generated. Use GenerationFinished when you think you have captured enough application logic."

            case GenerationFinished():
                if progress_callback:
                    progress_callback.on_completion(len(generated_checks))
                logger.info(f"Agent finished. Total checks generated: {len(generated_checks)}")
                return None  # Signal completion

            case Validate():
                if progress_callback:
                    progress_callback.on_tool_call("Validate", None)
                try:
                    results = self.database.validate()
                except Exception as e:
                    error_msg = "Validation timed out" if "timeout" in str(e).lower() else str(e)
                    prompt = (
                        f"Validation failed: {error_msg}. Try validating individual checks or continue with generation."
                    )
                    logger.warning(f"Validate failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("Validate", f"Failed: {error_msg}")
                    return prompt

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
                prompt = summary.model_dump_json(indent=2)

                if progress_callback:
                    violation_msg = f"Found {len(violations)} checks with violations"
                    if exceptions:
                        violation_msg += f", {len(exceptions)} checks failed"
                    progress_callback.on_tool_result("Validate", violation_msg)
                return prompt

            case GetTableData(table_name=table_name):
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
                        prompt = f"Table '{table_name}' data (RESULT TRUNCATED: showing {len(df)} of {len(original_df)} total rows):\n```jsonl\n{df_jsonl}\n```"
                    else:
                        prompt = f"Table '{table_name}' data:\n```jsonl\n{df_jsonl}\n```"

                    if progress_callback:
                        progress_callback.on_tool_result("GetTableData", f"Retrieved {len(df)} rows from {table_name}")
                except Exception as e:
                    error_msg = "Operation timed out" if "timeout" in str(e).lower() else str(e)
                    prompt = f"Failed to get table {table_name}: {error_msg}. Try a different approach or continue with available information."
                    logger.warning(f"GetTableData failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableData", f"Failed: {error_msg}")
                return prompt

            case RemoveChecks(check_names=check_names):
                if progress_callback:
                    progress_callback.on_tool_call("RemoveChecks", {"check_names": check_names})

                # Remove checks from database and our tracking
                removed_checks = self.database.remove_checks(check_names)

                if removed_checks:
                    # Also remove from generated_checks tracking
                    for check_name in removed_checks:
                        generated_checks.pop(check_name, None)

                    prompt = f"""Removed {len(removed_checks)} checks: {removed_checks}.
Current progress: {len(generated_checks)} checks generated.
Generate new checks to replace the removed ones or use GenerationFinished if you have enough."""
                    logger.info(f"Removed {len(removed_checks)} checks: {removed_checks}")
                else:
                    prompt = f"""No checks were removed (checks may be rule-based or not found).
Current progress: {len(generated_checks)} checks generated.
Generate new checks, validate existing ones, or use GenerationFinished if you have enough."""
                    logger.warning(f"Failed to remove any checks from: {check_names}")

                if progress_callback:
                    progress_callback.on_tool_result("RemoveChecks", f"Removed {len(removed_checks)} checks")
                return prompt

            case ExecuteQuery(query=query):
                if progress_callback:
                    progress_callback.on_tool_call("ExecuteQuery", {"query_name": query.function_name})

                try:
                    # Execute the query (may be truncated by decorator)
                    result_df = self.database.execute_query(query)

                    # Record the executed query if progress callback supports it
                    if progress_callback and hasattr(progress_callback, "on_query_executed"):
                        query_json = query.to_dict()
                        progress_callback.on_query_executed(query.function_name, query_json)

                    # Display the results
                    result_str = result_df.to_string()

                    # Check if result might be truncated (if close to token limit)
                    max_tokens = getattr(self.database, "max_output_tokens", None)
                    if max_tokens and len(result_str) >= (max_tokens * 0.9):  # If using 90%+ of limit
                        prompt = f"""Query '{query.function_name}' executed successfully (RESULT MAY BE TRUNCATED):
```
{result_str}
```
Use these query results to inform your check generation strategy."""
                    else:
                        prompt = f"""Query '{query.function_name}' executed successfully:
```
{result_str}
```
Use these query results to inform your check generation strategy."""

                    if progress_callback:
                        progress_callback.on_tool_result("ExecuteQuery", f"Query returned {len(result_df)} rows")

                except Exception as e:
                    error_msg = str(e)
                    prompt = f"Query '{query.function_name}' failed: {error_msg}"
                    logger.warning(f"ExecuteQuery failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("ExecuteQuery", f"Failed: {error_msg}")

                return prompt

            case ProfileTableData(table_name=table_name):
                if progress_callback:
                    progress_callback.on_tool_call("ProfileTableData", {"table_name": table_name})

                try:
                    # Get profile data from database and return as JSON
                    profile_result = self.database.profile_table_data(table_name)
                    # Use default=str to handle Timestamp and other non-serializable objects
                    prompt = f"Profile of table '{table_name}':\n```json\n{json.dumps(profile_result, indent=2, default=str)}\n```"

                    if progress_callback:
                        progress_callback.on_tool_result("ProfileTableData", f"Profile generated for {table_name}")

                except Exception as e:
                    error_msg = str(e)
                    prompt = f"Failed to profile table '{table_name}': {error_msg}"
                    logger.warning(f"ProfileTableData failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("ProfileTableData", f"Failed: {error_msg}")

                return prompt

            case ProfileTableColumnData(table_name=table_name, column_name=column_name):
                if progress_callback:
                    progress_callback.on_tool_call(
                        "ProfileTableColumnData", {"table_name": table_name, "column_name": column_name}
                    )

                try:
                    # Get detailed column profile from database
                    profile_result = self.database.profile_table_column_data(table_name, column_name)
                    # Use default=str to handle Timestamp and other non-serializable objects
                    prompt = f"Profile of column '{table_name}.{column_name}':\n```json\n{json.dumps(profile_result, indent=2, default=str)}\n```"

                    if progress_callback:
                        progress_callback.on_tool_result(
                            "ProfileTableColumnData", f"Profile generated for {table_name}.{column_name}"
                        )

                except Exception as e:
                    error_msg = str(e)
                    prompt = f"Failed to profile column '{table_name}.{column_name}': {error_msg}"
                    logger.warning(f"ProfileTableColumnData failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("ProfileTableColumnData", f"Failed: {error_msg}")

                return prompt

            case GetTableColumnSchema(table_name=table_name, column_name=column_name):
                if progress_callback:
                    progress_callback.on_tool_call(
                        "GetTableColumnSchema", {"table_name": table_name, "column_name": column_name}
                    )

                try:
                    # Get column schema information using list_table_schemas
                    schemas = self.database.list_table_schemas()
                    table_schema = schemas.get(table_name)
                    if not table_schema:
                        prompt = f"Table '{table_name}' not found in database schema."
                    else:
                        # TableSchema has table_schema_json as a string attribute
                        schema_dict = json.loads(table_schema.table_schema_json)
                        column_info = schema_dict.get("columns", {}).get(column_name)

                        if column_info:
                            prompt = f"Column schema for '{table_name}.{column_name}':\n```json\n{json.dumps(column_info, indent=2)}\n```"
                        else:
                            prompt = f"Column '{column_name}' not found in table '{table_name}'."

                    if progress_callback:
                        progress_callback.on_tool_result(
                            "GetTableColumnSchema", f"Retrieved schema for {table_name}.{column_name}"
                        )

                except Exception as e:
                    error_msg = str(e)
                    prompt = f"Failed to get column schema: {error_msg}"
                    logger.warning(f"GetTableColumnSchema failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableColumnSchema", f"Failed: {error_msg}")

                return prompt

            case GetCheck(check_name=check_name):
                if progress_callback:
                    progress_callback.on_tool_call("GetCheck", {"check_name": check_name})

                try:
                    # Get check from database
                    checks = self.database.list_checks()
                    if check_name in checks:
                        check = checks[check_name]
                        check_dict = check.to_dict()
                        prompt = f"Check '{check_name}':\n```json\n{json.dumps(check_dict, indent=2)}\n```"
                        if progress_callback:
                            progress_callback.on_tool_result("GetCheck", f"Retrieved check {check_name}")
                    else:
                        prompt = f"Check '{check_name}' not found."
                        if progress_callback:
                            progress_callback.on_tool_result("GetCheck", f"Check {check_name} not found")

                except Exception as e:
                    error_msg = str(e)
                    prompt = f"Failed to get check: {error_msg}"
                    logger.warning(f"GetCheck failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("GetCheck", f"Failed: {error_msg}")

                return prompt

            case _:
                logger.warning(f"Unknown tool: {tool_response}")
                return None
