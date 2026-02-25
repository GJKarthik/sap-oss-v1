"""V1 Check Generation Agent - Simple batch generation without tools."""

from typing import Dict, Optional, Any
from loguru import logger
from definition.base.executable_code import CheckLogic, CheckBatch
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMSessionConfig
from definition.base.prompt_builder import check_generation_prompt_v1
from definition.base.database import Database
import json


class CheckGenerationAgentV1:
    """Agent for generating validation checks using v1 mode (single batch generation)."""

    def __init__(
        self,
        database: Database,
        session_manager: LLMSessionManager,
        config: LLMSessionConfig,
        session_id: Optional[str] = None,
    ):
        """
        Initialize the v1 check generation agent.

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
        self.session_id = session_id or f"{database.database_id}_check_generator_v1"

        # V1 prompt (no tools) - no additional context
        system_message = check_generation_prompt_v1()

        # Update config with system message
        self.config = config.model_copy(update={"system_message": system_message})

        # Register session
        self.session_manager.register_session(self.session_id, self.config)
        logger.debug(f"Initialized CheckGenerationAgentV1 with session {self.session_id}")

    def generate_checks(
        self, user_message: Optional[str] = None, progress_callback: Optional[Any] = None
    ) -> Dict[str, CheckLogic]:
        """
        Generate checks using simple batch generation.

        Parameters
        ----------
        user_message : Optional[str]
            Optional user message for additional context
        progress_callback : Optional[Any]
            Optional callback for progress updates

        Returns
        -------
        Dict[str, CheckLogic]
            Generated validation checks mapped by function name
        """
        logger.info("Generating checks using V1 batch generation")

        if progress_callback:
            progress_callback.on_iteration_start(1)

        try:
            # Get existing rule-based checks to provide context
            existing_checks = self.database.rule_based_checks
            checks_json = json.dumps([check.to_dict() for check in existing_checks.values()], indent=2)

            # Build message with optional user context
            user_context = f"\nUser Context: {user_message}\n" if user_message else ""

            message = f"""
            Here are the existing checks:
            ```json
            {checks_json}
            ```
            {user_context}
            Generate comprehensive checks that capture the important business logic and data quality rules for this database.
            Generate as many checks as you think are necessary to thoroughly validate the data.
            """

            response = self.session_manager.send_message(
                session_id=self.session_id, message=message, response_format=CheckBatch
            )

            checks_list = response.output.checks if hasattr(response.output, "checks") else []

            # Use original names without prefix
            checks = {}
            for check in checks_list:
                check_name = check.function_name
                checks[check_name] = check

            logger.debug(f"Generated {len(checks)} checks")

            if progress_callback:
                progress_callback.on_items_generated("checks", len(checks), list(checks.keys()))
                progress_callback.on_completion(len(checks))

            # Add checks to database
            self.database.add_checks(checks)

            return checks

        except Exception as e:
            logger.error(f"Failed to generate checks: {e}")
            if progress_callback:
                progress_callback.on_error(str(e))
            return {}
