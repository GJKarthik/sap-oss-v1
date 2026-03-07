# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Resilience patterns for HANA AI Tools.

Provides circuit breaker and retry patterns for protecting tools
against cascading failures.
"""

from hana_ai.tools.resilience.circuit_breaker import (
    CircuitState,
    CircuitOpenError,
    ToolCircuitBreaker,
    CircuitBreakerRegistry,
    get_circuit_breaker_registry,
    circuit_protected,
)

__all__ = [
    "CircuitState",
    "CircuitOpenError",
    "ToolCircuitBreaker",
    "CircuitBreakerRegistry",
    "get_circuit_breaker_registry",
    "circuit_protected",
]