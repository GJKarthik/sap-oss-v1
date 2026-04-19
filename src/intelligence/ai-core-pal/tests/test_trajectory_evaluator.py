# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 SAP SE
"""Unit tests for the trajectory-level evaluator.

Run: pytest tests/test_trajectory_evaluator.py -v

No HANA / network dependencies; designed to run in CI on every push
so that MAS MGF §2.3.2 (REG-MGF-2.3.2-002) control coverage does not
regress silently.
"""
from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from evaluation import (
    Step,
    ToolPolicy,
    Trajectory,
    TrajectoryEvaluator,
    TrajectoryScore,
)
from evaluation.trajectory_evaluator import default_tb_policy


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def evaluator() -> TrajectoryEvaluator:
    return TrajectoryEvaluator(default_tb_policy())


def _clean_trajectory() -> Trajectory:
    return Trajectory(
        agent_id="tb-review-agent",
        goal="review FY2026 Q1 trial balance for Africa GFS",
        scope="read-write",
        tenant="africa-gfs",
        steps=[
            Step(
                index=1,
                tool="fetch_trial_balance",
                args={"legal_entity": "KE01", "period": "2026Q1"},
                outcome="success",
                progress=0.3,
                tenant="africa-gfs",
            ),
            Step(
                index=2,
                tool="call_pal_anomaly",
                args={"input_data": [1, 2, 3]},
                outcome="success",
                progress=0.6,
            ),
            Step(
                index=3,
                tool="write_review_note",
                args={
                    "legal_entity": "KE01",
                    "period": "2026Q1",
                    "body": "ok",
                },
                outcome="success",
                progress=1.0,
                tenant="africa-gfs",
            ),
        ],
    )


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


class TestHappyPath:
    def test_clean_trajectory_passes(self, evaluator: TrajectoryEvaluator):
        score = evaluator.score(_clean_trajectory())
        assert isinstance(score, TrajectoryScore)
        assert score.tool_correctness == pytest.approx(1.0)
        assert score.policy_adherence == pytest.approx(1.0)
        assert score.goal_progression == pytest.approx(1.0)
        assert score.overall == pytest.approx(1.0)
        assert score.violations == []
        assert score.passed()

    def test_as_dict_roundtrips(self, evaluator: TrajectoryEvaluator):
        score = evaluator.score(_clean_trajectory())
        d = score.as_dict()
        assert d["overall"] == pytest.approx(1.0)
        assert d["violations"] == []


# ---------------------------------------------------------------------------
# Tool correctness
# ---------------------------------------------------------------------------


class TestToolCorrectness:
    def test_disallowed_tool_penalised(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        traj.steps.insert(
            1,
            Step(
                index=99,
                tool="rm_rf",  # not in policy
                args={},
                outcome="success",
                progress=0.4,
            ),
        )
        score = evaluator.score(traj)
        assert score.tool_correctness < 1.0
        assert any("not in allow-list" in v for v in score.violations)

    def test_missing_required_arg_penalised(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        # drop a required arg
        traj.steps[0].args.pop("period")
        score = evaluator.score(traj)
        assert score.tool_correctness < 1.0
        assert any("missing required arg" in v for v in score.violations)

    def test_invalid_outcome_penalised(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        traj.steps[0].outcome = "kinda-worked"
        score = evaluator.score(traj)
        assert score.tool_correctness < 1.0
        assert any("outcome" in v for v in score.violations)


# ---------------------------------------------------------------------------
# Policy adherence
# ---------------------------------------------------------------------------


class TestPolicyAdherence:
    def test_write_in_read_only_trajectory_penalised(
        self, evaluator: TrajectoryEvaluator
    ):
        traj = _clean_trajectory()
        traj.scope = "read-only"
        score = evaluator.score(traj)
        assert score.policy_adherence < 1.0
        assert any(
            "read-only trajectory" in v for v in score.violations
        ), score.violations

    def test_tenant_leak_penalised(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        # step 1 fetches trial balance for a different tenant than the
        # trajectory scope.
        traj.steps[0].tenant = "europe-gfs"
        score = evaluator.score(traj)
        assert score.policy_adherence < 1.0
        assert any("outside scope" in v for v in score.violations)

    def test_invalid_scope_rejected(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        traj.scope = "whatever"
        with pytest.raises(ValueError):
            evaluator.score(traj)


# ---------------------------------------------------------------------------
# Goal progression
# ---------------------------------------------------------------------------


class TestGoalProgression:
    def test_flat_zero_scores_zero(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        for s in traj.steps:
            s.progress = 0.0
        score = evaluator.score(traj)
        assert score.goal_progression == pytest.approx(0.0)

    def test_regression_penalised(self, evaluator: TrajectoryEvaluator):
        traj = _clean_trajectory()
        traj.steps[1].progress = 0.1  # went backwards from 0.3
        score = evaluator.score(traj)
        assert score.goal_progression < 1.0
        assert any("regressed" in v for v in score.violations)

    def test_out_of_range_progress_flagged(
        self, evaluator: TrajectoryEvaluator
    ):
        traj = _clean_trajectory()
        traj.steps[0].progress = 1.5
        score = evaluator.score(traj)
        assert any("outside [0, 1]" in v for v in score.violations)


# ---------------------------------------------------------------------------
# Construction edge cases
# ---------------------------------------------------------------------------


class TestConstruction:
    def test_empty_policy_rejected(self):
        with pytest.raises(ValueError):
            TrajectoryEvaluator([])

    def test_duplicate_policy_rejected(self):
        with pytest.raises(ValueError):
            TrajectoryEvaluator(
                [
                    ToolPolicy(name="dup"),
                    ToolPolicy(name="dup"),
                ]
            )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
