# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 SAP SE
"""Post-deployment drift monitoring for agentic AI.

Tracks three families of signal and compares each against a baseline
captured at pilot-exit time:

1. **Override rate.** Fraction of agent recommendations that reviewers
   overrode. A fall well below baseline is the automation-bias signal
   highlighted by Ju & Aral (2026) (REG-JU-ARAL-4-001); a spike above
   baseline indicates model regression.
2. **Review duration.** Median wall-clock seconds between an agent
   recommendation and a reviewer decision. A collapse in duration
   alongside a collapse in override rate is the joint Ju-Aral signal
   to re-audit.
3. **Hallucination score.** A generic 0..1 score per inference; the
   monitor consumes whatever upstream evaluator produced it (Moonshot
   CI/CD hallucination benchmark, an LLM judge, or
   :mod:`evaluation.trajectory_evaluator`).

The monitor is intentionally simple: pure stdlib, no external TSDB, no
global state. It is designed to run as a batch job that ingests a day
of agent-event JSON and emits a :class:`DriftReport` to the GCFO
Finance AI Council (GFAIC) inbox — the federated body that holds
finance-scope binding authority under Delegation No. 2026-04 from the
Group AI Safety Council.

Closes regulatory requirement ``REG-MGF-2.3.3-002`` (MAS MGF Agentic AI
§2.3.3 — post-deployment monitoring).
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum
from statistics import median
from typing import Iterable, List, Optional, Sequence


# ---------------------------------------------------------------------------
# Enums / data classes
# ---------------------------------------------------------------------------


class AlertLevel(Enum):
    OK = "ok"
    WARN = "warn"
    CRITICAL = "critical"


@dataclass(frozen=True)
class BaselineSpec:
    """Baseline captured at pilot-exit.

    ``_tolerance`` values are absolute deltas for rates/scores and
    relative fractions for durations (because duration scale varies per
    agent).
    """

    override_rate: float
    override_tolerance: float = 0.05  # +/- absolute
    median_review_seconds: float = 120.0
    review_tolerance: float = 0.30  # +/- 30 %
    hallucination_rate: float = 0.02  # 2 %
    hallucination_tolerance: float = 0.03  # +/- absolute

    def validate(self) -> None:
        if not 0.0 <= self.override_rate <= 1.0:
            raise ValueError("override_rate must be in [0, 1]")
        if not 0.0 <= self.hallucination_rate <= 1.0:
            raise ValueError("hallucination_rate must be in [0, 1]")
        if self.median_review_seconds <= 0:
            raise ValueError("median_review_seconds must be > 0")


@dataclass
class MetricWindow:
    """One evaluation window (e.g. last 24 h of agent runs)."""

    n_runs: int
    n_overrides: int
    review_seconds: Sequence[float]
    hallucination_scores: Sequence[float]

    def override_rate(self) -> float:
        if self.n_runs == 0:
            return 0.0
        return self.n_overrides / self.n_runs

    def median_review(self) -> float:
        if not self.review_seconds:
            return math.nan
        return float(median(self.review_seconds))

    def hallucination_rate(self, threshold: float = 0.5) -> float:
        if not self.hallucination_scores:
            return 0.0
        flagged = sum(1 for s in self.hallucination_scores if s >= threshold)
        return flagged / len(self.hallucination_scores)


@dataclass
class Signal:
    name: str
    observed: float
    baseline: float
    delta: float
    level: AlertLevel
    message: str


@dataclass
class DriftReport:
    agent_id: str
    level: AlertLevel
    signals: List[Signal]
    window_runs: int
    notes: List[str] = field(default_factory=list)

    def passed(self) -> bool:
        return self.level == AlertLevel.OK

    def as_dict(self) -> dict:
        return {
            "agent_id": self.agent_id,
            "level": self.level.value,
            "window_runs": self.window_runs,
            "signals": [
                {
                    "name": s.name,
                    "observed": s.observed,
                    "baseline": s.baseline,
                    "delta": s.delta,
                    "level": s.level.value,
                    "message": s.message,
                }
                for s in self.signals
            ],
            "notes": list(self.notes),
        }


# ---------------------------------------------------------------------------
# Monitor
# ---------------------------------------------------------------------------


class DriftMonitor:
    """Per-agent drift monitor.

    Parameters
    ----------
    agent_id:
        Logical agent id (e.g. ``tb-review-agent``).
    baseline:
        Pilot-exit baseline. Must be explicitly frozen; the monitor
        never rewrites it.
    min_runs:
        Minimum number of runs before signals are evaluated. Below this
        threshold the monitor emits :class:`AlertLevel.OK` with a note.
    """

    def __init__(
        self,
        agent_id: str,
        baseline: BaselineSpec,
        min_runs: int = 20,
    ):
        if not agent_id:
            raise ValueError("agent_id is required")
        if min_runs < 1:
            raise ValueError("min_runs must be >= 1")
        baseline.validate()
        self._agent_id = agent_id
        self._baseline = baseline
        self._min_runs = min_runs

    def evaluate(self, window: MetricWindow) -> DriftReport:
        if window.n_runs < self._min_runs:
            return DriftReport(
                agent_id=self._agent_id,
                level=AlertLevel.OK,
                signals=[],
                window_runs=window.n_runs,
                notes=[
                    f"window has {window.n_runs} runs, below "
                    f"min_runs={self._min_runs}; drift not evaluated"
                ],
            )

        signals: List[Signal] = [
            self._override_signal(window),
            self._review_signal(window),
            self._hallucination_signal(window),
        ]
        highest = max(
            (s.level for s in signals),
            key=_level_rank,
        )
        return DriftReport(
            agent_id=self._agent_id,
            level=highest,
            signals=signals,
            window_runs=window.n_runs,
        )

    # -- signals ----------------------------------------------------------

    def _override_signal(self, window: MetricWindow) -> Signal:
        observed = window.override_rate()
        baseline = self._baseline.override_rate
        tol = self._baseline.override_tolerance
        delta = observed - baseline

        # Both directions matter. A *drop* of more than tol is the
        # automation-bias signal; a *rise* is regression.
        if abs(delta) <= tol:
            return Signal(
                name="override_rate",
                observed=observed,
                baseline=baseline,
                delta=delta,
                level=AlertLevel.OK,
                message="within tolerance",
            )
        if abs(delta) <= 2 * tol:
            direction = "fell" if delta < 0 else "rose"
            return Signal(
                name="override_rate",
                observed=observed,
                baseline=baseline,
                delta=delta,
                level=AlertLevel.WARN,
                message=f"override rate {direction} by {abs(delta):.3f}",
            )
        direction = "fell" if delta < 0 else "rose"
        return Signal(
            name="override_rate",
            observed=observed,
            baseline=baseline,
            delta=delta,
            level=AlertLevel.CRITICAL,
            message=(
                f"override rate {direction} by {abs(delta):.3f}; "
                f"exceeds 2x tolerance"
            ),
        )

    def _review_signal(self, window: MetricWindow) -> Signal:
        observed = window.median_review()
        baseline = self._baseline.median_review_seconds
        if math.isnan(observed):
            return Signal(
                name="median_review_seconds",
                observed=observed,
                baseline=baseline,
                delta=math.nan,
                level=AlertLevel.WARN,
                message="no review durations recorded",
            )
        rel_delta = (observed - baseline) / baseline
        if abs(rel_delta) <= self._baseline.review_tolerance:
            return Signal(
                name="median_review_seconds",
                observed=observed,
                baseline=baseline,
                delta=rel_delta,
                level=AlertLevel.OK,
                message="within tolerance",
            )
        if abs(rel_delta) <= 2 * self._baseline.review_tolerance:
            return Signal(
                name="median_review_seconds",
                observed=observed,
                baseline=baseline,
                delta=rel_delta,
                level=AlertLevel.WARN,
                message=(
                    f"median review time shifted {rel_delta * 100:.0f}% "
                    f"vs baseline"
                ),
            )
        return Signal(
            name="median_review_seconds",
            observed=observed,
            baseline=baseline,
            delta=rel_delta,
            level=AlertLevel.CRITICAL,
            message=(
                f"median review time shifted {rel_delta * 100:.0f}% "
                f"vs baseline; exceeds 2x tolerance"
            ),
        )

    def _hallucination_signal(self, window: MetricWindow) -> Signal:
        observed = window.hallucination_rate()
        baseline = self._baseline.hallucination_rate
        tol = self._baseline.hallucination_tolerance
        delta = observed - baseline
        if delta <= tol:
            return Signal(
                name="hallucination_rate",
                observed=observed,
                baseline=baseline,
                delta=delta,
                level=AlertLevel.OK,
                message="within tolerance",
            )
        if delta <= 2 * tol:
            return Signal(
                name="hallucination_rate",
                observed=observed,
                baseline=baseline,
                delta=delta,
                level=AlertLevel.WARN,
                message=f"hallucination rate rose by {delta:.3f}",
            )
        return Signal(
            name="hallucination_rate",
            observed=observed,
            baseline=baseline,
            delta=delta,
            level=AlertLevel.CRITICAL,
            message=(
                f"hallucination rate rose by {delta:.3f}; "
                f"exceeds 2x tolerance"
            ),
        )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


_LEVEL_ORDER = {AlertLevel.OK: 0, AlertLevel.WARN: 1, AlertLevel.CRITICAL: 2}


def _level_rank(level: AlertLevel) -> int:
    return _LEVEL_ORDER[level]


def combine_windows(windows: Iterable[MetricWindow]) -> MetricWindow:
    """Combine several per-day windows into a rolling window."""
    n_runs = 0
    n_overrides = 0
    review: List[float] = []
    hallucination: List[float] = []
    for w in windows:
        n_runs += w.n_runs
        n_overrides += w.n_overrides
        review.extend(w.review_seconds)
        hallucination.extend(w.hallucination_scores)
    return MetricWindow(
        n_runs=n_runs,
        n_overrides=n_overrides,
        review_seconds=review,
        hallucination_scores=hallucination,
    )
