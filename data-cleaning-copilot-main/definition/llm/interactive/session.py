# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Interactive session for user-in-the-loop database workflows."""

import uuid
from typing import Optional, Dict, Any, List
from loguru import logger
import gradio as gr
import json
from definition.base.database import (
    Database,
    MultipleDatabaseCalls,
    DatabaseFunctionCall,
    ValidateDatabase,
    Corrupt,
    ListChecks,
    ListCorruptors,
    GetValidationResult,
    ExportValidationResult,
    Evaluate,
    ListTableSchemas,
    GetTableData,
    GetCheck,
    GetTableColumnSchema,
    # V3 specific tools
    GetTableSchema,
    ListValidationResults,
    AddChecks,
    GenerationFinished,
)
from definition.agents.agent_models import CheckGenerationV1, CheckGenerationV2, CheckGenerationV3, CorruptionGeneration
from definition.base.util_toolcalls import extract_tool_descriptions
from definition.base.prompt_builder import session_prompt
from typing import Union
from pydantic import BaseModel, Field

# CheckLogic and CorruptionLogic are imported but only used for type checking
from definition.base.executable_code import CheckLogic, CorruptionLogic  # noqa: F401
import pandas as pd
from definition.llm.models import LLMSessionConfig, LLMResponse
from definition.llm.session_manager import LLMSessionManager

# Create union of all interactive session function calls
InteractiveFunctionCall = Union[
    ValidateDatabase,
    Corrupt,
    ListChecks,
    ListCorruptors,
    GetValidationResult,
    ExportValidationResult,
    Evaluate,
    ListTableSchemas,
    GetTableData,
    GetCheck,
    GetTableColumnSchema,
    # V3 specific tools
    GetTableSchema,
    ListValidationResults,
    GenerationFinished,
    # Agent calls
    CheckGenerationV1,
    CheckGenerationV2,
    CheckGenerationV3,
]


class MultipleInteractiveCalls(BaseModel):
    """Container for multiple interactive function calls."""

    calls: List[InteractiveFunctionCall] = Field(description="List of function calls to execute")


