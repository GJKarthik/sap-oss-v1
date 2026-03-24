# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Integration tests for the agent workflow."""

import ast
import json
import os
import sys
import unittest
from typing import Dict, List, Any
from unittest.mock import MagicMock, patch, PropertyMock
import pandas as pd

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class MockDatabase:
    """Mock database for testing agent workflows."""

    def __init__(self, database_id: str = "test_db"):
        self.database_id = database_id
        self.table_data: Dict[str, pd.DataFrame] = {}
        self.checks: Dict[str, Any] = {}
        self.rule_based_checks: Dict[str, Any] = {}
        self._check_result_store = MockCheckResultStore()
        self._table_schemas: Dict[str, Any] = {}

    @property
    def check_result_store(self):
        return self._check_result_store

    def add_table(self, name: str, df: pd.DataFrame) -> None:
        """Add a table to the mock database."""
        self.table_data[name] = df

    def list_table_schemas(self) -> Dict[str, Any]:
        """Return mock table schemas."""
        schemas = {}
        for table_name, df in self.table_data.items():
            schema = MockTableSchema(
                table_name=table_name,
                columns=list(df.columns),
                dtypes={col: str(df[col].dtype) for col in df.columns},
            )
            schemas[table_name] = schema
        return schemas

    def list_checks(self) -> Dict[str, Any]:
        """Return all registered checks."""
        return {**self.rule_based_checks, **self.checks}

    def add_checks(self, checks: Dict[str, Any]) -> None:
        """Add checks to the database."""
        self.checks.update(checks)

    def remove_checks(self, check_names: List[str]) -> List[str]:
        """Remove checks by name."""
        removed = []
        for name in check_names:
            if name in self.checks:
                del self.checks[name]
                removed.append(name)
        return removed

    def get_table_data(self, table_name: str) -> pd.DataFrame:
        """Get data for a table."""
        if table_name not in self.table_data:
            raise KeyError(f"Table '{table_name}' not found")
        return self.table_data[table_name].copy()

    def validate(self) -> Dict[str, Any]:
        """Run all validation checks."""
        results = {}
        for check_name, check in self.checks.items():
            try:
                # Simulate validation
                results[check_name] = pd.DataFrame()  # Empty = no violations
            except Exception as e:
                results[check_name] = e
        return results

    def profile_table_data(self, table_name: str) -> Dict[str, Any]:
        """Profile a table's data."""
        if table_name not in self.table_data:
            raise KeyError(f"Table '{table_name}' not found")
        df = self.table_data[table_name]
        return {
            "row_count": len(df),
            "column_count": len(df.columns),
            "columns": {
                col: {"dtype": str(df[col].dtype), "null_count": int(df[col].isna().sum())}
                for col in df.columns
            },
        }

    def profile_table_column_data(self, table_name: str, column_name: str) -> Dict[str, Any]:
        """Profile a specific column."""
        if table_name not in self.table_data:
            raise KeyError(f"Table '{table_name}' not found")
        df = self.table_data[table_name]
        if column_name not in df.columns:
            raise KeyError(f"Column '{column_name}' not found in table '{table_name}'")
        col = df[column_name]
        return {
            "dtype": str(col.dtype),
            "null_count": int(col.isna().sum()),
            "unique_count": int(col.nunique()),
            "sample_values": col.head(5).tolist(),
        }

    def execute_query(self, query: Any) -> pd.DataFrame:
        """Execute a query function."""
        query_func = query.to_query_function()
        return query_func(self.table_data)


class MockTableSchema:
    """Mock table schema for testing."""

    def __init__(self, table_name: str, columns: List[str], dtypes: Dict[str, str]):
        self.table_name = table_name
        self.columns = columns
        self.dtypes = dtypes
        self.table_schema_json = json.dumps(
            {"table_name": table_name, "columns": {col: {"type": dtypes.get(col, "object")} for col in columns}}
        )

    def model_dump_json(self) -> str:
        return json.dumps(
            {"table_name": self.table_name, "columns": self.columns, "column_types": self.dtypes}
        )


class MockCheckResultStore:
    """Mock check result store."""

    def __init__(self):
        self._results: Dict[str, Any] = {}

    def get_result(self, check_name: str) -> Any:
        return self._results.get(check_name, pd.DataFrame())

    def has_check(self, check_name: str) -> bool:
        return check_name in self._results

    def summary(self, **kwargs) -> Any:
        """Return a mock summary."""
        return MockSummary()


class MockSummary:
    """Mock validation summary."""

    def model_dump_json(self, **kwargs) -> str:
        return json.dumps(
            {
                "total_checks": 0,
                "checks_with_violations": [],
                "checks_without_violations": [],
                "failed_checks": [],
            }
        )


