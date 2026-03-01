# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""V3 Check Generation Agent - Intelligent routing with context-aware tool selection."""

from typing import Dict, Optional, Any, Set
from enum import Enum
from loguru import logger
import json
import pandas as pd
from definition.base.executable_code import CheckLogic
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMSessionConfig
from definition.base.prompt_builder import check_generation_prompt_v3
from definition.base.database import (
    Database,
    # Data Schema Retrieval
    ListTableSchemas,
    GetTableSchema,
    GetTableColumnSchema,
    GetTableData,
    ProfileTableData,
    ProfileTableColumnData,
    # Check Retrieval
    ListChecks,
    GetCheck,
    # Validation Result Retrieval
    ListValidationResults,
    GetValidationResult,
    # Check Modification
    AddChecks,
    RemoveChecks,
    # Check Execution
    Validate,
    # Lifecycle Control
    GenerationFinished,
)
from definition.base.util_toolcalls import extract_tool_descriptions


class ToolCategory(Enum):
    """Categories of tools for intelligent routing."""

    DATA_SCHEMA_RETRIEVAL = "DataSchemaRetrieval"
    CHECK_RETRIEVAL = "CheckRetrieval"
    VALIDATION_RESULT_RETRIEVAL = "ValidationResultRetrieval"
    CHECK_MODIFICATION = "CheckModification"
    CHECK_EXECUTION = "CheckExecution"
    LIFECYCLE_CONTROL = "LifecycleControl"


class ToolRouter:
    """Intelligent tool router for V3 agent."""

    # Tool category mappings
    TOOL_CATEGORIES = {
        ToolCategory.DATA_SCHEMA_RETRIEVAL: {
            ListTableSchemas,
            GetTableSchema,
            GetTableColumnSchema,
            GetTableData,
            ProfileTableData,
            ProfileTableColumnData,
        },
        ToolCategory.CHECK_RETRIEVAL: {ListChecks, GetCheck},
        ToolCategory.VALIDATION_RESULT_RETRIEVAL: {ListValidationResults, GetValidationResult},
        ToolCategory.CHECK_MODIFICATION: {AddChecks, RemoveChecks},
        ToolCategory.CHECK_EXECUTION: {Validate},
        ToolCategory.LIFECYCLE_CONTROL: {GenerationFinished},
    }

    # Routing rules based on last tool call
    ROUTING_RULES = {
        None: {  # Initial state
            "categories": [
                ToolCategory.DATA_SCHEMA_RETRIEVAL,
                ToolCategory.CHECK_RETRIEVAL,
                ToolCategory.CHECK_EXECUTION,
                ToolCategory.VALIDATION_RESULT_RETRIEVAL,
            ],
            "message": "Please explore the database schema, examine existing checks, and validate them to understand the current state.",
        },
        ToolCategory.CHECK_MODIFICATION: {
            "categories": [ToolCategory.CHECK_EXECUTION, ToolCategory.CHECK_MODIFICATION],
            "message": "Checks have been modified. Please do further modification if needed, or validate to see the results of your changes.",
        },
        ToolCategory.CHECK_EXECUTION: {
            "categories": [ToolCategory.CHECK_RETRIEVAL, ToolCategory.VALIDATION_RESULT_RETRIEVAL],
            "message": "Validation complete. Please retrieve and analyze the results to understand what checks found violations.",
        },
        ToolCategory.DATA_SCHEMA_RETRIEVAL: {
            "categories": [ToolCategory.CHECK_RETRIEVAL, ToolCategory.CHECK_MODIFICATION, ToolCategory.CHECK_EXECUTION],
            "message": "Schema retrieved. You can now examine checks, create new ones, or run validation.",
        },
        ToolCategory.CHECK_RETRIEVAL: {
            "categories": [
                ToolCategory.CHECK_MODIFICATION,
                ToolCategory.CHECK_EXECUTION,
                ToolCategory.DATA_SCHEMA_RETRIEVAL,
            ],
            "message": "Checks retrieved. You can modify them, run validation, or explore more schema details.",
        },
        ToolCategory.VALIDATION_RESULT_RETRIEVAL: {
            "categories": [
                ToolCategory.CHECK_MODIFICATION,
                ToolCategory.CHECK_RETRIEVAL,
                ToolCategory.LIFECYCLE_CONTROL,
            ],
            "message": "Results analyzed. You can now modify checks based on findings, examine specific checks, or complete if satisfied.",
        },
    }

    @classmethod
    def get_tool_category(cls, tool_class: type) -> Optional[ToolCategory]:
        """Get the category for a given tool class."""
        for category, tools in cls.TOOL_CATEGORIES.items():
            if tool_class in tools:
                return category
        return None

    @classmethod
    def get_available_tools(cls, last_category: Optional[ToolCategory]) -> Set[type]:
        """Get available tools based on the last tool category used."""
        if last_category in cls.ROUTING_RULES:
            routing_rule = cls.ROUTING_RULES[last_category]
        elif last_category is None:
            routing_rule = cls.ROUTING_RULES[None]
        else:
            # Default: provide all tools
            all_tools = set()
            for tools in cls.TOOL_CATEGORIES.values():
                all_tools.update(tools)
            return all_tools

        # Collect tools from specified categories
        available_tools = set()
        for category in routing_rule["categories"]:
            available_tools.update(cls.TOOL_CATEGORIES[category])

        # Always include lifecycle control for completion
        available_tools.update(cls.TOOL_CATEGORIES[ToolCategory.LIFECYCLE_CONTROL])

        return available_tools

    @classmethod
    def get_routing_message(cls, last_category: Optional[ToolCategory]) -> str:
        """Get the routing message for the current state."""
        if last_category in cls.ROUTING_RULES:
            return cls.ROUTING_RULES[last_category]["message"]
        elif last_category is None:
            return cls.ROUTING_RULES[None]["message"]
        else:
            return "You have access to all tools. Please proceed with your analysis."


