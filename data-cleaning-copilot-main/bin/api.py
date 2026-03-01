#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""FastAPI server exposing the Data Cleaning Copilot as REST endpoints."""

import argparse
import os
import sys
from pathlib import Path
from typing import Optional

from loguru import logger
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

app = FastAPI(title="Data Cleaning Copilot API", version="1.0.0")

# CORS: use CORS_ALLOWED_ORIGINS (comma-separated). Do not use allow_credentials with "*".
_cors_origins_raw = os.getenv("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").strip()
_cors_origins = [o.strip() for o in _cors_origins_raw.split(",") if o.strip()]
_allow_wildcard = "*" in _cors_origins
_origins_list = [o for o in _cors_origins if o != "*"] if _allow_wildcard else _cors_origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins_list if _origins_list else (["*"] if _allow_wildcard else []),
    allow_credentials=not _allow_wildcard and bool(_origins_list),
    allow_methods=["*"],
    allow_headers=["*"],
)

# Globals – initialised on startup
_interactive_session = None
_session_manager = None
_session_id: str = ""
_session_model: str = "claude-4"
_agent_model: str = "claude-4"


def _aicore_config_ready() -> bool:
    required = ["AICORE_BASE_URL", "AICORE_AUTH_URL", "AICORE_CLIENT_ID", "AICORE_CLIENT_SECRET"]
    return all((os.getenv(key) or "").strip() for key in required)


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=12000)


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
    message = req.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be blank.")

    try:
        response = _interactive_session.process_request(message)
        return ChatResponse(response=response)
    except Exception as exc:
        logger.error(f"Chat error: {exc}")
        raise HTTPException(status_code=500, detail="Failed to process chat request.")


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
async def get_session_history(limit: int = Query(10, ge=1, le=100)):
    if _interactive_session is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    return _interactive_session._get_session_history(_session_id, limit=limit)


@app.get("/api/check-history")
async def get_check_history(limit: int = Query(5, ge=1, le=100)):
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
    if _interactive_session is None or _session_manager is None:
        raise HTTPException(status_code=503, detail="Session not initialised.")
    _session_manager.clear_session_history(_session_id)
    return ClearResponse(status="cleared")


@app.get("/api/health")
async def health():
    config_ready = _aicore_config_ready()
    return {
        "status": "ok" if _interactive_session is not None and config_ready else "degraded",
        "session_ready": _interactive_session is not None,
        "session_model": _session_model,
        "agent_model": _agent_model,
        "aicore_config_ready": config_ready,
    }


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

    if session_model_key not in model_map:
        raise ValueError(f"Unsupported session model: {session_model_key}")
    if agent_model_key not in model_map:
        raise ValueError(f"Unsupported agent model: {agent_model_key}")

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

    max_output_tokens = max(256, max_tokens - 500)

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

    def bounded_int(name: str, min_value: int, max_value: int):
        def _parse(value: str) -> int:
            parsed = int(value)
            if parsed < min_value or parsed > max_value:
                raise argparse.ArgumentTypeError(f"{name} must be between {min_value} and {max_value}")
            return parsed
        return _parse

    parser = argparse.ArgumentParser(description="Data Cleaning Copilot - FastAPI Server")
    parser.add_argument("--database", "-d", choices=["rel-stack"], required=True)
    parser.add_argument("--session-model", choices=["claude-3.7", "claude-4"], default="claude-4")
    parser.add_argument("--agent-model", choices=["claude-3.7", "claude-4"], default="claude-4")
    parser.add_argument("--session-deployment-id", type=str, default=None)
    parser.add_argument("--agent-deployment-id", type=str, default=None)
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--timeout", type=bounded_int("timeout", 1, 600), default=120)
    parser.add_argument("--max-tokens", type=bounded_int("max-tokens", 256, 64000), default=10000)
    parser.add_argument("--table-scopes", type=str, default="")
    parser.add_argument("--port", type=bounded_int("port", 1, 65535), default=8000)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    log_level = "DEBUG" if args.verbose else "INFO"
    logger.remove()
    logger.add(sys.stderr, level=log_level)

    load_dotenv()

    try:
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
    except Exception as exc:
        logger.error(f"Failed to initialise session: {exc}")
        raise SystemExit(1) from exc

    uvicorn.run(app, host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
