# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
End-to-end workflow tests for Data Cleaning Copilot.

These tests verify the complete workflow from data loading through
check generation to validation, using mocked LLM responses.
"""

import json
import os
import sys
import unittest
from typing import Any, Dict, List
from unittest.mock import MagicMock, patch, PropertyMock
import pandas as pd

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# =============================================================================
# Mock LLM Response Generator
# =============================================================================


class MockLLMResponseGenerator:
    """
    Generates realistic mock LLM responses for testing.
    
    Simulates the structured output that the LLM would produce
    for check generation requests.
    """

    @staticmethod
    def generate_check_batch(table_schemas: List[Dict]) -> Dict[str, Any]:
        """
        Generate a CheckBatch response based on table schemas.
        
        Parameters
        ----------
        table_schemas : List[Dict]
            List of table schema definitions
            
        Returns
        -------
        Dict[str, Any]
            CheckBatch-compatible structured response
        """
        checks = []
        
        for schema in table_schemas:
            table_name = schema.get("table_name", "Unknown")
            columns = schema.get("columns", [])
            
            # Generate null check for first column
            if columns:
                col_name = columns[0] if isinstance(columns[0], str) else columns[0].get("name", "id")
                checks.append({
                    "function_name": f"check_{table_name.lower()}_{col_name.lower()}_not_null",
                    "description": f"Validates that {col_name} is not null in {table_name}",
                    "parameters": "tables: Mapping[str, pd.DataFrame]",
                    "scope": [[table_name, col_name]],
                    "imports": [],
                    "body_lines": [
                        "violations = {}",
                        f"df = tables.get('{table_name}', pd.DataFrame())",
                        f"if not df.empty and '{col_name}' in df.columns:",
                        f"    null_mask = df['{col_name}'].isna()",
                        "    if null_mask.any():",
                        "        invalid_series = pd.Series(df.index[null_mask].tolist())",
                        f"        invalid_series.name = '{col_name}'",
                        f"        violations['{table_name}'] = invalid_series",
                    ],
                    "return_statement": "violations",
                    "sql": f"SELECT * FROM {table_name} WHERE {col_name} IS NULL",
                })
        
        return {"checks": checks}

    @staticmethod
    def generate_tool_response(tool_name: str, args: Dict[str, Any]) -> str:
        """Generate a mock tool call response."""
        if tool_name == "ListTableSchemas":
            return json.dumps([
                {"table_name": "Users", "columns": ["Id", "Name", "Email"]},
                {"table_name": "Orders", "columns": ["OrderId", "UserId", "Amount"]},
            ])
        elif tool_name == "GetTableData":
            return json.dumps({"rows": 5, "sample": [{"Id": 1, "Name": "Test"}]})
        elif tool_name == "Validate":
            return json.dumps({"total_violations": 0, "checks_passed": True})
        return json.dumps({"status": "ok"})


# =============================================================================
# Mock Database Fixture
# =============================================================================


def create_test_database():
    """Create a mock database with test data."""
    from tests.test_agent_workflow_integration import MockDatabase
    
    db = MockDatabase("e2e_test_db")
    
    # Users table with some data quality issues
    db.add_table(
        "Users",
        pd.DataFrame({
            "Id": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            "Name": ["Alice", "Bob", None, "David", "", "Eve", "Frank", None, "Helen", "Ivan"],
            "Email": [
                "alice@test.com",
                "invalid-email",  # Invalid format
                "charlie@test.com",
                None,  # Null
                "eve@test.com",
                "duplicate@test.com",
                "duplicate@test.com",  # Duplicate
                "helen@test.com",
                "helen@test.com",
                "ivan@test.com",
            ],
            "Age": [25, 30, 35, -5, 28, 150, 22, 45, 33, 0],  # -5 and 150 are invalid
            "Status": ["active", "active", "inactive", "pending", "ACTIVE", "inactive", "Active", "active", "deleted", "active"],
        })
    )
    
    # Orders table with FK issues
    db.add_table(
        "Orders",
        pd.DataFrame({
            "OrderId": [101, 102, 103, 104, 105, 106],
            "UserId": [1, 2, 99, 3, 1, 100],  # 99 and 100 don't exist in Users
            "Amount": [100.0, -50.0, 150.0, 0.0, 75.5, 200.0],  # -50 is invalid
            "Status": ["completed", "pending", "shipped", "cancelled", "completed", "invalid_status"],
        })
    )
    
    # Products table
    db.add_table(
        "Products",
        pd.DataFrame({
            "ProductId": [1, 2, 3, 4, 5],
            "Name": ["Widget A", "Widget B", None, "Widget D", ""],
            "Price": [10.0, 20.0, -5.0, 0.0, 100.0],  # -5 is invalid
            "Category": ["Electronics", "Electronics", "Clothing", None, "Home"],
        })
    )
    
    return db


# =============================================================================
# E2E Test Cases
# =============================================================================


class TestE2ECheckGeneration(unittest.TestCase):
    """End-to-end tests for check generation workflow."""

    def setUp(self):
        """Set up test fixtures."""
        self.db = create_test_database()
        self.mock_response_gen = MockLLMResponseGenerator()

    def test_complete_workflow_generates_valid_checks(self):
        """Test that a complete workflow generates syntactically valid checks."""
        from definition.base.executable_code import CheckLogic
        import ast
        
        # Generate mock check batch
        schemas = [
            {"table_name": "Users", "columns": ["Id", "Name", "Email"]},
            {"table_name": "Orders", "columns": ["OrderId", "UserId", "Amount"]},
        ]
        check_batch = self.mock_response_gen.generate_check_batch(schemas)
        
        # Verify checks are syntactically valid
        for check_data in check_batch["checks"]:
            check = CheckLogic(**check_data)
            code = check.to_code()
            
            # Should parse without syntax errors
            try:
                ast.parse(code)
            except SyntaxError as e:
                self.fail(f"Generated code has syntax error: {e}\n\nCode:\n{code}")
            
            # Should have the expected function name
            self.assertIn(f"def {check.function_name}", code)

    def test_generated_checks_find_known_violations(self):
        """Test that generated checks find known data quality issues."""
        from definition.base.executable_code import CheckLogic
        
        # Create a check that should find null Names
        check = CheckLogic(
            function_name="check_users_name_not_null",
            description="Check for null Names",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Users", "Name")],
            body_lines=[
                "violations = {}",
                "df = tables.get('Users', pd.DataFrame())",
                "if not df.empty and 'Name' in df.columns:",
                "    null_mask = df['Name'].isna()",
                "    if null_mask.any():",
                "        invalid_series = pd.Series(df.index[null_mask].tolist())",
                "        invalid_series.name = 'Name'",
                "        violations['Users'] = invalid_series",
            ],
            return_statement="violations",
        )
        
        # Execute the check
        validation_fn = check.to_validation_function()
        result = validation_fn(self.db.table_data)
        
        # Should find the null Names (indices 2 and 7)
        self.assertIn("Users", result)
        violation_indices = result["Users"].tolist()
        self.assertIn(2, violation_indices)  # None at index 2
        self.assertIn(7, violation_indices)  # None at index 7

    def test_check_for_negative_values(self):
        """Test check that finds negative values in Age column."""
        from definition.base.executable_code import CheckLogic
        
        check = CheckLogic(
            function_name="check_users_age_non_negative",
            description="Check that Age is non-negative",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Users", "Age")],
            body_lines=[
                "violations = {}",
                "df = tables.get('Users', pd.DataFrame())",
                "if not df.empty and 'Age' in df.columns:",
                "    invalid_mask = df['Age'] < 0",
                "    if invalid_mask.any():",
                "        invalid_series = pd.Series(df.index[invalid_mask].tolist())",
                "        invalid_series.name = 'Age'",
                "        violations['Users'] = invalid_series",
            ],
            return_statement="violations",
        )
        
        validation_fn = check.to_validation_function()
        result = validation_fn(self.db.table_data)
        
        # Should find the negative Age at index 3
        self.assertIn("Users", result)
        self.assertIn(3, result["Users"].tolist())

    def test_check_for_orphan_foreign_keys(self):
        """Test check that finds orphan foreign keys."""
        from definition.base.executable_code import CheckLogic
        
        check = CheckLogic(
            function_name="check_orders_userid_fk",
            description="Check that Orders.UserId references existing Users",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Orders", "UserId")],
            body_lines=[
                "violations = {}",
                "orders_df = tables.get('Orders', pd.DataFrame())",
                "users_df = tables.get('Users', pd.DataFrame())",
                "if not orders_df.empty and not users_df.empty:",
                "    if 'UserId' in orders_df.columns and 'Id' in users_df.columns:",
                "        valid_user_ids = set(users_df['Id'].dropna().tolist())",
                "        invalid_mask = ~orders_df['UserId'].isin(valid_user_ids)",
                "        if invalid_mask.any():",
                "            invalid_series = pd.Series(orders_df.index[invalid_mask].tolist())",
                "            invalid_series.name = 'UserId'",
                "            violations['Orders'] = invalid_series",
            ],
            return_statement="violations",
        )
        
        validation_fn = check.to_validation_function()
        result = validation_fn(self.db.table_data)
        
        # Should find orphan FKs at indices 2 (UserId=99) and 5 (UserId=100)
        self.assertIn("Orders", result)
        violation_indices = result["Orders"].tolist()
        self.assertIn(2, violation_indices)
        self.assertIn(5, violation_indices)

    def test_check_for_duplicate_emails(self):
        """Test check that finds duplicate email addresses."""
        from definition.base.executable_code import CheckLogic
        
        check = CheckLogic(
            function_name="check_users_email_unique",
            description="Check that Email is unique",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Users", "Email")],
            body_lines=[
                "violations = {}",
                "df = tables.get('Users', pd.DataFrame())",
                "if not df.empty and 'Email' in df.columns:",
                "    # Find duplicates (keep first, mark rest as violations)",
                "    duplicates = df['Email'].duplicated(keep='first') & df['Email'].notna()",
                "    if duplicates.any():",
                "        invalid_series = pd.Series(df.index[duplicates].tolist())",
                "        invalid_series.name = 'Email'",
                "        violations['Users'] = invalid_series",
            ],
            return_statement="violations",
        )
        
        validation_fn = check.to_validation_function()
        result = validation_fn(self.db.table_data)
        
        # Should find duplicate emails
        self.assertIn("Users", result)
        # Indices 6, 8 have duplicates of emails at indices 5, 7
        violation_indices = result["Users"].tolist()
        self.assertGreater(len(violation_indices), 0)


class TestE2EDataProfiling(unittest.TestCase):
    """End-to-end tests for data profiling workflow."""

    def setUp(self):
        """Set up test fixtures."""
        self.db = create_test_database()

    def test_profile_identifies_null_columns(self):
        """Test that profiling identifies columns with nulls."""
        profile = self.db.profile_table_data("Users")
        
        self.assertIn("columns", profile)
        
        # Name column should have null count > 0
        name_profile = profile["columns"].get("Name", {})
        self.assertGreater(name_profile.get("null_count", 0), 0)

    def test_profile_column_data(self):
        """Test detailed column profiling."""
        profile = self.db.profile_table_column_data("Users", "Age")
        
        self.assertIn("dtype", profile)
        self.assertIn("null_count", profile)
        self.assertIn("unique_count", profile)


class TestE2EValidationWorkflow(unittest.TestCase):
    """End-to-end tests for complete validation workflow."""

    def setUp(self):
        """Set up test fixtures."""
        self.db = create_test_database()

    def test_full_validation_workflow(self):
        """Test complete validation workflow with multiple checks."""
        from definition.base.executable_code import CheckLogic
        
        # Create multiple checks
        checks = [
            CheckLogic(
                function_name="check_users_name_not_null",
                description="Name not null",
                parameters="tables: Mapping[str, pd.DataFrame]",
                scope=[("Users", "Name")],
                body_lines=[
                    "violations = {}",
                    "df = tables.get('Users', pd.DataFrame())",
                    "if not df.empty:",
                    "    null_mask = df['Name'].isna()",
                    "    if null_mask.any():",
                    "        violations['Users'] = pd.Series(df.index[null_mask].tolist(), name='Name')",
                ],
                return_statement="violations",
            ),
            CheckLogic(
                function_name="check_orders_amount_positive",
                description="Amount positive",
                parameters="tables: Mapping[str, pd.DataFrame]",
                scope=[("Orders", "Amount")],
                body_lines=[
                    "violations = {}",
                    "df = tables.get('Orders', pd.DataFrame())",
                    "if not df.empty:",
                    "    invalid_mask = df['Amount'] < 0",
                    "    if invalid_mask.any():",
                    "        violations['Orders'] = pd.Series(df.index[invalid_mask].tolist(), name='Amount')",
                ],
                return_statement="violations",
            ),
        ]
        
        # Run all checks and aggregate results
        all_violations = {}
        for check in checks:
            validation_fn = check.to_validation_function()
            result = validation_fn(self.db.table_data)
            for table, violations in result.items():
                if table not in all_violations:
                    all_violations[table] = []
                all_violations[table].extend(violations.tolist())
        
        # Should have violations in both tables
        self.assertIn("Users", all_violations)
        self.assertIn("Orders", all_violations)

    def test_check_execution_with_error_handling(self):
        """Test that checks handle errors gracefully."""
        from definition.base.executable_code import CheckLogic
        
        # Create a check that accesses a non-existent column
        check = CheckLogic(
            function_name="check_safe_execution",
            description="Should handle missing column gracefully",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("Users", "NonexistentColumn")],
            body_lines=[
                "violations = {}",
                "df = tables.get('Users', pd.DataFrame())",
                "if not df.empty and 'NonexistentColumn' in df.columns:",
                "    null_mask = df['NonexistentColumn'].isna()",
                "    if null_mask.any():",
                "        violations['Users'] = pd.Series(df.index[null_mask].tolist())",
            ],
            return_statement="violations",
        )
        
        validation_fn = check.to_validation_function()
        result = validation_fn(self.db.table_data)
        
        # Should return empty dict (no crash, no violations)
        self.assertEqual(result, {})


class TestE2ERateLimiting(unittest.TestCase):
    """End-to-end tests for rate limiting."""

    def test_rate_limiter_allows_requests_within_limit(self):
        """Test that requests within limit are allowed."""
        from definition.rate_limiting import get_rate_limiter, RateLimiterManager
        
        # Create a fresh limiter for testing
        limiter = RateLimiterManager()
        
        # Should allow requests within limit
        for i in range(5):
            allowed, info = limiter.check_rate_limit("api_chat", "test_client")
            self.assertTrue(allowed, f"Request {i+1} should be allowed")

    def test_rate_limiter_blocks_excessive_requests(self):
        """Test that excessive requests are blocked."""
        from definition.rate_limiting import SlidingWindowLimiter
        
        # Create a limiter with very low limit for testing
        limiter = SlidingWindowLimiter(max_requests=3, window_seconds=60)
        
        # First 3 requests should pass
        for i in range(3):
            allowed, _ = limiter.is_allowed("test")
            self.assertTrue(allowed)
        
        # 4th request should be blocked
        allowed, info = limiter.is_allowed("test")
        self.assertFalse(allowed)
        self.assertIn("remaining", info)
        self.assertEqual(info["remaining"], 0)


class TestE2EObservability(unittest.TestCase):
    """End-to-end tests for observability features."""

    def test_metrics_recording(self):
        """Test that metrics are recorded correctly."""
        from definition.observability import (
            metrics_available,
            record_request,
            record_check_generated,
        )
        
        # These should not raise even if prometheus is not installed
        record_request("test_service", "test_method", "success", 0.5)
        record_check_generated("test_db", "v3", 5)
        
        # Just verify no exception was raised
        self.assertTrue(True)

    def test_health_check(self):
        """Test health check functionality."""
        from definition.observability import get_health_status
        
        status = get_health_status()
        
        # Should return a valid status
        result = status.to_dict()
        self.assertIn("status", result)
        self.assertIn("timestamp", result)

    def test_logging_configuration(self):
        """Test that logging can be configured."""
        from definition.observability import configure_logging
        
        # Should not raise
        configure_logging(level="DEBUG", json_format=False)
        
        # Verify no exception
        self.assertTrue(True)


class TestE2ETracing(unittest.TestCase):
    """End-to-end tests for distributed tracing."""

    def test_tracing_context_manager(self):
        """Test that tracing context managers work."""
        from definition.tracing import create_span, tracing_available
        
        # Should work regardless of whether OpenTelemetry is installed
        with create_span("test_span", kind="internal", attributes={"test": "value"}) as span:
            # Do some work
            result = 1 + 1
        
        self.assertEqual(result, 2)

    def test_traced_decorator(self):
        """Test the @traced decorator."""
        from definition.tracing import traced
        
        @traced("test.function", kind="internal")
        def test_function(x, y):
            return x + y
        
        result = test_function(2, 3)
        self.assertEqual(result, 5)

    def test_trace_context_injection(self):
        """Test trace context injection into headers."""
        from definition.tracing import inject_trace_context
        
        headers = {"Content-Type": "application/json"}
        result = inject_trace_context(headers)
        
        # Should return headers (with or without trace context)
        self.assertIn("Content-Type", result)


if __name__ == "__main__":
    unittest.main()