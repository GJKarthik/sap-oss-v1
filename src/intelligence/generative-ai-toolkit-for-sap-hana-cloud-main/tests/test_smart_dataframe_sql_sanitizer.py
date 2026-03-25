import ast
from pathlib import Path
import unittest


SMART_DATAFRAME_PATH = Path(__file__).resolve().parents[1] / 'src' / 'hana_ai' / 'smart_dataframe.py'
TARGET_NAMES = {
    'ALLOWED_SQL_PREFIXES',
    'BLOCKED_SQL_KEYWORDS',
    '_sanitize_select_statement',
}


def load_sanitizer():
    source = SMART_DATAFRAME_PATH.read_text()
    module = ast.parse(source)
    snippets = ['import re', 'import unicodedata']

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
    return namespace['_sanitize_select_statement']


class TestSmartDataFrameSqlSanitizer(unittest.TestCase):
    def setUp(self):
        self.sanitize = load_sanitizer()

    def test_allows_ascii_select(self):
        self.assertEqual(self.sanitize('SELECT * FROM my_table'), 'SELECT * FROM my_table')

    def test_blocks_zero_width_keyword_obfuscation(self):
        with self.assertRaisesRegex(ValueError, 'Non-printable or format characters'):
            self.sanitize('SELECT * FROM t DR\u200bOP TABLE u')

    def test_blocks_homoglyph_keyword_obfuscation(self):
        with self.assertRaisesRegex(ValueError, 'Only ASCII SQL statements are allowed'):
            self.sanitize('SELECT * FROM t DRΟP TABLE u')


if __name__ == '__main__':
    unittest.main()