class InteractiveSession:
    """
    Browser-based interactive session for database workflows with LLM tool calling.
    """

    def __init__(
        self,
        database: Database,
        session_manager: LLMSessionManager,
        config: LLMSessionConfig,
        session_id: Optional[str] = None,
        agent_config: Optional[LLMSessionConfig] = None,
    ):
        """
        Initialize interactive session with LLM integration.

        Parameters
        ----------
        database : Database
            The database instance to interact with
        session_manager : LLMSessionManager
            Manager for LLM sessions
        config : LLMSessionConfig
            LLM configuration for the session
        session_id : Optional[str]
            Session ID to use. If None, generates one.
        agent_config : Optional[LLMSessionConfig]
            Optional separate configuration for agents. If None, uses session config.
        """
        self.database = database
        self.session_manager = session_manager
        self.session_id = session_id or f"interactive_{uuid.uuid4().hex[:8]}"
        # Use separate config for agents if provided, otherwise use session config
        self.agent_config = agent_config or config

        # Generate system message using prompt builder
        tool_descriptions = extract_tool_descriptions(InteractiveFunctionCall)
        system_message = session_prompt(tool_descriptions)

        # Update config with system message
        self.config = config.model_copy(update={"system_message": system_message})

        # Register session if it doesn't exist
        if self.session_manager.get_session(self.session_id) is None:
            self.session_manager.register_session(self.session_id, self.config)
            logger.debug(f"Registered new session {self.session_id} for database {database.database_id}")
        else:
            logger.debug(f"Using existing session {self.session_id} for database {database.database_id}")

    def start(self, share: bool = False, port: int = 7860) -> None:
        """
        Launch browser-based GUI using Gradio.

        Parameters
        ----------
        share : bool
            Whether to create a public shareable link
        port : int
            Port to run the interface on
        """
        logger.info(f"Launching Gradio interface on port {port}")

        # Custom CSS for scrollable areas
        custom_css = """
        #agent-progress-display {
            height: 160px;
            overflow-y: auto;
            padding: 10px;
            background-color: #f8f9fa;
            border: 1px solid #dee2e6;
            border-radius: 5px;
            font-size: 0.9em;
            line-height: 1.4;
        }
        .generated-checks-display {
            overflow-y: auto !important;
            padding-right: 10px;
        }
        .generated-checks-display h3 {
            margin-top: 0.5em;
            margin-bottom: 0.5em;
        }
        .generated-checks-display details {
            margin-bottom: 0.5em;
        }
        .generated-checks-display::-webkit-scrollbar,
        #agent-progress-display::-webkit-scrollbar {
            width: 8px;
        }
        .generated-checks-display::-webkit-scrollbar-track,
        #agent-progress-display::-webkit-scrollbar-track {
            background: #f1f1f1;
            border-radius: 4px;
        }
        .generated-checks-display::-webkit-scrollbar-thumb,
        #agent-progress-display::-webkit-scrollbar-thumb {
            background: #888;
            border-radius: 4px;
        }
        .generated-checks-display::-webkit-scrollbar-thumb:hover,
        #agent-progress-display::-webkit-scrollbar-thumb:hover {
            background: #555;
        }
        """

        with gr.Blocks(title="Database Interactive Session", css=custom_css) as interface:
            gr.Markdown(
                f"# Database Interactive Session\n**Database:** {self.database.database_id}\n**Session:** {self.session_id}"
            )

            with gr.Row():
                with gr.Column(scale=2):
                    chatbot = gr.Chatbot(
                        height=500,
                        label="Chat",
                        elem_classes="markdown-chatbot",
                        show_copy_button=True,
                        render_markdown=True,
                        type="messages",  # Use OpenAI-style messages format
                    )

                    with gr.Row():
                        with gr.Column(scale=3):
                            msg = gr.Textbox(
                                label="Your message",
                                placeholder="Ask about data quality, generate checks, create corruptions, or query the database...",
                                lines=2,
                            )
                        with gr.Column(scale=1):
                            agent_progress = gr.Markdown(
                                value="*No agent activity*", label="Agent Progress", elem_id="agent-progress-display"
                            )

                    with gr.Row():
                        submit = gr.Button("Submit", variant="primary")
                        clear = gr.Button("Clear")

                with gr.Column(scale=1):
                    # LLM Generated Checks
                    gr.Markdown("### LLM Generated Checks")
                    with gr.Tabs():
                        with gr.Tab("Generated Checks"):
                            with gr.Group():
                                generated_checks_display = gr.Markdown(
                                    value=self._format_generated_checks(),
                                    label="LLM Generated Checks",
                                    elem_classes="generated-checks-display",
                                    height=550,  # Fixed height with automatic scrolling
                                    container=True,
                                    show_copy_button=True,
                                )
                                refresh_checks = gr.Button("Refresh Checks", size="sm")

                        with gr.Tab("Check History"):
                            check_session_display = gr.JSON(label="Check Generation History", value=[], height=250)
                            refresh_check_session = gr.Button("Refresh History", size="sm")

                        with gr.Tab("Main Session"):
                            session_display = gr.JSON(label="Session Messages", value=[], height=250)
                            clear_session = gr.Button("Clear Session Data", size="sm")

                    # Session Configuration Tabs
                    gr.Markdown("### Session Configuration")
                    with gr.Tabs():
                        with gr.Tab("Main Config"):
                            main_config_display = gr.JSON(
                                label="Main Session Configuration",
                                value=self._get_session_config(self.session_id),
                                height=200,
                            )
                            refresh_main_config = gr.Button("Refresh Config", size="sm")

                        with gr.Tab("Check Gen Config"):
                            check_config_display = gr.JSON(
                                label="Check Generation Configuration",
                                value=self._get_session_config(self.database.check_generator_session_id),
                                height=200,
                            )
                            refresh_check_config = gr.Button("Refresh Config", size="sm")

            # Store current progress collector at instance level
            self.current_progress_collector = None

            def update_progress_display():
                """Periodic update function for progress display."""
                if self.current_progress_collector:
                    return self.current_progress_collector.get_formatted_progress()
                return gr.update()  # No update if no collector

            def refresh_generated_checks():
                return self._format_generated_checks()

            def refresh_check_history():
                return self._get_session_history(self.database.check_generator_session_id, limit=5)

            def refresh_main_configuration():
                return self._get_session_config(self.session_id)

            def refresh_check_configuration():
                return self._get_session_config(self.database.check_generator_session_id)

            def clear_chat():
                # Clear session history in session manager
                self.session_manager.clear_session_history(self.session_id)
                return None, []  # Return empty list for messages format

            def clear_session_data():
                return []

            # Use Gradio's native bot response with thinking animation
            def user_message(message, history):
                """Add user message to chat."""
                if not message:
                    return "", history
                return "", history + [{"role": "user", "content": message}]

            def bot_response(history, session_data, check_data, generated_checks):
                """Generate bot response with thinking animation."""
                if not history or history[-1]["role"] != "user":
                    yield history, session_data, check_data, generated_checks
                    return

                user_msg = history[-1]["content"]

                # Process the request
                response = self.process_request(user_msg)

                # Add the response
                history = history + [{"role": "assistant", "content": response}]

                # Update session displays
                updated_session = self._get_session_history(self.session_id, limit=10)
                updated_check = self._get_session_history(self.database.check_generator_session_id, limit=5)
                updated_generated = self._format_generated_checks()

                yield history, updated_session, updated_check, updated_generated

            # Chain user message and bot response with proper bot status
            msg.submit(user_message, [msg, chatbot], [msg, chatbot], queue=False).then(
                bot_response,
                [chatbot, session_display, check_session_display, generated_checks_display],
                [chatbot, session_display, check_session_display, generated_checks_display],
                show_progress="full",  # This enables the spinner and timer
            )

            submit.click(user_message, [msg, chatbot], [msg, chatbot], queue=False).then(
                bot_response,
                [chatbot, session_display, check_session_display, generated_checks_display],
                [chatbot, session_display, check_session_display, generated_checks_display],
                show_progress="full",  # This enables the spinner and timer
            )

            # Set up periodic progress updates using Gradio Timer
            # This will update the progress display every 100ms
            timer = gr.Timer(1, active=True)
            timer.tick(fn=update_progress_display, inputs=None, outputs=agent_progress)
            clear.click(clear_chat, None, [chatbot, session_display])
            clear_session.click(clear_session_data, None, session_display)
            refresh_check_session.click(refresh_check_history, None, check_session_display)
            refresh_checks.click(refresh_generated_checks, None, generated_checks_display)
            refresh_main_config.click(refresh_main_configuration, None, main_config_display)
            refresh_check_config.click(refresh_check_configuration, None, check_config_display)

        interface.queue().launch(share=share, server_port=port)

    def _format_generated_checks(self) -> str:
        """
        Format LLM-generated checks for display in markdown.

        Returns
        -------
        str
            Formatted markdown string with all generated checks
        """
        generated_checks = self.database.generated_checks

        if not generated_checks:
            return "*No LLM-generated checks yet. Use agent_check_generation to generate checks.*"

        output = []
        for i, (check_name, check) in enumerate(generated_checks.items(), 1):
            # Remove llm_ prefix for display
            display_name = check_name[4:] if check_name.startswith("llm_") else check_name

            output.append(f"### {i}. `{display_name}`\n")
            output.append(f"**Description:** {check.description}\n")
            output.append(f"**Scope:** `{check.scope}`\n")
            output.append("\n<details>\n<summary><b>View Code</b></summary>\n\n")
            output.append(f"```python\n{check.to_code()}\n```\n")
            output.append("</details>\n\n")
            output.append("---\n\n")

        # Remove last separator
        if output and output[-1] == "---\n\n":
            output.pop()

        return "".join(output)

    def _get_session_history(self, session_id: str, limit: int = 10) -> List[Dict[str, Any]]:
        """
        Get formatted session history for display.

        Parameters
        ----------
        session_id : str
            Session ID to get history for
        limit : int
            Maximum number of messages to return

        Returns
        -------
        List[Dict[str, Any]]
            Formatted session history
        """
        try:
            session = self.session_manager.get_session(session_id)
            if not session:
                return []

            history = session.get_conversation_history()
            formatted_history = []

            for msg in history[-limit:]:
                formatted_msg = {"timestamp": msg.timestamp, "role": msg.role.value, "content": msg.content}
                formatted_history.append(formatted_msg)

            return formatted_history
        except Exception as e:
            logger.debug(f"Could not get history for session {session_id}: {e}")
            return []

    def _get_session_config(self, session_id: str) -> Dict[str, Any]:
        """
        Get formatted session configuration for display.

        Parameters
        ----------
        session_id : str
            Session ID to get configuration for

        Returns
        -------
        Dict[str, Any]
            Formatted session configuration
        """
        try:
            session = self.session_manager.get_session(session_id)
            if not session:
                return {"error": "Session not found"}

            config = session.config
            formatted_config = {
                "session_id": session_id,
                "model_name": config.model_name,
                "temperature": config.temperature,
                "max_tokens": config.max_tokens,
                "deployment_id": config.deployment_id if hasattr(config, "deployment_id") else None,
                "resource_group": config.resource_group if hasattr(config, "resource_group") else None,
                "system_message": config.system_message,  # Full system message without truncation
            }

            # Remove None values for cleaner display
            formatted_config = {k: v for k, v in formatted_config.items() if v is not None}

            return formatted_config
        except Exception as e:
            logger.debug(f"Could not get config for session {session_id}: {e}")
            return {"error": str(e)}

    def process_request(self, user_input: str) -> str:
        """
        Process user request through LLM with tool calling.

        Parameters
        ----------
        user_input : str
            Natural language request from user

        Returns
        -------
        str
            Response to user
        """
        try:
            # Send message to LLM with structured output format for tool calling
            logger.debug(f"Sending message to LLM session {self.session_id} with tool calling")
            llm_response = self.session_manager.send_message(
                message=user_input, session_id=self.session_id, response_format=MultipleInteractiveCalls
            )

            # Process the response
            response_text = self._handle_llm_response(llm_response)
            return response_text

        except Exception as e:
            logger.error(f"Error processing request with structured output: {e}")
            logger.error(f"Full error details: {type(e).__name__}: {str(e)}")
            import traceback

            logger.error(f"Traceback:\n{traceback.format_exc()}")
            return f"Error: {str(e)}"

    def _format_dataframe_for_display(self, df: pd.DataFrame, max_rows: int = 10) -> str:
        """Format a DataFrame for display in Gradio markdown."""
        # Use len() instead of .empty to avoid NA ambiguity
        if len(df) == 0:
            return "_No data_"
        return f"```\n{df.head(max_rows).to_markdown(index=False)}\n```"

    def _format_json_for_display(self, data: dict) -> str:
        """Format JSON data for display with proper markdown code blocks."""
        # Use default=str to handle Timestamp and other non-serializable objects
        return f"```json\n{json.dumps(data, indent=2, default=str)}\n```\n"

    def _execute_function_calls(self, calls_container, progress_callback=None):
        """Execute function calls directly."""
        results = []

        for call in calls_container.calls:
            result = self._execute_single_call(call, progress_callback)
            results.append((call, result))

        return results

    def _execute_single_call(self, call, progress_callback=None):
        """Execute a single function call."""
        import random

        match call:
            # Agent calls
            case CheckGenerationV1():
                from definition.agents.check_generation_agent_v1 import CheckGenerationAgentV1

                agent = CheckGenerationAgentV1(self.database, self.session_manager, self.agent_config)
                return agent.generate_checks(user_message=call.user_message, progress_callback=progress_callback)

            case CheckGenerationV2():
                from definition.agents.check_generation_agent_v2 import CheckGenerationAgentV2

                agent = CheckGenerationAgentV2(self.database, self.session_manager, self.agent_config)
                return agent.generate_checks(
                    user_message=call.user_message,
                    max_iterations=call.max_iterations,
                    progress_callback=progress_callback,
                )

            case CheckGenerationV3():
                from definition.agents.check_generation_agent_v3 import CheckGenerationAgentV3

                agent = CheckGenerationAgentV3(self.database, self.session_manager, self.agent_config)
                return agent.generate_checks(
                    user_message=call.user_message,
                    max_iterations=call.max_iterations,
                    progress_callback=progress_callback,
                )

            case CorruptionGeneration():
                from definition.agents.corruption_generation_agent import CorruptionGenerationAgent

                agent = CorruptionGenerationAgent(self.database, self.session_manager, self.agent_config)
                return agent.generate_corruptions(user_message=call.user_message, progress_callback=progress_callback)

            # Database function calls
            case ValidateDatabase():
                return self.database.validate()

            case Corrupt(corruptor_name=name, percentage=pct, rand_seed=rand_seed):
                rand = random.Random(rand_seed) if rand_seed is not None else None
                return self.database.corrupt(corruptor_name=name, percentage=pct, rand=rand)

            case ListChecks():
                checks_mapping = self.database.list_checks()
                return {name: check.to_dict() for name, check in checks_mapping.items()}

            case ListCorruptors():
                corruptors_mapping = self.database.list_corruptors()
                return {name: corruptor.to_dict() for name, corruptor in corruptors_mapping.items()}

            case GetValidationResult(check_name=name):
                result = self.database.check_result_store.get_result(name)
                return result if result is not None else pd.DataFrame()

            case ExportValidationResult(directory=directory, override_existing_files=override):
                self.database.export_validation_result(directory, override)
                return None

            case Evaluate(ground_truth_file=ground_truth_file):
                return self.database.evaluate(ground_truth_file)

            case ListTableSchemas():
                return self.database.list_table_schemas()

            case GetTableData(table_name=table_name):
                return self.database.get_table_data(table_name)

            case GetCheck(check_name=check_name):
                return self.database.get_check(check_name)

            case GetTableColumnSchema(table_name=table_name, column_name=column_name):
                return self.database.get_table_column_schema(table_name, column_name)

            case GetTableSchema(table_name=table_name):
                return self.database.get_table_schema(table_name)

            case ListValidationResults(include_empty=include_empty):
                return self.database.list_validation_results(include_empty=include_empty)

            case _:
                logger.warning(f"Unknown function call: {call}")
                return None

    def _build_function_call_header(self, function_name: str, **kwargs) -> str:
        """Build a formatted header for function call display."""
        header = f"### Function Call: `{function_name}`\n\n"
        if kwargs:
            header += "**Parameters:**\n" + "".join(
                f"- **{key}**: `{value}`\n" for key, value in kwargs.items() if value is not None
            )
        else:
            header += "**Parameters:** _None_\n"
        return header + "\n"

    def _handle_llm_response(self, response: LLMResponse) -> str:
        """
        Handle LLM response and execute function calls if present.

        Parameters
        ----------
        response : LLMResponse
            Response from LLM

        Returns
        -------
        str
            Response text or function execution results
        """
        # Normalize all outputs to MultipleInteractiveCalls
        if not isinstance(response.output, MultipleInteractiveCalls):
            if isinstance(response.output, MultipleDatabaseCalls):
                response.output = MultipleInteractiveCalls(calls=response.output.calls)
            else:
                # Wrap single call in a list
                response.output = MultipleInteractiveCalls(calls=[response.output])

        if isinstance(response.output, MultipleInteractiveCalls):
            # Setup progress tracking for agent operations if needed
            from definition.llm.interactive.streaming_progress import StreamingProgressCollector

            agent_call_types = (CheckGenerationV1, CheckGenerationV2, CheckGenerationV3, CorruptionGeneration)
            has_agent_call = any(isinstance(call, agent_call_types) for call in response.output.calls)

            self.current_progress_collector = StreamingProgressCollector() if has_agent_call else None
            progress_callback = self.current_progress_collector

            # Execute the function calls
            try:
                logger.debug("Executing function calls")
                results = self._execute_function_calls(response.output, progress_callback=progress_callback)

                # Build formatted markdown response
                output_parts = []

                for call, result in results:
                    match call:
                        case ValidateDatabase():
                            output_parts.append(self._build_function_call_header("validate"))

                            violations_dict = {k: v for k, v in result.items() if isinstance(v, pd.DataFrame)}
                            exceptions_dict = {k: v for k, v in result.items() if isinstance(v, Exception)}

                            # Calculate total violations across all checks
                            total_violations = sum(len(df) for df in violations_dict.values())

                            output_parts.append("### Database Validation Results\n")
                            output_parts.append(
                                f"**Status:** Found **{total_violations}** validation violations across {len(violations_dict)} checks\n"
                            )

                            if exceptions_dict:
                                output_parts.append(
                                    f"**Errors:** {len(exceptions_dict)} checks failed with exceptions\n"
                                )

                            output_parts.append("\n")

                            if violations_dict:  # If there are any violations
                                output_parts.append("**Violations by check:**\n\n")

                                for check_name, violations_df in violations_dict.items():
                                    if isinstance(violations_df, pd.DataFrame) and len(violations_df) > 0:
                                        output_parts.append(f"#### Check: `{check_name}`\n")
                                        output_parts.append(f"- **Total violations:** {len(violations_df)}\n")

                                        # Show first 5 samples for each check
                                        sample_df = violations_df.head(5)
                                        output_parts.append("- **Sample violations (first 5):**\n\n")
                                        output_parts.append(self._format_dataframe_for_display(sample_df))
                                        output_parts.append("\n")

                            if exceptions_dict:  # If there are any exceptions
                                output_parts.append("**Failed checks:**\n\n")
                                for check_name, exc in exceptions_dict.items():
                                    output_parts.append(f"- `{check_name}`: {type(exc).__name__} - {str(exc)[:100]}\n")
                                output_parts.append("\n")

                            if not violations_dict and not exceptions_dict:
                                output_parts.append("**All validation checks passed!**\n")

                        case Corrupt(corruptor_name=corruptor_name, percentage=percentage, rand_seed=rand_seed):
                            output_parts.append(
                                self._build_function_call_header(
                                    "corrupt_table",
                                    corruptor_name=corruptor_name,
                                    percentage=percentage,
                                    rand_seed=rand_seed,
                                )
                            )

                            output_parts.append(f"### Corruption Applied: `{corruptor_name}`\n")
                            output_parts.append(f"**Percentage:** {percentage * 100:.1f}%\n")
                            output_parts.append(f"**Tables Affected:** {len(result)} tables returned\n\n")

                            # Show which tables were potentially modified
                            table_summaries = []
                            for table_name, table_df in result.items():
                                if isinstance(table_df, pd.DataFrame):
                                    table_summaries.append(
                                        f"- **{table_name}**: {len(table_df)} rows, {len(table_df.columns)} columns"
                                    )

                            if table_summaries:
                                output_parts.append("**Table Summary:**\n")
                                output_parts.extend([s + "\n" for s in table_summaries])
                                output_parts.append("\n")

                            # Note about corruption
                            output_parts.append(
                                "*Note: Corruption has been applied based on the corruptor's logic. "
                                "Run validation to see which values were corrupted.*\n"
                            )

                        case CheckGenerationV1() | CheckGenerationV2() | CheckGenerationV3():
                            if isinstance(call, CheckGenerationV1):
                                function_type = "check_generation_v1"
                                params = {"user_message": call.user_message, "force_regenerate": call.force_regenerate}
                            elif isinstance(call, CheckGenerationV2):
                                function_type = "check_generation_v2"
                                params = {
                                    "user_message": call.user_message,
                                    "max_iterations": call.max_iterations,
                                    "force_regenerate": call.force_regenerate,
                                }
                            else:
                                function_type = "check_generation_v3"
                                params = {
                                    "user_message": call.user_message,
                                    "max_iterations": call.max_iterations,
                                    "force_regenerate": call.force_regenerate,
                                }

                            output_parts.append(self._build_function_call_header(function_type, **params))

                            # Result is a Dict[str, CheckLogic]
                            output_parts.append(f"### Generated {len(result)} Validation Checks\n\n")

                            for check_name, check in result.items():
                                output_parts.append(f"**{check.function_name}**\n")
                                output_parts.append(f"- Description: {check.description}\n")
                                output_parts.append(f"- Scope: {check.scope}\n")

                                # Show code snippet
                                output_parts.append("\n<details>\n<summary>View Code</summary>\n\n")
                                output_parts.append(f"```python\n{check.to_code()}\n```\n")
                                output_parts.append("</details>\n\n")

                            output_parts.append(
                                "\n*Checks have been added to the database. Use `validate` to run them.*\n"
                            )

                        case CorruptionGeneration():
                            output_parts.append(
                                self._build_function_call_header(
                                    "corruption_generation",
                                    user_message=call.user_message,
                                    num_iterations=call.num_iterations,
                                    force_regenerate=call.force_regenerate,
                                )
                            )

                            # Result is a dict of corruptor_name -> CorruptionLogic
                            output_parts.append(f"### Generated {len(result)} Corruption Strategies\n\n")
                            for corruptor_name, corruptor in result.items():
                                output_parts.append(f"**{corruptor.function_name}**\n")
                                output_parts.append(f"- Description: {corruptor.description}\n")
                                output_parts.append(f"- Scope: {corruptor.scope}\n")
                                # Show code snippet
                                output_parts.append("\n<details>\n<summary>View Code</summary>\n\n")
                                output_parts.append(f"```python\n{corruptor.to_code()}\n```\n")
                                output_parts.append("</details>\n\n")

                            output_parts.append(
                                "\n*Corruptors have been added to the database. Use `corrupt_table` to apply them.*\n"
                            )

                        case ListChecks():
                            logger.debug(
                                f"Processing ListChecks result: type={type(result)}, len={len(result) if isinstance(result, dict) else 'N/A'}"
                            )
                            output_parts.append(self._build_function_call_header("list_checks"))

                            output_parts.append(f"### Check Details ({len(result)} checks)\n")
                            if result:  # Checks were found
                                for check_name, check in result.items():
                                    # Convert CheckLogic to dict
                                    if hasattr(check, "to_dict"):
                                        check_dict = check.to_dict()
                                    elif isinstance(check, dict):
                                        check_dict = check
                                    else:
                                        check_dict = {"check": str(check)}
                                    output_parts.append(f"\n**{check_name}:**\n")
                                    output_parts.append(self._format_json_for_display(check_dict))
                            else:
                                output_parts.append("⚠️ No checks available.\n")

                        case ListCorruptors():
                            output_parts.append(self._build_function_call_header("list_corruptors"))

                            output_parts.append(f"### Corruptor Details ({len(result)} corruptors)\n")
                            if result:  # Corruptors were found
                                for corruptor_name, corruptor in result.items():
                                    # Convert CorruptionLogic to dict
                                    if hasattr(corruptor, "to_dict"):
                                        corruptor_dict = corruptor.to_dict()
                                    elif isinstance(corruptor, dict):
                                        corruptor_dict = corruptor
                                    else:
                                        corruptor_dict = {"corruptor": str(corruptor)}
                                    output_parts.append(f"\n**{corruptor_name}:**\n")
                                    output_parts.append(self._format_json_for_display(corruptor_dict))
                            else:
                                output_parts.append("⚠️ No corruptors available.\n")

                        case GetValidationResult(check_name=check_name):
                            output_parts.append(
                                self._build_function_call_header("get_validation_result", check_name=check_name)
                            )

                            output_parts.append(f"### Validation Results for: `{check_name}`\n")
                            if isinstance(result, pd.DataFrame) and len(result) > 0:
                                output_parts.append(f"**Found {len(result)} violations:**\n\n")
                                # Show first 10 violations
                                sample = result.head(10)
                                output_parts.append(self._format_dataframe_for_display(sample))
                                if len(result) > 10:
                                    output_parts.append(f"\n*... and {len(result) - 10} more violations*\n")

                        case ExportValidationResult(directory=directory, override_existing_files=override):
                            output_parts.append(
                                self._build_function_call_header(
                                    "export_validation_result", directory=directory, override_existing_files=override
                                )
                            )

                            # Result is None since the function saves to file
                            output_parts.append("### Validation Results Exported\n")
                            output_parts.append(f"**Directory:** `{directory}`\n")
                            output_parts.append(f"**File:** `{directory}/violations.csv`\n")
                            output_parts.append(f"**Override existing:** {override}\n\n")
                            output_parts.append(
                                "*All validation violations have been concatenated and saved to the CSV file.*\n"
                            )

                        case Evaluate(ground_truth_file=ground_truth_file):
                            output_parts.append(
                                self._build_function_call_header("evaluate", ground_truth_file=ground_truth_file)
                            )

                            output_parts.append("### Evaluation Report\n")
                            output_parts.append(f"**Ground Truth File:** `{ground_truth_file}`\n\n")

                            # Display the evaluation report
                            output_parts.append(self._format_dataframe_for_display(result, max_rows=20))

                            # Highlight overall metrics if available
                            overall_metrics = result[result["check_name"] == "OVERALL"]
                            if len(overall_metrics) > 0:
                                overall = overall_metrics.iloc[0]
                                output_parts.append("\n### Overall Performance\n")
                                output_parts.append(f"- **Precision:** {overall['precision']:.4f}\n")
                                output_parts.append(f"- **Recall:** {overall['recall']:.4f}\n")
                                output_parts.append(f"- **F1 Score:** {overall['f1_score']:.4f}\n")
                                output_parts.append(f"- **True Positives:** {overall['true_positives']}\n")
                                output_parts.append(f"- **False Positives:** {overall['false_positives']}\n")
                                output_parts.append(f"- **False Negatives:** {overall['false_negatives']}\n")

                        case ListTableSchemas():
                            output_parts.append(self._build_function_call_header("list_table_schemas"))
                            output_parts.append(f"### Table Schemas ({len(result)} tables)\n\n")
                            # Convert each schema to JSON format
                            schemas_json = {}
                            for table_name, schema in result.items():
                                if hasattr(schema, "model_dump"):
                                    schemas_json[table_name] = schema.model_dump()
                                elif hasattr(schema, "dict"):
                                    schemas_json[table_name] = schema.dict()
                                else:
                                    schemas_json[table_name] = str(schema)

                            # Display as formatted JSON without truncation
                            output_parts.append(self._format_json_for_display(schemas_json))

                        case GetTableData(table_name=table_name):
                            output_parts.append(
                                self._build_function_call_header("get_table_data", table_name=table_name)
                            )

                            output_parts.append(f"### Table Data: `{table_name}`\n\n")

                            if isinstance(result, pd.DataFrame):
                                # Use len() instead of .empty to avoid NA ambiguity
                                if len(result) > 0:
                                    output_parts.append(
                                        f"**Shape:** {result.shape[0]} rows × {result.shape[1]} columns\n\n"
                                    )
                                    # Display the actual data using markdown table
                                    output_parts.append(self._format_dataframe_for_display(result, max_rows=20))
                                else:
                                    output_parts.append("*Table is empty (0 rows)*\n")
                            else:
                                output_parts.append("*No data available*\n")

                        case GetCheck(check_name=check_name):
                            output_parts.append(self._build_function_call_header("get_check", check_name=check_name))

                            if result:
                                output_parts.append(f"### Check: `{check_name}`\n\n")
                                # Convert CheckLogic to dict for display
                                if hasattr(result, "to_dict"):
                                    check_dict = result.to_dict()
                                    output_parts.append(self._format_json_for_display(check_dict))

                                    # Show code
                                    if hasattr(result, "to_code"):
                                        output_parts.append("\n**Code:**\n")
                                        output_parts.append(f"```python\n{result.to_code()}\n```\n")
                            else:
                                output_parts.append("### Check Not Found\n")
                                output_parts.append(f"Check `{check_name}` does not exist in the database.\n")

                        case GetTableColumnSchema(table_name=table_name, column_name=column_name):
                            output_parts.append(
                                self._build_function_call_header(
                                    "get_table_column_schema", table_name=table_name, column_name=column_name
                                )
                            )

                            if result is not None:
                                output_parts.append(f"### Column Schema: `{table_name}.{column_name}`\n\n")
                                # result might be a dict or an object with model_dump
                                if isinstance(result, dict):
                                    output_parts.append(self._format_json_for_display(result))
                                elif hasattr(result, "model_dump"):
                                    schema_dict = result.model_dump()
                                    output_parts.append(self._format_json_for_display(schema_dict))
                                else:
                                    output_parts.append(f"```\n{result}\n```\n")
                            else:
                                output_parts.append("### Column Not Found\n")
                                output_parts.append(f"Column `{table_name}.{column_name}` does not exist.\n")

                        case GetTableSchema(table_name=table_name):
                            output_parts.append(
                                self._build_function_call_header("get_table_schema", table_name=table_name)
                            )

                            if result is not None:
                                output_parts.append(f"### Table Schema: `{table_name}`\n\n")
                                # result is already a dict from get_table_schema
                                if isinstance(result, dict):
                                    output_parts.append(self._format_json_for_display(result))
                                elif hasattr(result, "model_dump"):
                                    schema_dict = result.model_dump()
                                    output_parts.append(self._format_json_for_display(schema_dict))
                                else:
                                    output_parts.append(f"Schema type: {type(result)}\n")
                                    output_parts.append(f"```\n{result}\n```\n")
                            else:
                                output_parts.append("### Table Not Found\n")
                                output_parts.append(f"Table `{table_name}` does not exist.\n")

                        case ListValidationResults(include_empty=include_empty):
                            output_parts.append(
                                self._build_function_call_header("list_validation_results", include_empty=include_empty)
                            )

                            output_parts.append("### Validation Results Summary\n\n")
                            if result:
                                output_parts.append("**Check Results:**\n\n")
                                for check_name, violations_df in result.items():
                                    violation_count = (
                                        len(violations_df) if isinstance(violations_df, pd.DataFrame) else 0
                                    )
                                    status = (
                                        "✅ PASSED"
                                        if violation_count == 0
                                        else f"❌ FAILED ({violation_count} violations)"
                                    )
                                    output_parts.append(f"- `{check_name}`: {status}\n")
                            else:
                                output_parts.append("No validation results available.\n")

                    output_parts.append("\n---\n")  # Add separator between function calls

                # Remove last separator
                if output_parts and output_parts[-1] == "\n---\n":
                    output_parts.pop()

                return "".join(output_parts)

            except Exception as e:
                logger.error(f"Error executing function calls: {e}")
                return f"**Error executing function calls:** {str(e)}"

        # Handle regular text response
        elif isinstance(response.output, str):
            return response.output
        elif hasattr(response.output, "model_dump_json"):
            return self._format_json_for_display(response.output.model_dump())
        else:
            return str(response.output)
