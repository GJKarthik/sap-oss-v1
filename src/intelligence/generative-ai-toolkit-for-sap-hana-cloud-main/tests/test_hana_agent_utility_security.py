import importlib.util
import unittest
from pathlib import Path
from unittest.mock import Mock


UTILITY_PATH = Path(__file__).resolve().parents[1] / 'src' / 'hana_ai' / 'agents' / 'hana_agent' / 'utility.py'
SPEC = importlib.util.spec_from_file_location('hana_agent_utility', UTILITY_PATH)
utility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(utility)


class TestHanaAgentUtilitySecurity(unittest.TestCase):
    def test_validate_sql_identifier_accepts_safe_and_rejects_unsafe_values(self):
        self.assertEqual(utility._validate_sql_identifier('SAFE_123'), 'SAFE_123')
        with self.assertRaises(ValueError):
            utility._validate_sql_identifier('unsafe-name')
        with self.assertRaises(ValueError):
            utility._validate_sql_identifier('x' * 129)

    def test_sql_builders_reject_unsafe_identifiers(self):
        with self.assertRaises(ValueError):
            utility._create_pse_sql_string({'key': 'k', 'certificate': 'c'}, 'BAD-NAME')
        with self.assertRaises(ValueError):
            utility._create_ai_core_remote_source_sql_string({}, 'BAD-NAME', 'SAFE_PSE')
        with self.assertRaises(ValueError):
            utility._call_agent_sql('q', {}, 'SAFE_SCHEMA', 'PROC;DROP')

    def test_sql_builders_escape_literals_after_validation(self):
        connection_context = Mock()

        utility._create_certificate_and_add_to_pse(
            connection_context,
            'SAFE_CERT',
            "line1'\nline2",
            'SAFE_PSE',
        )
        sql_calls = [call.args[0] for call in connection_context.execute_sql.call_args_list]
        self.assertEqual(
            sql_calls,
            [
                "CREATE CERTIFICATE SAFE_CERT FROM 'line1''\nline2'",
                'ALTER PSE SAFE_PSE ADD CERTIFICATE SAFE_CERT',
            ],
        )

        sql = utility._call_agent_sql("q'", {'k': "v'"}, 'SAFE_SCHEMA', 'SAFE_PROC')
        self.assertIn('CALL SAFE_SCHEMA.SAFE_PROC(', sql)
        self.assertIn('"q\'\'"', sql)
        self.assertIn('"v\'\'"', sql)


if __name__ == '__main__':
    unittest.main()

