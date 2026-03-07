"""
OpenAI-Compatible Router

Provides aiohttp routes for OpenAI-compatible API endpoints.

Endpoints:
- GET  /v1/models
- GET  /v1/models/{model_id}
- POST /v1/chat/completions
- POST /v1/embeddings
- GET  /health
- GET  /livez
- GET  /readyz
"""

import json
from typing import Optional, Callable, Any
from aiohttp import web

from .models import list_models, get_model
from .chat_completions import create_chat_completion
from .embeddings import create_embedding, initialize_vocabulary_embeddings


# Global routes registry
routes = web.RouteTableDef()


@routes.get('/v1/models')
async def handle_list_models(request: web.Request) -> web.Response:
    """GET /v1/models - List available models"""
    result = list_models()
    return web.json_response(result)


@routes.get('/v1/models/{model_id}')
async def handle_get_model(request: web.Request) -> web.Response:
    """GET /v1/models/{model_id} - Get specific model"""
    model_id = request.match_info['model_id']
    result = get_model(model_id)
    
    if result is None:
        return web.json_response(
            {"error": {"message": f"Model {model_id} not found", "type": "invalid_request_error"}},
            status=404
        )
    
    return web.json_response(result)


@routes.post('/v1/chat/completions')
async def handle_chat_completions(request: web.Request) -> web.Response:
    """POST /v1/chat/completions - Create chat completion"""
    try:
        body = await request.json()
    except json.JSONDecodeError:
        return web.json_response(
            {"error": {"message": "Invalid JSON body", "type": "invalid_request_error"}},
            status=400
        )
    
    # Extract required parameters
    model = body.get('model')
    messages = body.get('messages')
    
    if not model:
        return web.json_response(
            {"error": {"message": "Missing required parameter: model", "type": "invalid_request_error"}},
            status=400
        )
    
    if not messages:
        return web.json_response(
            {"error": {"message": "Missing required parameter: messages", "type": "invalid_request_error"}},
            status=400
        )
    
    # Check for streaming
    stream = body.get('stream', False)
    
    if stream:
        # Return streaming response
        response = web.StreamResponse(
            status=200,
            headers={
                'Content-Type': 'text/event-stream',
                'Cache-Control': 'no-cache',
                'Connection': 'keep-alive'
            }
        )
        await response.prepare(request)
        
        generator = create_chat_completion(
            model=model,
            messages=messages,
            stream=True,
            **{k: v for k, v in body.items() if k not in ['model', 'messages', 'stream']}
        )
        
        for chunk in generator:
            await response.write(chunk.encode('utf-8'))
        
        return response
    
    # Non-streaming response
    result = create_chat_completion(
        model=model,
        messages=messages,
        **{k: v for k, v in body.items() if k not in ['model', 'messages']}
    )
    
    # Check for error
    if 'error' in result:
        return web.json_response(result, status=400)
    
    return web.json_response(result)


@routes.post('/v1/embeddings')
async def handle_embeddings(request: web.Request) -> web.Response:
    """POST /v1/embeddings - Create embeddings"""
    try:
        body = await request.json()
    except json.JSONDecodeError:
        return web.json_response(
            {"error": {"message": "Invalid JSON body", "type": "invalid_request_error"}},
            status=400
        )
    
    # Extract required parameters
    input_text = body.get('input')
    model = body.get('model', 'text-embedding-odata')
    
    if not input_text:
        return web.json_response(
            {"error": {"message": "Missing required parameter: input", "type": "invalid_request_error"}},
            status=400
        )
    
    result = create_embedding(
        input=input_text,
        model=model,
        **{k: v for k, v in body.items() if k not in ['input', 'model']}
    )
    
    # Check for error
    if 'error' in result:
        return web.json_response(result, status=400)
    
    return web.json_response(result)


@routes.get('/health')
async def handle_health(request: web.Request) -> web.Response:
    """GET /health - Full health check"""
    try:
        from lib.health import get_health_checker
        checker = get_health_checker()
        result = checker.run_all_checks()
        
        status_code = 200
        if result.status.value == "unhealthy":
            status_code = 503
        elif result.status.value == "degraded":
            status_code = 200  # Still accept traffic when degraded
        
        return web.json_response(result.to_dict(), status=status_code)
    except ImportError:
        # Fallback if health module not available
        return web.json_response({
            "status": "healthy",
            "version": "3.0.0"
        })


@routes.get('/livez')
async def handle_liveness(request: web.Request) -> web.Response:
    """GET /livez - Kubernetes liveness probe"""
    try:
        from lib.health import get_health_checker
        checker = get_health_checker()
        result = checker.get_liveness()
        return web.json_response(result)
    except ImportError:
        return web.json_response({"status": "alive"})


@routes.get('/readyz')
async def handle_readiness(request: web.Request) -> web.Response:
    """GET /readyz - Kubernetes readiness probe"""
    try:
        from lib.health import get_health_checker
        checker = get_health_checker()
        result = checker.get_readiness()
        
        if result.get("status") == "not_ready":
            return web.json_response(result, status=503)
        
        return web.json_response(result)
    except ImportError:
        return web.json_response({"status": "ready"})


# Alternative route names for OpenAI SDK compatibility
@routes.get('/models')
async def handle_list_models_alt(request: web.Request) -> web.Response:
    """GET /models - Alternative path (without /v1 prefix)"""
    return await handle_list_models(request)


@routes.post('/chat/completions')
async def handle_chat_completions_alt(request: web.Request) -> web.Response:
    """POST /chat/completions - Alternative path (without /v1 prefix)"""
    return await handle_chat_completions(request)


@routes.post('/embeddings')
async def handle_embeddings_alt(request: web.Request) -> web.Response:
    """POST /embeddings - Alternative path (without /v1 prefix)"""
    return await handle_embeddings(request)


def create_app(middlewares: list = None) -> web.Application:
    """
    Create aiohttp application with OpenAI-compatible routes.
    
    Args:
        middlewares: Optional list of aiohttp middleware
    
    Returns:
        Configured aiohttp Application
    """
    app = web.Application(middlewares=middlewares or [])
    app.router.add_routes(routes)
    
    # Initialize vocabulary embeddings on startup
    async def on_startup(app):
        count = initialize_vocabulary_embeddings()
        print(f"Initialized {count} vocabulary embeddings")
    
    app.on_startup.append(on_startup)
    
    return app


def router():
    """Get the route table for integration with existing servers"""
    return routes


# Standalone server runner
async def run_server(host: str = "0.0.0.0", port: int = 9150):
    """
    Run standalone OpenAI-compatible server.
    
    Args:
        host: Host to bind to
        port: Port to listen on
    """
    app = create_app()
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    
    print(f"OpenAI-compatible server running at http://{host}:{port}")
    print("Endpoints:")
    print("  GET  /v1/models")
    print("  GET  /v1/models/{model_id}")
    print("  POST /v1/chat/completions")
    print("  POST /v1/embeddings")
    print("  GET  /health")
    print("  GET  /livez")
    print("  GET  /readyz")
    
    await site.start()
    
    # Keep running
    import asyncio
    while True:
        await asyncio.sleep(3600)


if __name__ == "__main__":
    import asyncio
    asyncio.run(run_server())