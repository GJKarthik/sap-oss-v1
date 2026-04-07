import os
from typing import Any

from openai import AsyncOpenAI

from domain.entities.connector_entity import ConnectorEntity
from domain.entities.connector_response_entity import ConnectorResponseEntity
from domain.ports.connector_port import ConnectorPort
from domain.services.logger import configure_logger

# Initialize a logger for this module
logger = configure_logger(__name__)


class PrivateLLMAdapter(ConnectorPort):

    ERROR_PROCESSING_PROMPT = "[PrivateLLMAdapter] Failed to process prompt."
    ERROR_MISSING_ENDPOINT = (
        "[PrivateLLMAdapter] model_endpoint is required for private_llm_adapter."
    )

    def configure(self, connector_entity: ConnectorEntity):
        """
        Configure a private OpenAI-compatible LLM endpoint.

        Expected auth environment variable precedence:
        1) PRIVATE_LLM_API_KEY
        2) OPENAI_API_KEY
        """
        if not connector_entity.model_endpoint:
            raise ValueError(self.ERROR_MISSING_ENDPOINT)

        self.connector_entity = connector_entity
        api_key = os.getenv("PRIVATE_LLM_API_KEY") or os.getenv("OPENAI_API_KEY") or ""
        self._client = AsyncOpenAI(
            api_key=api_key,
            base_url=self.connector_entity.model_endpoint,
        )

    async def get_response(self, prompt: Any) -> ConnectorResponseEntity:
        """
        Retrieve a response from a private OpenAI-compatible endpoint.
        """
        connector_prompt = f"{self.connector_entity.connector_pre_prompt}{prompt}{self.connector_entity.connector_post_prompt}"  # noqa: E501

        if self.connector_entity.system_prompt:
            request_messages = [
                {"role": "system", "content": self.connector_entity.system_prompt},
                {"role": "user", "content": connector_prompt},
            ]
        else:
            request_messages = [{"role": "user", "content": connector_prompt}]

        new_params = {
            **self.connector_entity.params,
            "model": self.connector_entity.model,
            "messages": request_messages,
        }

        try:
            response = await self._client.chat.completions.create(**new_params)
            return ConnectorResponseEntity(response=await self._process_response(response))
        except Exception as e:
            logger.error(f"{self.ERROR_PROCESSING_PROMPT} {e}")
            raise e

    async def _process_response(self, response: Any) -> str:
        return response.choices[0].message.content
