"""
Per-upstream async circuit breaker for LLM HTTP calls (vLLM vs AI Core proxy).

States: CLOSED (normal), OPEN (fail-fast, no network), HALF_OPEN (single probe after cooldown).
"""

from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass
from enum import Enum
from typing import Dict


class _State(str, Enum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


@dataclass
class _Circuit:
    state: _State = _State.CLOSED
    consecutive_failures: int = 0
    opened_at: float | None = None


class LLMCircuitBreaker:
    def __init__(self, failure_threshold: int, cooldown_sec: float) -> None:
        self.failure_threshold = max(1, failure_threshold)
        self.cooldown_sec = max(1.0, cooldown_sec)
        self._circuits: Dict[str, _Circuit] = {}
        self._lock = asyncio.Lock()

    @classmethod
    def from_env(cls) -> LLMCircuitBreaker:
        threshold = int(os.getenv("LLM_CIRCUIT_FAILURE_THRESHOLD", "5"))
        cooldown = float(os.getenv("LLM_CIRCUIT_COOLDOWN_SEC", "30"))
        return cls(failure_threshold=threshold, cooldown_sec=cooldown)

    async def allow_request(self, name: str) -> bool:
        """Return True if the caller may attempt an upstream HTTP call."""
        now = time.monotonic()
        async with self._lock:
            c = self._circuits.setdefault(name, _Circuit())
            if c.state == _State.CLOSED:
                return True
            if c.state == _State.OPEN:
                if c.opened_at is not None and now - c.opened_at >= self.cooldown_sec:
                    c.state = _State.HALF_OPEN
                    return True
                return False
            # HALF_OPEN: allow probe
            return True

    async def record_success(self, name: str) -> None:
        async with self._lock:
            c = self._circuits.setdefault(name, _Circuit())
            c.state = _State.CLOSED
            c.consecutive_failures = 0
            c.opened_at = None

    async def record_failure(self, name: str) -> None:
        async with self._lock:
            c = self._circuits.setdefault(name, _Circuit())
            if c.state == _State.HALF_OPEN:
                c.state = _State.OPEN
                c.opened_at = time.monotonic()
                c.consecutive_failures = self.failure_threshold
                return
            c.consecutive_failures += 1
            if c.consecutive_failures >= self.failure_threshold:
                c.state = _State.OPEN
                c.opened_at = time.monotonic()

    def snapshot(self, name: str) -> dict:
        """For tests / debugging (not used in hot path)."""
        c = self._circuits.get(name)
        if not c:
            return {"state": _State.CLOSED.value, "failures": 0}
        return {
            "state": c.state.value,
            "failures": c.consecutive_failures,
            "opened_at": c.opened_at,
        }