class CheckGenerationAgentV3:
    """Agent for generating validation checks using v3 mode (intelligent routing)."""

    def __init__(
        self,
        database: Database,
        session_manager: LLMSessionManager,
        config: LLMSessionConfig,
        session_id: Optional[str] = None,
    ):
        """
        Initialize the v3 check generation agent.

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
        self.session_id = session_id or f"{database.database_id}_check_generator_v3"
        self.router = ToolRouter()

        # Track state
        self.last_tool_category: Optional[ToolCategory] = None
        self.iteration_count = 0

        # Initialize with all tools for system message
        all_tools = set()
        for tools in ToolRouter.TOOL_CATEGORIES.values():
            all_tools.update(tools)
        self.all_tools = all_tools

        # Create union type dynamically
        from typing import Union as UnionType

        CheckAgentV3ToolCall = UnionType[tuple(all_tools)]

        # Generate system message with all tool descriptions
        tool_descriptions = extract_tool_descriptions(CheckAgentV3ToolCall)
        system_message = check_generation_prompt_v3(tool_descriptions, self.router.ROUTING_RULES)

        # Update config with system message
        self.config = config.model_copy(update={"system_message": system_message})

        # Register session
        self.session_manager.register_session(self.session_id, self.config)
        logger.debug(f"Initialized CheckGenerationAgentV3 with session {self.session_id}")

    def generate_checks(
        self, user_message: Optional[str] = None, max_iterations: int = 100, progress_callback: Optional[Any] = None
    ) -> Dict[str, CheckLogic]:
        """
        Generate checks using intelligent routing agent.

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
        logger.info(f"Generating checks using V3 intelligent routing (max {max_iterations} iterations)")

        # Build initial prompt with routing guidance
        user_context = f"\nUser Context: {user_message}\n" if user_message else ""
        routing_message = self.router.get_routing_message(None)

        prompt = f"""
        {routing_message}

        GOAL: Generate comprehensive checks that capture the important business logic and data quality rules for this database.
        Continue generating checks until you believe you have sufficiently captured the application logic.
        Use GenerationFinished when you think you have generated enough checks.
        {user_context}
        """

        # Use provided max_iterations
        generated_checks = {}  # Track generated checks to return

        try:
            while self.iteration_count < max_iterations:
                self.iteration_count += 1

                if progress_callback:
                    progress_callback.on_iteration_start(self.iteration_count)

                # Get available tools for current state
                available_tools = self.router.get_available_tools(self.last_tool_category)

                # Create response format from available tools
                from typing import Union as UnionType
                from pydantic import BaseModel, Field

                # Create union of available tool types
                CheckAgentToolResponse = UnionType[tuple(available_tools)]

                # Create response model with the available tools
                class DynamicToolResponse(BaseModel):
                    """Response containing one of the available tools."""

                    tool: CheckAgentToolResponse = Field(description="Tool to call based on current routing state")

                # Send message to LLM with dynamic response format
                response = self.session_manager.send_message(
                    session_id=self.session_id, message=prompt, response_format=DynamicToolResponse
                )

                # Extract the tool from the response
                tool_response = response.output.tool

                # Handle tool response and get next prompt
                prompt, should_complete = self._handle_tool_response(tool_response, generated_checks, progress_callback)

                if should_complete or prompt is None:
                    logger.info(f"Agent completed after {self.iteration_count} iterations")
                    if progress_callback:
                        progress_callback.on_completion(len(generated_checks))
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
        self, tool_response: Any, generated_checks: Dict[str, CheckLogic], progress_callback: Optional[Any]
    ) -> tuple[Optional[str], bool]:
        """
        Handle a tool response and update routing state.

        Returns (next_prompt, should_complete)
        """
        # Get tool category for routing
        tool_category = self.router.get_tool_category(type(tool_response))

        # Handle the specific tool response
        match tool_response:
            case ListTableSchemas():
                if progress_callback:
                    progress_callback.on_tool_call("ListTableSchemas", {})
                schemas_dict = self.database.list_table_schemas()
                schemas_json = [json.loads(s.model_dump_json()) for s in schemas_dict.values()]
                base_prompt = f"Table schemas:\n```json\n{json.dumps(schemas_json, indent=2)}\n```"
                if progress_callback:
                    progress_callback.on_tool_result("ListTableSchemas", f"Retrieved {len(schemas_dict)} table schemas")

            case GetTableSchema(table_name=table_name):
                if progress_callback:
                    progress_callback.on_tool_call("GetTableSchema", {"table_name": table_name})
                schema = self.database.list_table_schemas().get(table_name)
                if schema:
                    base_prompt = f"Schema for table '{table_name}':\n```json\n{schema.model_dump_json(indent=2)}\n```"
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableSchema", f"Retrieved schema for {table_name}")
                else:
                    base_prompt = f"Table '{table_name}' not found."
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableSchema", f"Table {table_name} not found")

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
                        row_dict = {k: (None if pd.isna(v) else v) for k, v in row_dict.items()}
                        jsonl_lines.append(json.dumps(row_dict, default=str))
                    df_jsonl = "\n".join(jsonl_lines)

                    # Check if data was truncated
                    if original_df is not None and len(df) < len(original_df):
                        base_prompt = f"Table '{table_name}' data (RESULT TRUNCATED: showing {len(df)} of {len(original_df)} total rows):\n```jsonl\n{df_jsonl}\n```"
                    else:
                        base_prompt = f"Table '{table_name}' data:\n```jsonl\n{df_jsonl}\n```"

                    if progress_callback:
                        progress_callback.on_tool_result("GetTableData", f"Retrieved {len(df)} rows from {table_name}")
                except Exception as e:
                    error_msg = "Operation timed out" if "timeout" in str(e).lower() else str(e)
                    base_prompt = f"Error retrieving table '{table_name}': {error_msg}. Try a different approach or continue with available information."
                    logger.warning(f"GetTableData failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableData", f"Error: {error_msg}")

            case GetTableColumnSchema(table_name=table_name, column_name=column_name):
                if progress_callback:
                    progress_callback.on_tool_call(
                        "GetTableColumnSchema", {"table_name": table_name, "column_name": column_name}
                    )
                column_schema = self.database.get_table_column_schema(table_name, column_name)
                if column_schema:
                    base_prompt = f"Column schema for '{table_name}.{column_name}':\n```json\n{column_schema.model_dump_json(indent=2)}\n```"
                    if progress_callback:
                        progress_callback.on_tool_result(
                            "GetTableColumnSchema", f"Retrieved schema for {table_name}.{column_name}"
                        )
                else:
                    base_prompt = f"Column '{table_name}.{column_name}' not found."
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableColumnSchema", f"Column not found")

            case ListChecks():
                if progress_callback:
                    progress_callback.on_tool_call("ListChecks", {})
                checks_mapping = self.database.list_checks()
                check_details = {name: check.to_dict() for name, check in checks_mapping.items()}
                base_prompt = (
                    f"Found {len(checks_mapping)} checks:\n```json\n{json.dumps(check_details, indent=2)}\n```"
                )
                if progress_callback:
                    progress_callback.on_tool_result("ListChecks", f"Found {len(checks_mapping)} checks")

            case GetCheck(check_name=check_name):
                if progress_callback:
                    progress_callback.on_tool_call("GetCheck", {"check_name": check_name})
                check = self.database.get_check(check_name)
                if check:
                    base_prompt = f"Check '{check_name}':\n```json\n{json.dumps(check.to_dict(), indent=2)}\n```"
                    if progress_callback:
                        progress_callback.on_tool_result("GetCheck", f"Retrieved check {check_name}")
                else:
                    base_prompt = f"Check '{check_name}' not found."
                    if progress_callback:
                        progress_callback.on_tool_result("GetCheck", "Check not found")

            case ListValidationResults():
                if progress_callback:
                    progress_callback.on_tool_call("ListValidationResults", {})
                summary = self.database.check_result_store.summary(
                    profile_violations=False,
                    only_generated_checks=True,
                    rule_based_check_names=set(self.database.rule_based_checks.keys()),
                )
                base_prompt = f"Validation results summary:\n```json\n{summary.model_dump_json(indent=2)}\n```"
                if progress_callback:
                    progress_callback.on_tool_result("ListValidationResults", f"Retrieved validation summary")

            case GetValidationResult(check_name=check_name):
                if progress_callback:
                    progress_callback.on_tool_call("GetValidationResult", {"check_name": check_name})
                result = self.database.check_result_store.get_result(check_name)
                if isinstance(result, pd.DataFrame) and not result.empty:
                    result_str = result.to_string()
                    base_prompt = f"Violations for '{check_name}':\n```\n{result_str}\n```"
                    if progress_callback:
                        progress_callback.on_tool_result("GetValidationResult", f"Found {len(result)} violations")
                elif isinstance(result, Exception):
                    base_prompt = f"Check '{check_name}' failed: {result}"
                    if progress_callback:
                        progress_callback.on_tool_result("GetValidationResult", "Check failed")
                else:
                    status = (
                        "passed (no violations)"
                        if self.database.check_result_store.has_check(check_name)
                        else "not found"
                    )
                    base_prompt = f"Check '{check_name}' {status}."
                    if progress_callback:
                        progress_callback.on_tool_result("GetValidationResult", status)

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
                base_prompt = f"Added {len(checks.checks)} checks. Total: {len(generated_checks)} checks generated."

            case RemoveChecks(check_names=check_names):
                if progress_callback:
                    progress_callback.on_tool_call("RemoveChecks", {"check_names": check_names})
                removed = self.database.remove_checks(check_names)
                # Also remove from generated_checks tracking
                for name in removed:
                    generated_checks.pop(name, None)
                base_prompt = (
                    f"Removed {len(removed)} checks: {removed}. Remaining: {len(generated_checks)} checks generated."
                )
                if progress_callback:
                    progress_callback.on_tool_result("RemoveChecks", f"Removed {len(removed)} checks")

            case Validate():
                if progress_callback:
                    progress_callback.on_tool_call("Validate", None)
                try:
                    results = self.database.validate()
                except Exception as e:
                    error_msg = "Validation timed out" if "timeout" in str(e).lower() else str(e)
                    base_prompt = (
                        f"Validation failed: {error_msg}. Try validating individual checks or continue with generation."
                    )
                    logger.warning(f"Validate failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("Validate", f"Failed: {error_msg}")
                    return base_prompt, False

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
                base_prompt = f"Validation complete:\n```json\n{summary.model_dump_json(indent=2)}\n```"

                if progress_callback:
                    msg = f"Found {len(violations)} checks with violations"
                    if exceptions:
                        msg += f", {len(exceptions)} checks failed"
                    progress_callback.on_tool_result("Validate", msg)

            case ProfileTableData(table_name=table_name):
                if progress_callback:
                    progress_callback.on_tool_call("ProfileTableData", {"table_name": table_name})

                try:
                    # Get profile data from database and return as JSON
                    profile_result = self.database.profile_table_data(table_name)
                    base_prompt = f"Profile of table '{table_name}':\n```json\n{json.dumps(profile_result, indent=2, default=str)}\n```"

                    if progress_callback:
                        progress_callback.on_tool_result("ProfileTableData", f"Profile generated for {table_name}")

                except Exception as e:
                    error_msg = str(e)
                    base_prompt = f"Failed to profile table '{table_name}': {error_msg}"
                    logger.warning(f"ProfileTableData failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("ProfileTableData", f"Failed: {error_msg}")

            case ProfileTableColumnData(table_name=table_name, column_name=column_name):
                if progress_callback:
                    progress_callback.on_tool_call(
                        "ProfileTableColumnData", {"table_name": table_name, "column_name": column_name}
                    )

                try:
                    # Get detailed column profile from database
                    profile_result = self.database.profile_table_column_data(table_name, column_name)
                    base_prompt = f"Profile of column '{table_name}.{column_name}':\n```json\n{json.dumps(profile_result, indent=2, default=str)}\n```"

                    if progress_callback:
                        progress_callback.on_tool_result(
                            "ProfileTableColumnData", f"Profile generated for {table_name}.{column_name}"
                        )

                except Exception as e:
                    error_msg = str(e)
                    base_prompt = f"Failed to profile column '{table_name}.{column_name}': {error_msg}"
                    logger.warning(f"ProfileTableColumnData failed: {e}")
                    if progress_callback:
                        progress_callback.on_tool_result("ProfileTableColumnData", f"Failed: {error_msg}")

            case GenerationFinished():
                if progress_callback:
                    progress_callback.on_completion(len(generated_checks))
                logger.info("Agent signaled completion")
                return None, True  # Signal completion

            case _:
                logger.warning(f"Unknown tool: {tool_response}")
                return None, False

        # Update routing state
        self.last_tool_category = tool_category

        # Get routing message for the current state
        routing_message = self.router.get_routing_message(tool_category)

        # Build next prompt with just base prompt and routing message
        next_prompt = f"{base_prompt}\n\n{routing_message}"

        return next_prompt, False
