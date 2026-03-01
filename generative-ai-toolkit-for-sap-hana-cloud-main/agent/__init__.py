# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Generative AI Toolkit for HANA Cloud Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for generative AI with SAP HANA Cloud.

Note: ALWAYS routes to vLLM - HANA data is confidential.
"""

from .gen_ai_toolkit_agent import GenAiToolkitAgent, MangleEngine

__all__ = ["GenAiToolkitAgent", "MangleEngine"]