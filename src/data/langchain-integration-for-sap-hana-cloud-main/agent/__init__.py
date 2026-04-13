# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2023 SAP SE
"""
LangChain HANA Cloud Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
and governance rules for HANA vector store operations.

Note: HANA data is confidential by default - routes to vLLM for data queries.
"""

from .langchain_hana_agent import LangChainHanaAgent, GovernanceEngine

__all__ = ["LangChainHanaAgent", "GovernanceEngine"]