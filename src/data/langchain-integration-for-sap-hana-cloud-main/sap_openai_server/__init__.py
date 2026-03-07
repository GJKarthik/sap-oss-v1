# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2023 SAP SE
"""
SAP OpenAI-Compatible Server for LangChain HANA Integration

Provides a full OpenAI-compatible API that routes to SAP AI Core
with LangChain + HANA Cloud vector store integration.
"""

from .server import app, main

__version__ = "1.0.0"
__all__ = ["app", "main"]