import sys
import types
import unittest
from pathlib import Path
from unittest.mock import Mock


PROJECT_ROOT = Path(__file__).resolve().parents[3]
SRC_ROOT = PROJECT_ROOT / 'src'
if str(SRC_ROOT) not in sys.path:
    sys.path.insert(0, str(SRC_ROOT))

fake_pandas = types.ModuleType('pandas')
fake_pandas.DataFrame = Mock()

fake_hana_ml = types.ModuleType('hana_ml')
fake_dataframe = types.ModuleType('hana_ml.dataframe')
fake_dataframe.create_dataframe_from_pandas = Mock()


class FakeConnectionContext:  # pragma: no cover
    pass


fake_hana_ml.ConnectionContext = FakeConnectionContext
fake_hana_ml.dataframe = fake_dataframe
sys.modules.setdefault('pandas', fake_pandas)
sys.modules.setdefault('hana_ml', fake_hana_ml)
sys.modules.setdefault('hana_ml.dataframe', fake_dataframe)

from hana_ai.vectorstore.hana_vector_engine import HANAMLinVectorEngine


class _FakeCollectedResult:
    def __init__(self):
        self.shape = (1, 3)
        self.iloc = self
        self._rows = [['matched_example', 0.99, 'model-id']]

    def __getitem__(self, item):
        row_index, column_index = item
        return self._rows[row_index][column_index]


class TestHANAMLinVectorEngineSecurity(unittest.TestCase):
    def _make_connection(self):
        connection = Mock()
        connection.get_current_schema.return_value = 'SAFE_SCHEMA'
        connection.has_table.return_value = True
        connection.table.return_value.columns = ['id', 'description', 'example', 'embeddings']
        connection.sql.return_value.collect.return_value = _FakeCollectedResult()
        return connection

    def test_rejects_unsafe_identifiers(self):
        connection = self._make_connection()
        with self.assertRaises(ValueError):
            HANAMLinVectorEngine(connection, 'unsafe-table')
        with self.assertRaises(ValueError):
            HANAMLinVectorEngine(connection, 'safe_table', schema='bad schema')

    def test_rejects_unknown_model_version(self):
        connection = self._make_connection()
        with self.assertRaises(ValueError):
            HANAMLinVectorEngine(connection, 'safe_table', model_version='DROP TABLE users')

    def test_query_rejects_unknown_distance(self):
        connection = self._make_connection()
        engine = HANAMLinVectorEngine(connection, 'safe_table')
        with self.assertRaises(ValueError):
            engine.query('hello', distance='COSINE_SIMILARITY; DROP TABLE demo')

    def test_query_uses_bound_parameters(self):
        connection = self._make_connection()
        engine = HANAMLinVectorEngine(connection, 'safe_table')

        result = engine.query("abc'; DROP TABLE demo;--", top_n=1)

        self.assertEqual(result, 'matched_example')
        sql = connection.sql.call_args.args[0]
        parameters = connection.sql.call_args.kwargs['parameters']
        self.assertIn('VECTOR_EMBEDDING(?, \'QUERY\', ?)', sql)
        self.assertNotIn('DROP TABLE demo', sql)
        self.assertEqual(parameters, ["abc'; DROP TABLE demo;--", 'SAP_NEB.20240715'])


if __name__ == '__main__':
    unittest.main()