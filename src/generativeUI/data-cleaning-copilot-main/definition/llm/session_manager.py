# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Simple LLM session manager using boto3 Amazon Bedrock for centralized LLM client management."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Type
from pydantic import BaseModel
from loguru import logger
import instructor

# Gen AI Hub imports
from gen_ai_hub.proxy.core.proxy_clients import get_proxy_client
from gen_ai_hub.proxy.native.amazon.clients import Session

from definition.llm.models import LLMSessionConfig, ConversationMessage, MessageRole, LLMResponse, SessionInfo
from definition.llm.exceptions import (
    SessionNotFoundError,
    SessionAlreadyExistsError,
    InvalidConfigurationError,
    StructuredOutputError,
)


class LLMSession:
    """Individual LLM session using boto3 Amazon Bedrock for conversation management."""

    def __init__(self, session_id: str, config: LLMSessionConfig):
        self.session_id = session_id
        self.config = config
        self.created_at = datetime.now().isoformat()
        self.last_activity: Optional[str] = None

        # Simple in-memory conversation history
        self.conversation_history: List[ConversationMessage] = []

        # Initialize bedrock client
        self.bedrock_client = self._create_bedrock_client()

        # Initialize instructor client for all outputs (structured and unstructured)
        # Use BEDROCK_JSON mode for Gen AI Hub
        self.instructor_client = instructor.from_bedrock(self.bedrock_client, mode=instructor.Mode.BEDROCK_JSON)

        logger.debug(f"Initialized LLM session {session_id} with boto3 Bedrock and instructor")

    def _create_bedrock_client(self):
        """Create the boto3 Bedrock client using Gen AI Hub."""
        # Validate required config fields
        if not self.config.base_url:
            raise InvalidConfigurationError("base_url is required in config")
        if not self.config.auth_url:
            raise InvalidConfigurationError("auth_url is required in config")
        if not self.config.client_id:
            raise InvalidConfigurationError("client_id is required in config")
        if not self.config.client_secret:
            raise InvalidConfigurationError("client_secret is required in config")
        if not self.config.model_name:
            raise InvalidConfigurationError("model_name is required in config")

        # Create proxy client for SAP Gen AI Hub
        proxy_kwargs = {
            "base_url": self.config.base_url,
            "auth_url": self.config.auth_url,
            "client_id": self.config.client_id,
            "client_secret": self.config.client_secret,
        }

        if self.config.resource_group:
            proxy_kwargs["resource_group"] = self.config.resource_group

        proxy_client = get_proxy_client(
            proxy_version="gen-ai-hub",
            base_url=self.config.base_url,
            auth_url=self.config.auth_url,
            client_id=self.config.client_id,
            client_secret=self.config.client_secret,
        )

        # Create boto3 bedrock client
        client_kwargs = {"proxy_client": proxy_client, "model_name": self.config.model_name}
        if self.config.deployment_id:
            client_kwargs["deployment_id"] = self.config.deployment_id

        bedrock_client = Session().client(**client_kwargs)

        return bedrock_client

    def _build_instructor_messages(self, include_history: bool = True) -> List[Dict[str, str]]:
        """Build messages in instructor format."""
        messages = []

        if include_history and self.conversation_history:
            for msg in self.conversation_history:
                if msg.role == MessageRole.USER:
                    messages.append({"role": "user", "content": msg.content})
                elif msg.role == MessageRole.ASSISTANT:
                    messages.append({"role": "assistant", "content": msg.content})

        return messages

    def send_message(
        self,
        message: str,
        response_format: Optional[Type[BaseModel]] = None,
        include_history: bool = True,
        record_history: bool = True,
    ) -> LLMResponse:
        """Send a message to the LLM and get a response using instructor.

        Parameters
        ----------
        message : str
            Message to send to the LLM
        response_format : Optional[Type[BaseModel]]
            Expected Pydantic model for structured output
        include_history : bool
            Whether to include conversation history
        """

        # Use the message directly
        input_text = message

        # Build messages for instructor
        messages = self._build_instructor_messages(include_history)
        messages.append({"role": "user", "content": input_text})
        try:
            # Prepare call kwargs for instructor
            call_kwargs = {
                "messages": messages,
                "temperature": self.config.temperature,
                "max_tokens": self.config.max_tokens,
            }

            # Add system message if present - instructor with Bedrock expects it in messages
            if self.config.system_message:
                call_kwargs["system"] = [{"text": self.config.system_message}]

            if response_format is not None:
                logger.debug(f"Using instructor client for structured output: {response_format.__name__}")
                call_kwargs["response_model"] = response_format
                output = self.instructor_client.chat.completions.create(**call_kwargs)

                # For conversation history, convert structured output to JSON string
                response_content = (
                    output.model_dump_json(indent=2) if hasattr(output, "model_dump_json") else str(output)
                )
            else:
                logger.debug("Using bedrock client directly for unstructured output")
                # For unstructured output, use the bedrock client directly
                bedrock_kwargs = {
                    "messages": messages,
                    "temperature": self.config.temperature,
                    "max_tokens": self.config.max_tokens,
                }

                # Add system message if present - Bedrock expects it as a list
                if self.config.system_message:
                    bedrock_kwargs["system"] = [{"text": self.config.system_message}]

                # Use bedrock client directly for unstructured output
                response = self.bedrock_client.converse(modelId=str(self.config.model_name), **bedrock_kwargs)

                # Extract text content from bedrock response
                output = response.get("output", {}).get("message", {}).get("content", [{}])[0].get("text", "")
                response_content = output

        except Exception as e:
            raise StructuredOutputError(f"Instructor API call failed: {e}", raw_output=str(e))

        if record_history:
            self.append_turn(message, response_content)

        return LLMResponse(session_id=self.session_id, output=output)

    def append_turn(self, user_content: str, assistant_content: str) -> None:
        """Append a finalized user/assistant turn to session history."""
        user_message = ConversationMessage(
            role=MessageRole.USER,
            content=user_content,
            timestamp=datetime.now().isoformat(),
        )
        assistant_message = ConversationMessage(
            role=MessageRole.ASSISTANT,
            content=assistant_content,
            timestamp=datetime.now().isoformat(),
        )
        self.conversation_history.append(user_message)
        self.conversation_history.append(assistant_message)
        self.last_activity = datetime.now().isoformat()

    def get_conversation_history(self) -> List[ConversationMessage]:
        """Get conversation history."""
        return self.conversation_history.copy()

    def get_info(self) -> SessionInfo:
        """Get session information."""
        return SessionInfo(
            session_id=self.session_id,
            config=self.config,
            created_at=self.created_at,
            message_count=len(self.conversation_history),
            last_activity=self.last_activity,
        )

    def clear_history(self) -> None:
        """Clear conversation history."""
        self.conversation_history.clear()
        logger.debug(f"Cleared history for session {self.session_id}")


