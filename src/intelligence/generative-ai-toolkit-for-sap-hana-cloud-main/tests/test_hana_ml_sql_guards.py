import ast
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
UTILITY_PATH = ROOT / 'src' / 'hana_ai' / 'tools' / 'hana_ml_tools' / 'utility.py'
MEMORY_MANAGER_PATH = ROOT / 'src' / 'hana_ai' / 'mem0' / 'memory_manager.py'


def load_symbols(path, target_names, imports):
    source = path.read_text()
    module = ast.parse(source)
    snippets = list(imports)

    for node in module.body:
        name = getattr(node, 'name', None)
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in target_names:
                    snippets.append(ast.get_source_segment(source, node))
                    break
        elif isinstance(node, ast.FunctionDef) and name in target_names:
            snippets.append(ast.get_source_segment(source, node))

    namespace = {}
    exec('\n\n'.join(snippets), namespace)
    return namespace


UTILITY_SYMBOLS = load_symbols(
    UTILITY_PATH,
    {
        '_IDENTIFIER_PATTERN',
        'ALLOWED_SQL_PREFIXES',
        'BLOCKED_SQL_KEYWORDS',
        '_validate_identifier',
        '_sanitize_select_statement',
        '_create_temp_table',
    },
    ['from datetime import datetime', 'import re', 'import unicodedata'],
)
MEMORY_SYMBOLS = load_symbols(
    MEMORY_MANAGER_PATH,
    {'_IDENTIFIER_PATTERN', '_validate_identifier'},
    ['import re'],
)


class _FakeConn:
    def __init__(self):
        self.executed_sql = None

    def execute_sql(self, sql):
        self.executed_sql = sql


class TestHanaMlSqlGuards(unittest.TestCase):
    def test_create_temp_table_sanitizes_select_statement(self):
        create_temp_table = UTILITY_SYMBOLS['_create_temp_table']
        conn = _FakeConn()

        select_sql = 'SELECT * FROM source_table'
        result = create_temp_table(conn, select_sql, 'foo_tool', 'extra_info')

        self.assertRegex(conn.executed_sql, r'^CREATE LOCAL TEMPORARY TABLE #FOO_TOOL_EXTRA_INFO_[0-9]+ AS \(SELECT \* FROM source_table\)$')
        self.assertRegex(result, r'^SELECT \* FROM #FOO_TOOL_EXTRA_INFO_[0-9]+$')

    def test_create_temp_table_rejects_non_select_sql(self):
        create_temp_table = UTILITY_SYMBOLS['_create_temp_table']

        with self.assertRaisesRegex(ValueError, 'valid read-only SQL statement|SELECT or WITH'):
            create_temp_table(_FakeConn(), 'DELETE FROM source_table', 'foo_tool')

    def test_memory_manager_identifier_validation_rejects_sql_injection(self):
        validate_identifier = MEMORY_SYMBOLS['_validate_identifier']

        with self.assertRaisesRegex(ValueError, 'letters, numbers, and underscores'):
            validate_identifier('MEMORY" UNION SELECT * FROM USERS', 'table_name')


if __name__ == '__main__':
    unittest.main()