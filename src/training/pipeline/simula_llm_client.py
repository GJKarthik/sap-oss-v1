"""
simula_llm_client.py — OpenAI-compatible LLM client for Simula reasoning tasks.

Supports:
- vLLM TurboQuant (local or AI Core deployed)
- OpenAI API
- Async batch generation for Best-of-N sampling
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from typing import AsyncIterator, Optional

import httpx

from .simula_config import LLMConfig, LLMProvider

logger = logging.getLogger(__name__)


@dataclass
class LLMResponse:
    """Structured response from LLM."""
    content: str
    finish_reason: str
    usage: dict


class SimulaLLMClient:
    """
    OpenAI-compatible client for Simula reasoning tasks.
    
    Uses vLLM TurboQuant or OpenAI API for:
    - Taxonomy generation (Best-of-N sampling)
    - Meta-prompt creation
    - Critic evaluation
    """
    
    def __init__(self, config: LLMConfig | None = None):
        self.config = config or LLMConfig()
        self._client: httpx.AsyncClient | None = None
        self._semaphore = asyncio.Semaphore(self.config.max_concurrent)
    
    @property
    def client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self.config.base_url,
                headers={
                    "Authorization": f"Bearer {self.config.api_key}",
                    "Content-Type": "application/json",
                },
                timeout=60.0,
            )
        return self._client
    
    async def close(self):
        """Close the HTTP client."""
        if self._client and not self._client.is_closed:
            await self._client.aclose()
    
    async def generate(
        self,
        prompt: str,
        system_prompt: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
        json_mode: bool = False,
    ) -> LLMResponse:
        """
        Generate a single completion.
        
        Args:
            prompt: User prompt
            system_prompt: Optional system prompt
            temperature: Override config temperature
            max_tokens: Override config max_tokens
            json_mode: Request JSON output format
            
        Returns:
            LLMResponse with content, finish_reason, and usage
        """
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        
        payload = {
            "model": self.config.model,
            "messages": messages,
            "temperature": temperature or self.config.temperature,
            "max_tokens": max_tokens or self.config.max_tokens,
        }
        
        if json_mode:
            payload["response_format"] = {"type": "json_object"}
        
        async with self._semaphore:
            try:
                response = await self.client.post("/chat/completions", json=payload)
                response.raise_for_status()
                data = response.json()
                
                choice = data["choices"][0]
                return LLMResponse(
                    content=choice["message"]["content"],
                    finish_reason=choice.get("finish_reason", "stop"),
                    usage=data.get("usage", {}),
                )
            except httpx.HTTPStatusError as e:
                logger.error(f"LLM request failed: {e.response.status_code} - {e.response.text}")
                raise
            except Exception as e:
                logger.error(f"LLM request error: {e}")
                raise
    
    async def generate_batch(
        self,
        prompts: list[str],
        system_prompt: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> list[LLMResponse]:
        """
        Generate completions for multiple prompts concurrently.
        
        Args:
            prompts: List of user prompts
            system_prompt: Optional system prompt (shared)
            temperature: Override config temperature
            max_tokens: Override config max_tokens
            
        Returns:
            List of LLMResponse objects
        """
        tasks = [
            self.generate(
                prompt=p,
                system_prompt=system_prompt,
                temperature=temperature,
                max_tokens=max_tokens,
            )
            for p in prompts
        ]
        return await asyncio.gather(*tasks, return_exceptions=True)
    
    async def best_of_n(
        self,
        prompt: str,
        n: int = 5,
        system_prompt: str | None = None,
        temperature: float = 0.8,
        max_tokens: int | None = None,
    ) -> list[str]:
        """
        Generate N diverse completions for the same prompt (Best-of-N sampling).
        
        Used for taxonomy expansion to increase proposal distribution coverage.
        
        Args:
            prompt: User prompt
            n: Number of completions to generate
            system_prompt: Optional system prompt
            temperature: Higher temperature for diversity (default 0.8)
            max_tokens: Override config max_tokens
            
        Returns:
            List of N completion strings
        """
        # Generate N prompts (all the same)
        prompts = [prompt] * n
        responses = await self.generate_batch(
            prompts=prompts,
            system_prompt=system_prompt,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        
        # Filter out errors and extract content
        results = []
        for r in responses:
            if isinstance(r, LLMResponse):
                results.append(r.content)
            else:
                logger.warning(f"Best-of-N generation failed: {r}")
        
        return results
    
    async def generate_json(
        self,
        prompt: str,
        system_prompt: str | None = None,
        temperature: float | None = None,
    ) -> dict:
        """
        Generate a JSON response.
        
        Args:
            prompt: User prompt (should request JSON output)
            system_prompt: Optional system prompt
            temperature: Override config temperature
            
        Returns:
            Parsed JSON dict
        """
        response = await self.generate(
            prompt=prompt,
            system_prompt=system_prompt,
            temperature=temperature,
            json_mode=True,
        )
        
        try:
            return json.loads(response.content)
        except json.JSONDecodeError:
            # Try to extract JSON from markdown code blocks
            content = response.content
            if "```json" in content:
                start = content.find("```json") + 7
                end = content.find("```", start)
                content = content[start:end].strip()
            elif "```" in content:
                start = content.find("```") + 3
                end = content.find("```", start)
                content = content[start:end].strip()
            
            return json.loads(content)
    
    async def critic_evaluate(
        self,
        content: str,
        requirements: list[str],
        system_prompt: str | None = None,
    ) -> tuple[bool, str]:
        """
        Evaluate content against requirements using the critic pattern.
        
        Args:
            content: Content to evaluate
            requirements: List of requirements to check
            system_prompt: Optional custom system prompt
            
        Returns:
            Tuple of (is_valid, explanation)
        """
        default_system = """You are a strict critic evaluating if content meets requirements.
