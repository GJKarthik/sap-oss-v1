import os
from typing import Any

from openai import AsyncOpenAI

from domain.entities.connector_entity import ConnectorEntity
from domain.entities.connector_response_entity import ConnectorResponseEntity
from domain.ports.connector_port import ConnectorPort
from domain.services.logger import configure_logger

# Initialize a logger for this module
logger = configure_logger(__name__)


class AICoreAdapter(ConnectorPort):

    ERROR_PROCESSING_PROMPT = "[AICoreAdapter] Failed to process prompt."
    ERROR_MISSING_ENDPOINT = (
        "[AICoreAdapter] model_endpoint is required for ai_core_adapter."
    )

    def configure(self, connector_entity: ConnectorEntity):
        """
        Configure the SAP AI Core OpenAI-compatible endpoint.

        Expected auth environment variable precedence:
        1) AICORE_AUTH_TOKEN
        2) AICORE_API_KEY
        3) OPENAI_API_KEY
        """
        if not connector_entity.model_endpoint:
            raise ValueError(self.ERROR_MISSING_ENDPOINT)

        self.connector_entity = connector_entity
        api_key = (
            os.getenv("AICORE_AUTH_TOKEN")
            or os.getenv("AICORE_API_KEY")
            or os.getenv("OPENAI_API_KEY")
            or ""
        )
        ai_resource_group = (
            self.connector_entity.params.get("ai_resource_group")
            or self.connector_entity.params.get("resource_group")
            or os.getenv("AICORE_RESOURCE_GROUP")
            or ""
        )
        default_headers = (
            {"AI-Resource-Group": ai_resource_group} if ai_resource_group else None
        )
        self._client = AsyncOpenAI(
            api_key=api_key,
            base_url=self.connector_entity.model_endpoint,
            default_headers=default_headers,
        )

    async def get_response(self, prompt: Any) -> ConnectorResponseEntity:
        """
        Retrieve a response from a SAP AI Core OpenAI-compatible endpoint.
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
