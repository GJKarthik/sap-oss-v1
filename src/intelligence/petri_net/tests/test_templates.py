"""Tests for workflow templates."""

import pytest

from petri_net.core import TokenColour
from petri_net.engine import CPNEngine
from petri_net.templates import training_pipeline_net, ocr_batch_net, model_deploy_net


class TestTrainingPipeline:
    def test_runs_to_completion(self):
        net = training_pipeline_net()
        engine = CPNEngine(net)
        steps = engine.run(max_steps=100)
        assert steps > 0
        # Final "done" place should have a token
        m = engine.marking()
        assert len(m["done"]) == 1
        # Start should be empty
        assert len(m["start"]) == 0

    def test_no_deadlock(self):
        net = training_pipeline_net()
        engine = CPNEngine(net)
        engine.run(max_steps=100)
        assert not engine.is_deadlocked()

    def test_history_contains_all_stages(self):
        net = training_pipeline_net()
        engine = CPNEngine(net)
        engine.run(max_steps=100)
        fired = [name for name, _ in engine.history]
        for stage in ["preconvert", "build", "extract_schema",
                      "parse_templates", "expand", "generate",
                      "validate", "arabic"]:
            assert stage in fired, f"Stage '{stage}' did not fire"


class TestOCRBatch:
    def test_all_documents_processed(self):
        n = 4
        net = ocr_batch_net(n_documents=n)
        engine = CPNEngine(net)
        engine.run(max_steps=100)
        m = engine.marking()
        assert len(m["done"]) == n
        assert len(m["queue"]) == 0
        # All slots returned
        assert len(m["worker_slots"]) == 3

    def test_concurrency_limit(self):
        """At most 3 documents processing simultaneously."""
        net = ocr_batch_net(n_documents=10)
        engine = CPNEngine(net)
        # Step through and check processing never exceeds 3
        for _ in range(200):
            m = engine.marking()
            assert len(m["processing"]) <= 3
            if not engine.step():
                break
        m = engine.marking()
        assert len(m["done"]) == 10

    def test_completes_correctly(self):
        """After all docs processed, worker slots are returned (resource pool pattern).
        The engine reports this as soft-deadlock since worker_slots is non-terminal."""
        net = ocr_batch_net(n_documents=3)
        engine = CPNEngine(net)
        engine.run(max_steps=100)
        m = engine.marking()
        # All docs done, all slots returned, queue and processing empty
        assert len(m["done"]) == 3
        assert len(m["worker_slots"]) == 3
        assert len(m["queue"]) == 0
        assert len(m["processing"]) == 0


class TestModelDeploy:
    def test_runs_to_completion(self):
        net = model_deploy_net()
        engine = CPNEngine(net)
        steps = engine.run(max_steps=50)
        assert steps == 5  # 5 sequential stages
        m = engine.marking()
        assert len(m["promoted"]) == 1
        assert len(m["start"]) == 0

    def test_sequential_order(self):
        net = model_deploy_net()
        engine = CPNEngine(net)
        engine.run(max_steps=50)
        fired = [name for name, _ in engine.history]
        expected_order = ["export", "deploy", "health_check", "smoke_test", "promote"]
        assert fired == expected_order

    def test_no_deadlock(self):
        net = model_deploy_net()
        engine = CPNEngine(net)
        engine.run(max_steps=50)
        assert not engine.is_deadlocked()
