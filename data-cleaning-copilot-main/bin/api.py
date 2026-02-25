#!/usr/bin/env python3
"""FastAPI server exposing the Data Cleaning Copilot as REST endpoints."""

import argparse
import os
import sys
from pathlib import Path
from typing import Optional

from loguru import logger
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

app = FastAPI(title="Data Cleaning Copilot API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Globals – initialised on startup
_interactive_session = None
_session_manager = None
_session_id: str = ""
_session_model: str = "claude-4"
_agent_model: str = "claude-4"


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    response: str


class ClearResponse(BaseModel):
    status: str


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.post("/api/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised. Start the server with --database flag.")
    try:
        response = _interactive_session.process_request(req.message)
        return ChatResponse(response=response)
    except Exception as exc:
        logger.error(f"Chat error: {exc}")
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/api/checks")
async def get_checks():
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    checks = _interactive_session.database.generated_checks
    result = {}
    for name, check in checks.items():
        display_name = name[4:] if name.startswith("llm_") else name
        result[display_name] = {
            "description": check.description,
            "scope": check.scope,
            "code": check.to_code(),
        }
    return result


@app.get("/api/session-history")
async def get_session_history(limit: int = 10):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    return _interactive_session._get_session_history(_session_id, limit=limit)


@app.get("/api/check-history")
async def get_check_history(limit: int = 5):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    check_session_id = _interactive_session.database.check_generator_session_id
    return _interactive_session._get_session_history(check_session_id, limit=limit)


@app.get("/api/session-config")
async def get_session_config():
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    return {
        "main": _interactive_session._get_session_config(_session_id),
        "check_gen": _interactive_session._get_session_config(
            _interactive_session.database.check_generator_session_id
        ),
        "session_model": _session_model,
        "agent_model": _agent_model,
    }


@app.delete("/api/session", response_model=ClearResponse)
async def clear_session():
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    _session_manager.clear_session_history(_session_id)
    return ClearResponse(status="cleared")


@app.get("/api/health")
async def health():
    return {"status": "ok", "session_ready": _interactive_session is not None}


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

def _init_session(
    database_type: str,
    data_dir: Optional[str],
    session_model_key: str,
    agent_model_key: str,
    session_deployment_id: Optional[str],
    agent_deployment_id: Optional[str],
    timeout: int,
    max_tokens: int,
    table_scopes: str,
) -> None:
    global _interactive_session, _session_manager, _session_id, _session_model, _agent_model

    from definition.impl.database.rel_stack import RelStack
    from definition.llm.session_manager import LLMSessionManager
    from definition.llm.models import LLMProvider, LLMSessionConfig
    from definition.llm.interactive.session import InteractiveSession

    model_map = {
        "claude-3.7": LLMProvider.ANTHROPIC_CLAUDE_3_7,
        "claude-4": LLMProvider.ANTHROPIC_CLAUDE_4,
    }

    _session_model = session_model_key
    _agent_model = agent_model_key

    table_scope_set = {t.strip() for t in table_scopes.split(",") if t.strip()} if table_scopes else set()

    session_manager = LLMSessionManager()

    session_config = LLMSessionConfig(
        model_name=model_map[session_model_key],
        temperature=0.1,
        max_tokens=max_tokens,
        deployment_id=session_deployment_id,
        base_url=os.getenv("AICORE_BASE_URL"),
        auth_url=os.getenv("AICORE_AUTH_URL"),
        client_id=os.getenv("AICORE_CLIENT_ID"),
        client_secret=os.getenv("AICORE_CLIENT_SECRET"),
        resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
    )

    agent_config = LLMSessionConfig(
        model_name=model_map[agent_model_key],
        temperature=0.7,
        max_tokens=max_tokens,
        deployment_id=agent_deployment_id,
        base_url=os.getenv("AICORE_BASE_URL"),
        auth_url=os.getenv("AICORE_AUTH_URL"),
        client_id=os.getenv("AICORE_CLIENT_ID"),
        client_secret=os.getenv("AICORE_CLIENT_SECRET"),
        resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
    )

    max_output_tokens = max_tokens - 500

    if database_type == "rel-stack":
        db = RelStack(
            database_id="rel_stack_agent",
            max_output_tokens=max_output_tokens,
            table_scopes=table_scope_set,
            max_execution_time=timeout,
        )

        # Load data
        from bin.copilot import load_relstack_data
        data_path = Path(data_dir) if data_dir else None
        loaded, total = load_relstack_data(db, data_path)
        logger.info(f"Loaded {loaded}/{total} tables")
    else:
        raise ValueError(f"Unsupported database type: {database_type}")

    sid = f"{database_type}_api_session"
    _session_id = sid
    _session_manager = session_manager

    _interactive_session = InteractiveSession(
        database=db,
        session_manager=session_manager,
        config=session_config,
        session_id=sid,
        agent_config=agent_config,
    )

    logger.success(f"Interactive session '{sid}' ready.")


# ---------------------------------------------------------------------------
# CLI entry-point
# ---------------------------------------------------------------------------

def main() -> None:
    import uvicorn

    parser = argparse.ArgumentParser(description="Data Cleaning Copilot - FastAPI Server")
    parser.add_argument("--database", "-d", choices=["rel-stack"], required=True)
    parser.add_argument("--session-model", choices=["claude-3.7", "claude-4"], default="claude-4")
    parser.add_argument("--agent-model", choices=["claude-3.7", "claude-4"], default="claude-4")
    parser.add_argument("--session-deployment-id", type=str, default=None)
    parser.add_argument("--agent-deployment-id", type=str, default=None)
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--max-tokens", type=int, default=10000)
    parser.add_argument("--table-scopes", type=str, default="")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    log_level = "DEBUG" if args.verbose else "INFO"
    logger.remove()
    logger.add(sys.stderr, level=log_level)

    load_dotenv()

    _init_session(
        database_type=args.database,
        data_dir=args.data_dir,
        session_model_key=args.session_model,
        agent_model_key=args.agent_model,
        session_deployment_id=args.session_deployment_id,
        agent_deployment_id=args.agent_deployment_id,
        timeout=args.timeout,
        max_tokens=args.max_tokens,
        table_scopes=args.table_scopes,
    )

    uvicorn.run(app, host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