class LLMSessionManager:
    """Central manager for all LLM sessions using boto3 Bedrock."""

    def __init__(self):
        self._sessions: Dict[str, LLMSession] = {}
        logger.debug("Initialized LLMSessionManager with boto3 Bedrock support")

    def register_session(
        self, session_id: Optional[str] = None, config: Optional[LLMSessionConfig] = None, **config_kwargs
    ) -> str:
        """
        Register a new LLM session.

        Parameters
        ----------
        session_id : Optional[str]
            Session ID. If None, a UUID will be generated.
        config : Optional[LLMSessionConfig]
            Session configuration. If None, will be created from config_kwargs.
        **config_kwargs
            Configuration parameters if config is not provided.

        Returns
        -------
        str
            The session ID

        Raises
        ------
        SessionAlreadyExistsError
            If session_id already exists
        InvalidConfigurationError
            If configuration is invalid
        """
        if session_id is None:
            session_id = str(uuid.uuid4())

        if session_id in self._sessions:
            raise SessionAlreadyExistsError(session_id)

        # Create configuration
        if config is None:
            config = LLMSessionConfig(**config_kwargs)

        # Create and register session
        session = LLMSession(session_id, config)
        self._sessions[session_id] = session
        logger.debug(f"Registered new session: {session_id}")
        return session_id

    def send_message(
        self,
        session_id: str,
        message: str,
        response_format: Optional[Type[BaseModel]] = None,
        include_history: bool = True,
        record_history: bool = True,
    ) -> LLMResponse:
        """
        Send a message to a specific session.

        Parameters
        ----------
        session_id : str
            The session ID
        message : str
            Message to send
        response_format : Optional[Type[BaseModel]]
            Expected Pydantic model for structured output
        include_history : bool
            Whether to include conversation history

        Returns
        -------
        LLMResponse
            The LLM response

        Raises
        ------
        SessionNotFoundError
            If session doesn't exist
        """
        if session_id not in self._sessions:
            raise SessionNotFoundError(session_id)

        return self._sessions[session_id].send_message(
            message=message,
            response_format=response_format,
            include_history=include_history,
            record_history=record_history,
        )

    def append_turn(self, session_id: str, user_content: str, assistant_content: str) -> None:
        """Append a finalized conversation turn to an existing session."""
        if session_id not in self._sessions:
            raise SessionNotFoundError(session_id)
        self._sessions[session_id].append_turn(user_content, assistant_content)

    def delete_session(self, session_id: str) -> None:
        """
        Delete a session.

        Parameters
        ----------
        session_id : str
            The session ID to delete

        Raises
        ------
        SessionNotFoundError
            If session doesn't exist
        """
        if session_id not in self._sessions:
            raise SessionNotFoundError(session_id)

        del self._sessions[session_id]
        logger.debug(f"Deleted session: {session_id}")

    def get_session_info(self, session_id: str) -> SessionInfo:
        """
        Get information about a session.

        Parameters
        ----------
        session_id : str
            The session ID

        Returns
        -------
        SessionInfo
            Session information

        Raises
        ------
        SessionNotFoundError
            If session doesn't exist
        """
        if session_id not in self._sessions:
            raise SessionNotFoundError(session_id)

        return self._sessions[session_id].get_info()

    def list_sessions(self) -> List[SessionInfo]:
        """List all active sessions."""
        return [session.get_info() for session in self._sessions.values()]

    def clear_session_history(self, session_id: str) -> None:
        """
        Clear conversation history for a session.

        Parameters
        ----------
        session_id : str
            The session ID

        Raises
        ------
        SessionNotFoundError
            If session doesn't exist
        """
        if session_id not in self._sessions:
            raise SessionNotFoundError(session_id)

        self._sessions[session_id].clear_history()

    def cleanup_sessions(self, max_age_hours: int = 24) -> int:
        """
        Clean up old sessions based on last activity.

        Parameters
        ----------
        max_age_hours : int
            Maximum age in hours before a session is considered stale

        Returns
        -------
        int
            Number of sessions cleaned up
        """
        cutoff_time = datetime.now() - timedelta(hours=max_age_hours)
        sessions_to_remove: List[str] = []

        for session_id, session in self._sessions.items():
            if session.last_activity is not None:
                last_activity = datetime.fromisoformat(session.last_activity)
                if last_activity < cutoff_time:
                    sessions_to_remove.append(session_id)
            else:
                # No activity recorded, check creation time
                created_at = datetime.fromisoformat(session.created_at)
                if created_at < cutoff_time:
                    sessions_to_remove.append(session_id)

        for session_id in sessions_to_remove:
            del self._sessions[session_id]

        logger.debug(f"Cleaned up {len(sessions_to_remove)} stale sessions")
        return len(sessions_to_remove)

    def get_session(self, session_id: str) -> Optional[LLMSession]:
        """
        Get a session object (for advanced use cases).

        Parameters
        ----------
        session_id : str
            The session ID

        Returns
        -------
        Optional[LLMSession]
            The session object or None if not found
        """
        return self._sessions.get(session_id)