class TestBaseAgent(unittest.TestCase):
    """Test the base agent class."""

    def setUp(self):
        """Set up test fixtures."""
        self.db = MockDatabase("test_db")

        # Add sample tables
        self.db.add_table(
            "Users",
            pd.DataFrame(
                {
                    "Id": [1, 2, 3, 4, 5],
                    "Name": ["Alice", "Bob", None, "David", "Eve"],
                    "Email": ["alice@test.com", "invalid-email", "charlie@test.com", None, "eve@test.com"],
                    "Age": [25, 30, 35, -5, 28],
                }
            ),
        )

        self.db.add_table(
            "Orders",
            pd.DataFrame(
                {
                    "OrderId": [101, 102, 103, 104],
                    "UserId": [1, 2, 99, 3],  # 99 is an orphan FK
                    "Amount": [100.0, 200.0, 150.0, -50.0],
                    "Status": ["completed", "pending", "invalid_status", "completed"],
                }
            ),
        )

    def test_handle_list_table_schemas(self):
        """Test that handle_list_table_schemas returns valid schema info."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        # Create a concrete subclass for testing
        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        result = agent.handle_list_table_schemas()

        self.assertIn("Table schemas", result)
        self.assertIn("Users", result)
        self.assertIn("Orders", result)

    def test_handle_list_checks_empty(self):
        """Test handle_list_checks with no checks registered."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        result = agent.handle_list_checks()

        self.assertIn("Found 0 checks", result)

    def test_handle_get_table_data(self):
        """Test handle_get_table_data returns correct data format."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        result = agent.handle_get_table_data("Users")

        self.assertIn("Users", result)
        self.assertIn("jsonl", result)
        self.assertIn("Alice", result)
        self.assertIn("Bob", result)

    def test_handle_get_table_data_nonexistent(self):
        """Test handle_get_table_data with nonexistent table."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        result = agent.handle_get_table_data("NonexistentTable")

        self.assertIn("Failed", result)

    def test_handle_profile_table_data(self):
        """Test handle_profile_table_data returns profiling info."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        result = agent.handle_profile_table_data("Users")

        self.assertIn("Profile", result)
        self.assertIn("row_count", result)
        self.assertIn("5", result)  # 5 rows

    def test_handle_remove_checks(self):
        """Test handle_remove_checks removes checks correctly."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        # Add a mock check
        mock_check = MagicMock()
        mock_check.function_name = "test_check"
        self.db.checks["test_check"] = mock_check
        agent.generated_checks["test_check"] = mock_check

        result = agent.handle_remove_checks(["test_check"])

        self.assertIn("Removed 1 checks", result)
        self.assertNotIn("test_check", agent.generated_checks)

    def test_add_generated_checks(self):
        """Test add_generated_checks adds to both tracking and database."""
        from definition.agents.base_agent import BaseCheckGenerationAgent

        class TestAgent(BaseCheckGenerationAgent):
            @property
            def version(self) -> str:
                return "test"

            def get_system_prompt(self) -> str:
                return "Test prompt"

            def generate_checks(self, **kwargs):
                return {}

        agent = TestAgent(
            database=self.db,
            session_manager=MagicMock(),
            config=MagicMock(),
        )

        mock_check = MagicMock()
        mock_check.function_name = "new_check"

        agent.add_generated_checks({"new_check": mock_check})

        self.assertIn("new_check", agent.generated_checks)
        self.assertIn("new_check", self.db.checks)


class TestCheckLogicValidation(unittest.TestCase):
    """Test CheckLogic code generation and validation."""

    def test_generated_code_is_syntactically_valid(self):
        """Verify that to_code() produces syntactically valid Python."""
        from definition.base.executable_code import CheckLogic

        check = CheckLogic(
            function_name="check_users_name_not_null",
            description="Check that Name column is not null",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Users", "Name")],
            body_lines=[
                "violations = {}",
                "users_df = tables.get('Users', pd.DataFrame())",
                "if not users_df.empty and 'Name' in users_df.columns:",
                "    null_mask = users_df['Name'].isna()",
                "    if null_mask.any():",
                "        invalid_series = pd.Series(users_df.index[null_mask].tolist())",
                "        invalid_series.name = 'Name'",
                "        violations['Users'] = invalid_series",
            ],
            return_statement="violations",
        )

        code = check.to_code()

        # Should parse without syntax errors
        try:
            ast.parse(code)
        except SyntaxError as e:
            self.fail(f"Generated code has syntax error: {e}\n\nCode:\n{code}")

    def test_generated_code_contains_function(self):
        """Verify that to_code() produces code with the named function."""
        from definition.base.executable_code import CheckLogic

        check = CheckLogic(
            function_name="my_validation_check",
            description="Test check",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("TestTable", "TestColumn")],
            body_lines=["violations = {}"],
            return_statement="violations",
        )

        code = check.to_code()
        tree = ast.parse(code)

        function_names = [node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)]

        self.assertIn("my_validation_check", function_names)

    def test_check_with_imports(self):
        """Verify that imports are included in generated code."""
        from definition.base.executable_code import CheckLogic

        check = CheckLogic(
            function_name="check_with_imports",
            description="Test check with imports",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("TestTable", "TestColumn")],
            imports=["import re", "from datetime import datetime"],
            body_lines=[
                "violations = {}",
                "pattern = re.compile(r'^[a-z]+$')",
            ],
            return_statement="violations",
        )

        code = check.to_code()

        self.assertIn("import re", code)
        self.assertIn("from datetime import datetime", code)

    def test_check_to_dict_serialization(self):
        """Verify that to_dict() produces serializable output."""
        from definition.base.executable_code import CheckLogic

        check = CheckLogic(
            function_name="test_check",
            description="Test check description",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Table1", "Col1"), ("Table2", "Col2")],
            body_lines=["violations = {}"],
            return_statement="violations",
            sql="SELECT * FROM Table1 WHERE Col1 IS NULL",
        )

        check_dict = check.to_dict()

        # Should be JSON serializable
        json_str = json.dumps(check_dict)
        self.assertIsInstance(json_str, str)

        # Should contain expected keys
        self.assertEqual(check_dict["function_name"], "test_check")
        self.assertEqual(check_dict["description"], "Test check description")
        self.assertEqual(check_dict["scope"], [("Table1", "Col1"), ("Table2", "Col2")])
        self.assertEqual(check_dict["sql"], "SELECT * FROM Table1 WHERE Col1 IS NULL")


