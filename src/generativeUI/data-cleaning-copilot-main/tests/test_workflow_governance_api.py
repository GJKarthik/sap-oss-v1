#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
import importlib.util
import json
import unittest
from pathlib import Path
from types import SimpleNamespace

from fastapi.testclient import TestClient


REPO_ROOT = Path(__file__).resolve().parents[1]
API_PATH = REPO_ROOT / "bin" / "api.py"


def _load_api_module():
    spec = importlib.util.spec_from_file_location("dcc_api_test_module", API_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load API module from {API_PATH}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _parse_sse_payloads(raw_body: bytes):
    text = raw_body.decode("utf-8")
    payloads = []
    for frame in text.strip().split("\n\n"):
        data_lines = [line[5:].strip() for line in frame.splitlines() if line.startswith("data:")]
        if data_lines:
            payloads.append(json.loads("\n".join(data_lines)))
    return payloads


class FakeCall:
    def __init__(self, call_type: str, **attrs):
        self.type = call_type
        for key, value in attrs.items():
            setattr(self, key, value)


class FakeInteractiveSession:
    def __init__(self, planned_response, execute_response: str = "Applied the planned workflow."):
        self.database = SimpleNamespace(generated_checks={}, check_generator_session_id="check-session")
        self._planned_response = planned_response
        self._execute_response = execute_response
        self.plan_requests = []
        self.executed_plans = []

    def plan_request(self, message: str):
        self.plan_requests.append(message)
        return self._planned_response

    def execute_planned_response(self, message: str, planned_response):
        self.executed_plans.append((message, planned_response))
        return self._execute_response

    def _get_session_history(self, session_id: str, limit: int = 10):
        return [
            {
                "role": "assistant",
                "content": f"history for {session_id}",
            }
        ]

    def _get_session_config(self, session_id: str):
        return {"sessionId": session_id, "mode": "fake"}


class TestWorkflowGovernanceApi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_api_module()

    def setUp(self):
        self.api._pending_workflow_reviews.clear()
        self.api._workflow_audit_log.clear()
        self.api._workflow_audit_counter = 0
        self.api._session_id = "workflow-main-session"
        self.api._session_model = "claude-4"
        self.api._agent_model = "claude-4"
        self.client = TestClient(self.api.app)

    def _set_interactive_session(self, planned_calls, execute_response="Applied the planned workflow."):
        planned_response = SimpleNamespace(output=SimpleNamespace(calls=planned_calls))
        session = FakeInteractiveSession(planned_response=planned_response, execute_response=execute_response)
        self.api._interactive_session = session
        return session, planned_response

    def test_run_workflow_requires_approval_for_planned_check_generation(self):
        session, _ = self._set_interactive_session(
            [FakeCall("check_generation_v3", force_regenerate=False)]
        )

        response = self.client.post("/api/workflow/run", json={"message": "Generate a new rule for invoice checks"})

        self.assertEqual(response.status_code, 200)
        events = _parse_sse_payloads(response.content)
        self.assertEqual(events[0]["type"], "run.started")
        self.assertEqual(events[1]["type"], "approval.required")
        review = events[1]["review"]
        self.assertEqual(review["requestKind"], "validation_rule_update")
        self.assertEqual(review["riskLevel"], "medium")
        self.assertEqual(review["plannedCalls"][0]["name"], "check_generation_v3")
        self.assertIn("Generate or update validation checks", review["plannedCalls"][0]["summary"])
        self.assertEqual(len(self.api._pending_workflow_reviews), 1)
        self.assertEqual(session.executed_plans, [])

        state_response = self.client.get("/api/workflow/state")
        self.assertEqual(state_response.status_code, 200)
        workflow_state = state_response.json()
        self.assertEqual(workflow_state["pendingReview"]["reviewId"], review["reviewId"])
        self.assertEqual(workflow_state["workflowRun"]["summary"]["runId"], events[0]["runId"])
        self.assertEqual(workflow_state["workflowRun"]["summary"]["status"], "awaiting_approval")

    def test_approved_review_resumes_same_run_and_executes_stored_plan(self):
        session, _ = self._set_interactive_session(
            [FakeCall("corrupt", corruptor_name="swap_values", percentage=0.15)],
            execute_response="Corruption workflow executed.",
        )

        initial_response = self.client.post("/api/workflow/run", json={"message": "Corrupt 15 percent of the rows"})
        initial_events = _parse_sse_payloads(initial_response.content)
        review_event = next(event for event in initial_events if event["type"] == "approval.required")
        review_id = review_event["review"]["reviewId"]
        run_id = review_event["runId"]
        stored_plan = self.api._pending_workflow_reviews[review_id]["plannedResponse"]

        approved_response = self.client.post(
            "/api/workflow/run",
            json={"message": "Corrupt 15 percent of the rows", "review_id": review_id},
        )

        self.assertEqual(approved_response.status_code, 200)
        approved_events = _parse_sse_payloads(approved_response.content)
        self.assertEqual([event["type"] for event in approved_events[:3]], ["run.started", "run.status", "run.status"])
        self.assertEqual(approved_events[0]["runId"], run_id)
        self.assertEqual(approved_events[-1]["type"], "run.finished")
        self.assertEqual(approved_events[-1]["runId"], run_id)
        self.assertEqual(len(session.executed_plans), 1)
        self.assertEqual(session.executed_plans[0][0], "Corrupt 15 percent of the rows")
        self.assertIs(session.executed_plans[0][1], stored_plan)
        self.assertNotIn(review_id, self.api._pending_workflow_reviews)

        state_response = self.client.get("/api/workflow/state")
        self.assertEqual(state_response.status_code, 200)
        workflow_state = state_response.json()
        self.assertIsNone(workflow_state["pendingReview"])
        self.assertEqual(workflow_state["workflowRun"]["summary"]["runId"], run_id)
        self.assertEqual(workflow_state["workflowRun"]["summary"]["status"], "completed")

    def test_reject_workflow_review_records_audit_and_removes_pending_review(self):
        self._set_interactive_session(
            [FakeCall("export_validation_result", directory="/tmp/findings")]
        )

        initial_response = self.client.post(
            "/api/workflow/run",
            json={"message": "Export the validation findings to /tmp/findings"},
        )
        initial_events = _parse_sse_payloads(initial_response.content)
        review_event = next(event for event in initial_events if event["type"] == "approval.required")
        review_id = review_event["review"]["reviewId"]

        reject_response = self.client.post(f"/api/workflow/reviews/{review_id}/reject")

        self.assertEqual(reject_response.status_code, 200)
        self.assertEqual(reject_response.json()["status"], "rejected")
        self.assertNotIn(review_id, self.api._pending_workflow_reviews)

        audit_response = self.client.get("/api/workflow/audit")
        self.assertEqual(audit_response.status_code, 200)
        audit_entries = audit_response.json()
        self.assertEqual(audit_entries[0]["eventType"], "approval.rejected")
        self.assertEqual(audit_entries[0]["reviewId"], review_id)
        self.assertEqual(audit_entries[1]["eventType"], "approval.required")

        state_response = self.client.get("/api/workflow/state")
        self.assertEqual(state_response.status_code, 200)
        workflow_state = state_response.json()
        self.assertIsNone(workflow_state["pendingReview"])
        self.assertEqual(workflow_state["workflowRun"]["summary"]["status"], "error")
        self.assertIn("Rejected before execution", workflow_state["workflowRun"]["summary"]["assistantResponse"])


if __name__ == "__main__":
    unittest.main()
