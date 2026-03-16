import ast
from datetime import datetime
from pathlib import Path
import unittest


TARGET_PATH = Path(__file__).resolve().parents[1] / 'src' / 'hana_ai' / 'tools' / 'hana_ml_tools' / 'ts_make_predict_table.py'
TARGET_NAMES = {
    '_IDENTIFIER_PATTERN',
    '_NUMERIC_LITERAL_PATTERN',
    '_DATETIME_LITERAL_PATTERN',
    '_ALLOWED_INCREMENT_TYPES',
    '_validate_identifier',
    '_validate_numeric_literal',
    '_validate_datetime_literal',
    '_normalize_increment_type',
    '_format_group_literal',
}


def load_symbols():
    source = TARGET_PATH.read_text()
    module = ast.parse(source)
    snippets = ['from datetime import date, datetime', 'import math', 'import numbers', 'import re']

    for node in module.body:
        name = getattr(node, 'name', None)
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in TARGET_NAMES:
                    snippets.append(ast.get_source_segment(source, node))
                    break
        elif isinstance(node, ast.FunctionDef) and name in TARGET_NAMES:
            snippets.append(ast.get_source_segment(source, node))

    namespace = {}
    exec('\n\n'.join(snippets), namespace)
    return namespace


SYMBOLS = load_symbols()


class TestTSMakePredictTableSecurity(unittest.TestCase):
    def test_identifier_validation_rejects_injection_payloads(self):
        validate_identifier = SYMBOLS['_validate_identifier']

        self.assertEqual(validate_identifier('SAFE_KEY_1', 'key'), 'SAFE_KEY_1')
        with self.assertRaisesRegex(ValueError, 'letters, numbers, and underscores'):
            validate_identifier('key" UNION SELECT * FROM users', 'key')

    def test_datetime_literal_validation_blocks_sql_metacharacters(self):
        validate_datetime_literal = SYMBOLS['_validate_datetime_literal']

        self.assertEqual(
            validate_datetime_literal(datetime(2024, 1, 2, 3, 4, 5)),
            '2024-01-02 03:04:05',
        )
        with self.assertRaisesRegex(ValueError, 'safe datetime string'):
            validate_datetime_literal("2024-01-02 03:04:05'; DROP TABLE T --")

    def test_increment_type_allowlist_normalizes_known_units(self):
        normalize_increment_type = SYMBOLS['_normalize_increment_type']

        self.assertEqual(normalize_increment_type('day', 172800), ('DAYS', 2))
        self.assertEqual(normalize_increment_type('week', 1209600), ('DAYS', 14))
        self.assertEqual(normalize_increment_type('quarter', 7776000), ('MONTHS', 3))
        with self.assertRaisesRegex(ValueError, 'Unsupported increment_type'):
            normalize_increment_type('day; DROP TABLE x', 86400)

    def test_group_literal_validation_rejects_unsafe_string_groups(self):
        format_group_literal = SYMBOLS['_format_group_literal']

        self.assertEqual(format_group_literal(42, 'INTEGER'), '42')
        self.assertEqual(format_group_literal('GROUP_1', 'VARCHAR'), "'GROUP_1'")
        with self.assertRaisesRegex(ValueError, 'letters, numbers, and underscores'):
            format_group_literal("group' OR 1=1 --", 'VARCHAR')


if __name__ == '__main__':
    unittest.main()