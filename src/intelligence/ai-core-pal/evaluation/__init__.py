# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 SAP SE
"""Agent trajectory evaluation package.

Closes MAS MGF §2.3.2 (REG-MGF-2.3.2-002): trajectory-level evaluation
of agent runs, not just end-state outputs.
"""
from .trajectory_evaluator import (
    TrajectoryEvaluator,
    TrajectoryScore,
    Step,
    Trajectory,
    ToolPolicy,
)

__all__ = [
    "TrajectoryEvaluator",
    "TrajectoryScore",
    "Step",
    "Trajectory",
    "ToolPolicy",
]
