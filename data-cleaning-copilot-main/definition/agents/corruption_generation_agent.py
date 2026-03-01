# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Corruption Generation Agent - Interactive generation with tool usage."""

from typing import Dict, Optional, Any
from loguru import logger
from definition.base.executable_code import CorruptionLogic, CorruptorBatch
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMSessionConfig
from definition.base.prompt_builder import corruptor_generation_prompt
from definition.base.database import (
    Database,
    CorruptionAgentToolCall,
    CorruptorAgentToolResponse,
    ListTableSchemas,
    GetTableData,
    CorruptorBatch as CorruptorBatchCall,
)
from definition.base.util_toolcalls import extract_tool_descriptions
import json


class CorruptionGenerationAgent:
    """Agent for generating corruption strategies using LLM with tools."""

    def __init__(
        self,
        database: Database,
        session_manager: LLMSessionManager,
        config: LLMSessionConfig,
        session_id: Optional[str] = None,
    ):
        """
        Initialize the corruption generation agent.

        Parameters
        ----------
        database : Database
            The database to generate corruptions for
        session_manager : LLMSessionManager
            Manager for LLM sessions
        config : LLMSessionConfig
            Configuration for the LLM session
        session_id : Optional[str]
            Optional session ID, will be auto-generated if not provided
        """
        self.database = database
        self.session_manager = session_manager
        self.session_id = session_id or f"{database.database_id}_corruptor_generator"

        # Corruption generation prompt (with tools) - no additional context
        tool_descriptions = extract_tool_descriptions(CorruptionAgentToolCall)
        available_tables = list(database.table_classes.keys())
        system_message = corruptor_generation_prompt(tool_descriptions, available_tables)

        # Update config with system message
        self.config = config.model_copy(update={"system_message": system_message})

        # Register session
        self.session_manager.register_session(self.session_id, self.config)
        logger.debug(f"Initialized CorruptionGenerationAgent with session {self.session_id}")

    def generate_corruptions(
        self, user_message: str, progress_callback: Optional[Any] = None
    ) -> Dict[str, CorruptionLogic]:
        """
        Generate corruption strategies based on user requirements.

        Parameters
        ----------
        user_message : str
            User's requirements for corruption generation
        progress_callback : Optional[Any]
            Optional callback for progress updates

        Returns
        -------
        Dict[str, CorruptionLogic]
            Generated corruption strategies mapped by function name
        """
        logger.info(f"Generating corruption strategies based on: {user_message}")

        prompt = f"""
        Database Corruption Strategy Generation
        
        User Requirement: {user_message}
        """

        max_iterations = 10  # Safety limit
        current_iteration = 0
        generated_corruptors = {}  # Track generated corruptors

        try:
            while current_iteration < max_iterations:
                current_iteration += 1

                if progress_callback:
                    progress_callback.on_iteration_start(current_iteration)

                # Send message to LLM
                response = self.session_manager.send_message(
                    session_id=self.session_id, message=prompt, response_format=CorruptorAgentToolResponse
                )

                if not isinstance(response.output, CorruptorAgentToolResponse):
                    logger.warning(f"Unexpected response type: {type(response.output)}")
                    break

                tool_response = response.output.tool

                # Handle tool response
                prompt = self._handle_tool_response(tool_response, generated_corruptors, progress_callback)

                # Check for completion
                if prompt is None:
                    break

            # Add all generated corruptors to database
            if generated_corruptors:
                self.database.add_corruptors(generated_corruptors)

            return generated_corruptors

        except Exception as e:
            logger.error(f"Corruption generation failed: {e}")
            if progress_callback:
                progress_callback.on_error(str(e))
            return generated_corruptors

    def _handle_tool_response(
        self, tool_response: Any, generated_corruptors: Dict[str, CorruptionLogic], progress_callback: Optional[Any]
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
                logger.debug("Corruption agent requested table schemas")
                return prompt

            case GetTableData(table_name=table_name):
                if progress_callback:
                    progress_callback.on_tool_call("GetTableData", {"table_name": table_name})
                try:
                    df = self.database.get_table_data(table_name)
                    from definition.base.util_profiler import profile_table_data

                    profile_dict = profile_table_data(df)
                    profile_json = json.dumps(profile_dict, indent=2)
                    prompt = f"Table '{table_name}' profile:\n```json\n{profile_json}\n```"
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableData", f"Retrieved {len(df)} rows from {table_name}")
                    logger.debug(f"Corruption agent requested table {table_name}: {len(df)} rows")
                except Exception as e:
                    prompt = f"Failed to get table {table_name}: {e}"
                    if progress_callback:
                        progress_callback.on_tool_result("GetTableData", f"Failed to get table {table_name}")
                    logger.error(f"Corruption agent failed to get table {table_name}: {e}")
                return prompt

            case CorruptorBatchCall(corruptors=corruptors):
                if corruptors:
                    # Add all corruptors
                    corruptor_names = []
                    for corruptor in corruptors:
                        generated_corruptors[corruptor.function_name] = corruptor
                        corruptor_names.append(corruptor.function_name)
                        logger.info(f"Generated corruptor: {corruptor.function_name} - {corruptor.description}")

                    # Add to database immediately
                    self.database.add_corruptors({c.function_name: c for c in corruptors})

                    if progress_callback:
                        progress_callback.on_items_generated("corruptors", len(corruptors), corruptor_names)
                    logger.info(f"Generated {len(corruptors)} new corruptors")
                else:
                    if progress_callback:
                        progress_callback.on_completion(len(generated_corruptors))
                    logger.info(f"Corruption agent finished. Total corruptors generated: {len(generated_corruptors)}")

                # Exit after generating corruptor batch
                return None

            case _:
                logger.warning(f"Unknown tool: {tool_response}")
                return None