Analyze the content against each requirement.
Respond with a JSON object containing:
- "verdict": "pass" or "fail"
- "explanation": Brief explanation of your verdict
- "failed_requirements": List of requirements that were not met (empty if passed)"""
        
        prompt = f"""Evaluate if this content meets ALL the following requirements:

REQUIREMENTS:
{chr(10).join(f"- {r}" for r in requirements)}

CONTENT:
{content}

Provide your evaluation as JSON."""
        
        try:
            result = await self.generate_json(
                prompt=prompt,
                system_prompt=system_prompt or default_system,
                temperature=0.2,  # Low temperature for consistent evaluation
            )
            
            is_valid = result.get("verdict", "").lower() == "pass"
            explanation = result.get("explanation", "")
            
            return is_valid, explanation
        except Exception as e:
            logger.error(f"Critic evaluation failed: {e}")
            return False, f"Evaluation error: {e}"
    
    async def double_critic_evaluate(
        self,
        content: str,
        requirements: list[str],
    ) -> tuple[bool, str]:
        """
        Double-critic evaluation: independently assess correctness AND incorrectness.
        
        This mitigates sycophancy bias by requiring positive confirmation
        from the "correct" critic and negative confirmation from the "incorrect" critic.
        
        Args:
            content: Content to evaluate
            requirements: List of requirements to check
            
        Returns:
            Tuple of (is_valid, explanation)
        """
        # Critic 1: Evaluate if content IS correct
        positive_system = """You are a strict critic evaluating if content meets requirements.
Focus on finding evidence that the content MEETS the requirements.
Be thorough but fair in your evaluation.
Respond with JSON: {"verdict": "pass" or "fail", "explanation": "..."}"""
        
        # Critic 2: Evaluate if content is INCORRECT
        negative_system = """You are a strict critic evaluating if content FAILS to meet requirements.
Focus on finding evidence that the content DOES NOT meet the requirements.
Be thorough and look for any violations or missing elements.
Respond with JSON: {"verdict": "pass" or "fail", "explanation": "..."}
Note: "pass" means you found evidence of failure, "fail" means the content seems valid."""
        
        prompt = f"""Evaluate this content against the requirements:

REQUIREMENTS:
{chr(10).join(f"- {r}" for r in requirements)}

CONTENT:
{content}

Provide your evaluation as JSON."""
        
        try:
            # Run both critics concurrently
            positive_task = self.generate_json(
                prompt=prompt,
                system_prompt=positive_system,
                temperature=0.2,
            )
            negative_task = self.generate_json(
                prompt=prompt,
                system_prompt=negative_system,
                temperature=0.2,
            )
            
            positive_result, negative_result = await asyncio.gather(
                positive_task, negative_task, return_exceptions=True
            )
            
            # Handle errors
            if isinstance(positive_result, Exception):
                logger.error(f"Positive critic failed: {positive_result}")
                return False, f"Positive critic error: {positive_result}"
            if isinstance(negative_result, Exception):
                logger.error(f"Negative critic failed: {negative_result}")
                return False, f"Negative critic error: {negative_result}"
            
            # Evaluate: pass if positive critic passes AND negative critic fails
            positive_pass = positive_result.get("verdict", "").lower() == "pass"
            negative_found_issues = negative_result.get("verdict", "").lower() == "pass"
            
            is_valid = positive_pass and not negative_found_issues
            
            explanation = (
                f"Positive critic: {positive_result.get('explanation', 'N/A')}; "
                f"Negative critic: {negative_result.get('explanation', 'N/A')}"
            )
            
            return is_valid, explanation
            
        except Exception as e:
            logger.error(f"Double critic evaluation failed: {e}")
            return False, f"Evaluation error: {e}"


# Convenience function for one-off generations
async def quick_generate(
    prompt: str,
    system_prompt: str | None = None,
    config: LLMConfig | None = None,
) -> str:
    """Quick one-off generation without managing client lifecycle."""
    client = SimulaLLMClient(config)
    try:
        response = await client.generate(prompt, system_prompt)
        return response.content
    finally:
        await client.close()


# Sync wrapper for non-async contexts
def generate_sync(
    prompt: str,
    system_prompt: str | None = None,
    config: LLMConfig | None = None,
) -> str:
    """Synchronous wrapper for quick_generate."""
    return asyncio.run(quick_generate(prompt, system_prompt, config))