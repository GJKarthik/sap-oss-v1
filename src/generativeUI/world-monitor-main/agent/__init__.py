"""
World Monitor Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for global event monitoring and analysis.

Note: Content-based routing - public news to AI Core, analysis to vLLM.
"""

from .world_monitor_agent import WorldMonitorAgent, MangleEngine

__all__ = ["WorldMonitorAgent", "MangleEngine"]