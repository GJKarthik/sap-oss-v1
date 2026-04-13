"""
UI5 Web Components Angular Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for UI5 Angular component generation and development.

Note: AI Core default - public code/documentation. Routes to vLLM only for user data.
"""

from .ui5_ngx_agent import UI5NgxAgent, GovernanceEngine

__all__ = ["UI5NgxAgent", "GovernanceEngine"]