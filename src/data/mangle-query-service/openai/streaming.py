"""
Streaming support for OpenAI-compatible API.

Implements Server-Sent Events (SSE) for chat completions.
"""

import json
import asyncio
from typing import AsyncGenerator, List, Dict, Any, Optional
from datetime import datetime
import httpx


async def stream_chat_completion(
    aicore_url: str,
    model: str,
    messages: List[Dict[str, Any]],
    temperature: float = 0.7,
    max_tokens: Optional[int] = None,
) -> AsyncGenerator[str, None]:
    """
    Stream chat completion from AI Core.
    
    Yields SSE-formatted chunks:
    data: {"id":"...","choices":[{"delta":{"content":"token"}}]}\n\n
    """
    
    request_id = f"chatcmpl-{datetime.now().timestamp()}"
    created = int(datetime.now().timestamp())
    
    async with httpx.AsyncClient() as client:
        payload = {
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "stream": True,
        }
        if max_tokens:
            payload["max_tokens"] = max_tokens
        
        try:
            async with client.stream(
                "POST",
                f"{aicore_url}/v1/chat/completions",
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=120.0
            ) as response:
                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]":
                            yield "data: [DONE]\n\n"
                            break
                        
                        # Pass through AI Core chunks
                        yield f"data: {data}\n\n"
                        
        except Exception as e:
            # Return error as final chunk
            error_chunk = {
                "id": request_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{
                    "index": 0,
                    "delta": {},
                    "finish_reason": "error"
                }],
                "error": str(e)
            }
            yield f"data: {json.dumps(error_chunk)}\n\n"
            yield "data: [DONE]\n\n"


async def stream_mock_completion(
    model: str,
    messages: List[Dict[str, Any]],
    context: str = "",
) -> AsyncGenerator[str, None]:
    """
    Mock streaming for development/testing.
    
    Simulates token-by-token generation.
    """
    
    request_id = f"chatcmpl-{datetime.now().timestamp()}"
    created = int(datetime.now().timestamp())
    
    # Get user query
    user_query = next(
        (m["content"] for m in reversed(messages) if m["role"] == "user"),
        "Hello"
    )
    
    # Generate mock response
    response_text = f"[Mangle Query Service - Streaming]\n\nProcessed query: {user_query[:50]}..."
    if context:
        response_text += f"\n\nUsing context from: {context}"
    
    # Stream token by token
    for i, char in enumerate(response_text):
        chunk = {
            "id": request_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {"content": char} if i > 0 else {"role": "assistant", "content": char},
                "finish_reason": None
            }]
        }
        yield f"data: {json.dumps(chunk)}\n\n"
        await asyncio.sleep(0.02)  # Simulate generation delay
    
    # Final chunk
    final_chunk = {
        "id": request_id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{
            "index": 0,
            "delta": {},
            "finish_reason": "stop"
        }]
    }
    yield f"data: {json.dumps(final_chunk)}\n\n"
    yield "data: [DONE]\n\n"


def create_stream_response_generator(
    aicore_url: str,
    model: str,
    messages: List[Dict[str, Any]],
    temperature: float,
    max_tokens: Optional[int],
    context_source: str = "",
    use_mock: bool = False,
) -> AsyncGenerator[str, None]:
    """
    Create appropriate streaming generator based on configuration.
    """
    
    if use_mock or not aicore_url or aicore_url.startswith("http://mock"):
        return stream_mock_completion(model, messages, context_source)
    else:
        return stream_chat_completion(
            aicore_url, model, messages, temperature, max_tokens
        )