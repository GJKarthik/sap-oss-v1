# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Data Cleaning Copilot Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
and regulations/mangle compliance for data cleaning operations.

Note: This service ALWAYS routes to vLLM since it processes raw financial data.
"""

from .data_cleaning_agent import DataCleaningAgent, MangleEngine

__all__ = ["DataCleaningAgent", "MangleEngine"]