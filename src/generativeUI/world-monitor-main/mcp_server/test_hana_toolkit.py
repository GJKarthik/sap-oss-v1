"""Unit tests for the HANA toolkit MCP integration."""

import os
import sys
import unittest


_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
for _path in (_here, _root):
    if _path not in sys.path:
        sys.path.insert(0, _path)


import hana_toolkit


class FakeCursor:
    def __init__(self, rows, description):
        self._rows = rows
        self.description = description

    def execute(self, _sql, _params=None):
        return None

    def fetchmany(self, limit):
        return self._rows[:limit]

    def fetchone(self):
        return (1,)

    def close(self):
        return None


class FakeConnection:
    def __init__(self, rows, description):
        self._rows = rows
        self._description = description
        self.closed = False

    def cursor(self):
        return FakeCursor(self._rows, self._description)

    def close(self):
        self.closed = True


class FakeDbApi:
    def __init__(self, rows, description):
        self._rows = rows
        self._description = description

    def connect(self, **_kwargs):
        return FakeConnection(self._rows, self._description)


class HanaToolkitTests(unittest.TestCase):
    def test_query_uses_mock_rows_when_hana_not_configured(self):
        server = hana_toolkit.HanaToolkitServer(clock=lambda: 1_710_000_000.0)
        result = server.query({"sql": "SELECT * FROM AI_GOVERNANCE.DIMENSION_FACTS"})

        self.assertEqual(result["source"], "mock")
        self.assertTrue(result["degraded"])
        self.assertGreater(result["count"], 0)

    def test_query_rejects_non_readonly_sql(self):
        server = hana_toolkit.HanaToolkitServer()
        result = server.query({"sql": "DELETE FROM AI_GOVERNANCE.AUDIT_LOGS"})

        self.assertIn("Only read-only", result["error"])

    def test_vector_search_returns_ranked_matches(self):
        server = hana_toolkit.HanaToolkitServer()
        result = server.vector_search({"query": "fairness competitor analysis", "limit": 2})

        self.assertEqual(result["count"], 1)
        self.assertEqual(result["matches"][0]["metadata"]["dimension"], "fairness")

    def test_get_governance_facts_filters_by_action(self):
        server = hana_toolkit.HanaToolkitServer()
        result = server.get_governance_facts({"action": "impact_assessment"})

        self.assertEqual(result["count"], 2)
        self.assertTrue(all(fact["action"] == "impact_assessment" for fact in result["facts"]))
        self.assertIn("DIMENSION_FACTS", result["schemaSql"])

    def test_get_audit_logs_returns_ai_decision_shape(self):
        server = hana_toolkit.HanaToolkitServer(clock=lambda: 1_710_000_000.0)
        result = server.get_audit_logs({"limit": 2, "service": "world-monitor"})

        self.assertEqual(result["count"], 2)
        self.assertIn("traceId", result["decisions"][0])
        self.assertIn(result["decisions"][0]["outcome"], {"allowed", "blocked", "anonymised"})

    def test_resolve_mangle_predicate_uses_governance_facts(self):
        server = hana_toolkit.HanaToolkitServer()
        result = server.resolve_mangle_predicate("subject_to_review", ["impact_assessment"])

        self.assertEqual(len(result), 2)
        self.assertTrue(all(row["result"] for row in result))

    def test_query_uses_dbapi_when_configured(self):
        config = hana_toolkit.HanaToolkitConfig(
            host="hana.example.local",
            user="tester",
            password="secret",
        )
        fake_dbapi = FakeDbApi(rows=[("accountability",)], description=[("DIMENSION_NAME",)])
        server = hana_toolkit.HanaToolkitServer(config=config, dbapi_module=fake_dbapi)
        result = server.query({"sql": "SELECT DIMENSION_NAME FROM AI_GOVERNANCE.DIMENSION_FACTS"})

        self.assertEqual(result["source"], "hana")
        self.assertFalse(result["degraded"])
        self.assertEqual(result["rows"][0]["DIMENSION_NAME"], "accountability")


if __name__ == "__main__":
    unittest.main()