class TestCorruptionLogicValidation(unittest.TestCase):
    """Test CorruptionLogic code generation."""

    def test_corruption_logic_code_generation(self):
        """Verify CorruptionLogic generates valid code."""
        from definition.base.executable_code import CorruptionLogic

        corruption = CorruptionLogic(
            function_name="corrupt_users_name",
            description="Corrupt Name column with nulls",
            parameters="table_data: Mapping[str, pd.DataFrame], rand: random.Random, percentage: float",
            scope=[("Users", "Name")],
            corruption_percentage=0.1,
            body_lines=[
                "modified_tables = {}",
                "if 'Users' in table_data:",
                "    df = table_data['Users'].copy()",
                "    if 'Name' in df.columns:",
                "        num_corrupt = int(len(df) * percentage)",
                "        if num_corrupt > 0:",
                "            indices = rand.sample(range(len(df)), min(num_corrupt, len(df)))",
                "            df.loc[indices, 'Name'] = None",
                "            modified_tables['Users'] = df",
            ],
            return_statement="modified_tables if modified_tables else {}",
        )

        code = corruption.to_code()

        # Should parse without syntax errors
        try:
            ast.parse(code)
        except SyntaxError as e:
            self.fail(f"Generated corruption code has syntax error: {e}\n\nCode:\n{code}")


class TestSandboxSecurityEnforcement(unittest.TestCase):
    """Test that sandbox security is enforced."""

    def test_subprocess_always_used(self):
        """Verify that use_subprocess=False still uses subprocess (deprecated parameter)."""
        from definition.base.executable_code import execute_sandboxed_function

        # Simple safe function
        code = """
def safe_add(a, b):
    return a + b
"""
        # Even with use_subprocess=False, should still use subprocess
        result, error = execute_sandboxed_function(
            func_code=code,
            func_name="safe_add",
            args=(2, 3),
            use_subprocess=False,  # Deprecated, should be ignored
        )

        # Should succeed via subprocess
        self.assertIsNone(error)
        self.assertEqual(result, 5)

    def test_blocked_import_rejected(self):
        """Verify that blocked imports are rejected."""
        from definition.base.executable_code import execute_sandboxed_function

        code = """
import os

def dangerous_func():
    return os.getcwd()
"""
        result, error = execute_sandboxed_function(
            func_code=code,
            func_name="dangerous_func",
            args=(),
        )

        self.assertIsNotNone(error)

    def test_blocked_call_rejected(self):
        """Verify that blocked calls are rejected."""
        from definition.base.executable_code import execute_sandboxed_function

        code = """
def dangerous_func():
    return eval("1 + 1")
"""
        result, error = execute_sandboxed_function(
            func_code=code,
            func_name="dangerous_func",
            args=(),
        )

        self.assertIsNotNone(error)

    def test_allowed_imports_work(self):
        """Verify that allowed imports (pandas, numpy, etc.) work."""
        from definition.base.executable_code import execute_sandboxed_function

        code = """
import pandas as pd
import numpy as np

def allowed_func():
    df = pd.DataFrame({'a': [1, 2, 3]})
    return len(df)
"""
        result, error = execute_sandboxed_function(
            func_code=code,
            func_name="allowed_func",
            args=(),
        )

        self.assertIsNone(error)
        self.assertEqual(result, 3)


if __name__ == "__main__":
    unittest.main()