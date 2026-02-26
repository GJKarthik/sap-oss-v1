"""
AI Core PAL Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for SAP HANA Predictive Analysis Library (PAL).

Note: HANA data is confidential - always routes to vLLM only.
"""

from .aicore_pal_agent import AICorePALAgent, MangleEngine

__all__ = ["AICorePALAgent", "MangleEngine"]