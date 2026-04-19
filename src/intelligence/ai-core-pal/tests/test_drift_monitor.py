# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 SAP SE
"""Unit tests for :mod:`monitoring.drift_monitor`.

Run: pytest tests/test_drift_monitor.py -v
"""
from __future__ import annotations

import math
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from monitoring import (
    AlertLevel,
    BaselineSpec,
    DriftMonitor,
    DriftReport,
    MetricWindow,
)
from monitoring.drift_monitor import combine_windows


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def baseline() -> BaselineSpec:
    return BaselineSpec(
        override_rate=0.20,
        override_tolerance=0.05,
        median_review_seconds=180.0,
        review_tolerance=0.30,
        hallucination_rate=0.02,
        hallucination_tolerance=0.03,
    )


@pytest.fixture
def monitor(baseline: BaselineSpec) -> DriftMonitor:
    return DriftMonitor("tb-review-agent", baseline, min_runs=20)


def _steady_window(n: int = 100) -> MetricWindow:
    """A window near the baseline (0.20 overrides, 180s median, clean)."""
    return MetricWindow(
        n_runs=n,
        n_overrides=int(round(0.20 * n)),
        review_seconds=[180.0] * n,
        hallucination_scores=[0.1] * n,
    )


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


class TestHappyPath:
    def test_steady_window_is_ok(self, monitor: DriftMonitor):
        report = monitor.evaluate(_steady_window())
        assert report.level == AlertLevel.OK
        assert report.passed()
        assert {s.name for s in report.signals} == {
            "override_rate",
            "median_review_seconds",
            "hallucination_rate",
        }

    def test_as_dict_is_serialisable(self, monitor: DriftMonitor):
        report = monitor.evaluate(_steady_window())
        d = report.as_dict()
        assert d["agent_id"] == "tb-review-agent"
        assert d["level"] == "ok"
        assert len(d["signals"]) == 3


# ---------------------------------------------------------------------------
# Threshold behaviour
# ---------------------------------------------------------------------------


class TestOverrideRateSignals:
    def test_small_drop_warns(self, monitor: DriftMonitor):
        w = _steady_window()
        w.n_overrides = int(round(0.12 * w.n_runs))  # -0.08 from baseline 0.20
        report = monitor.evaluate(w)
        override = _sig(report, "override_rate")
        assert override.level == AlertLevel.WARN

    def test_large_drop_is_critical(self, monitor: DriftMonitor):
        w = _steady_window()
        w.n_overrides = int(round(0.02 * w.n_runs))  # -0.18
        report = monitor.evaluate(w)
        override = _sig(report, "override_rate")
        assert override.level == AlertLevel.CRITICAL
        assert "fell" in override.message

    def test_large_rise_is_critical(self, monitor: DriftMonitor):
        w = _steady_window()
        w.n_overrides = int(round(0.50 * w.n_runs))  # +0.30
        report = monitor.evaluate(w)
        override = _sig(report, "override_rate")
        assert override.level == AlertLevel.CRITICAL
        assert "rose" in override.message


class TestReviewDurationSignals:
    def test_collapse_is_critical(self, monitor: DriftMonitor):
        w = _steady_window()
        # 70% drop (well over 2x tolerance of 30%)
        w.review_seconds = [30.0] * w.n_runs
        report = monitor.evaluate(w)
        review = _sig(report, "median_review_seconds")
        assert review.level == AlertLevel.CRITICAL

    def test_missing_durations_warn(self, monitor: DriftMonitor):
        w = _steady_window()
        w.review_seconds = []
        report = monitor.evaluate(w)
        review = _sig(report, "median_review_seconds")
        assert review.level == AlertLevel.WARN
        assert math.isnan(review.observed)


class TestHallucinationSignals:
    def test_spike_is_critical(self, monitor: DriftMonitor):
        w = _steady_window()
        # Half the runs hallucinate -> rate 0.5 vs baseline 0.02
        w.hallucination_scores = (
            [0.9] * (w.n_runs // 2) + [0.1] * (w.n_runs - w.n_runs // 2)
        )
        report = monitor.evaluate(w)
        hall = _sig(report, "hallucination_rate")
        assert hall.level == AlertLevel.CRITICAL


# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------


class TestGuards:
    def test_small_window_skips_eval(self, monitor: DriftMonitor):
        w = MetricWindow(
            n_runs=5,
            n_overrides=1,
            review_seconds=[180.0] * 5,
            hallucination_scores=[0.1] * 5,
        )
        report = monitor.evaluate(w)
        assert report.level == AlertLevel.OK
        assert report.signals == []
        assert any("below min_runs" in n for n in report.notes)

    def test_invalid_baseline_rejected(self):
        with pytest.raises(ValueError):
            BaselineSpec(override_rate=1.5).validate()
        with pytest.raises(ValueError):
            BaselineSpec(override_rate=0.1, median_review_seconds=-1).validate()

    def test_empty_agent_id_rejected(self, baseline: BaselineSpec):
        with pytest.raises(ValueError):
            DriftMonitor("", baseline)

    def test_min_runs_must_be_positive(self, baseline: BaselineSpec):
        with pytest.raises(ValueError):
            DriftMonitor("x", baseline, min_runs=0)


class TestCombineWindows:
    def test_combine_sums_counts_and_concatenates_samples(self):
        w1 = MetricWindow(
            n_runs=10, n_overrides=2,
            review_seconds=[1.0, 2.0], hallucination_scores=[0.1],
        )
        w2 = MetricWindow(
            n_runs=5, n_overrides=1,
            review_seconds=[3.0], hallucination_scores=[0.2, 0.3],
        )
        merged = combine_windows([w1, w2])
        assert merged.n_runs == 15
        assert merged.n_overrides == 3
        assert list(merged.review_seconds) == [1.0, 2.0, 3.0]
        assert list(merged.hallucination_scores) == [0.1, 0.2, 0.3]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _sig(report: DriftReport, name: str):
    match = [s for s in report.signals if s.name == name]
    assert len(match) == 1, f"signal {name!r} missing"
    return match[0]


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
