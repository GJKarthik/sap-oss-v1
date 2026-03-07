# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for OData Database Integration.

Tests the integration of OData vocabulary checks with the Database class.
"""

import pytest
import pandas as pd
from definition.odata.database_integration import (
    derive_odata_checks,
    add_odata_checks_to_database,
    ODataDatabaseExtension,
    create_odata_check_logic,
    create_uppercase_check_logic,
    create_currency_check_logic,
    TERM_REGEX_PATTERNS,
    TERM_TO_CHECK_LOGIC_FACTORY,
)
from definition.base.executable_code import CheckLogic


class TestCreateODataCheckLogic:
    """Tests for create_odata_check_logic function."""
    
    def test_create_regex_check(self):
        """Test creating a regex-based check."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="PostalCode",
            term_name="IsDigitSequence",
            regex_pattern=r"\d+",
        )
        
        assert check is not None
        assert check.function_name == "OData_Customer_PostalCode_IsDigitSequence"
        assert check.scope == [("Customer", "PostalCode")]
        assert len(check.body_lines) > 0
    
    def test_create_placeholder_check(self):
        """Test creating a placeholder check (no validation)."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="Name",
            term_name="UnknownTerm",
        )
        
        assert check is not None
        assert "return {}" in "".join(check.body_lines)
    
    def test_check_has_valid_code(self):
        """Test that generated check has valid Python code."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="ID",
            term_name="IsDigitSequence",
            regex_pattern=r"\d+",
        )
        
        code = check.to_code()
        assert "def OData_Customer_ID_IsDigitSequence" in code
        assert "tables" in code  # Should accept tables parameter


class TestCreateSpecializedCheckLogic:
    """Tests for specialized check logic factories."""
    
    def test_create_uppercase_check(self):
        """Test creating uppercase check."""
        check = create_uppercase_check_logic("Customer", "CustomerID")
        
        assert check.function_name == "OData_Customer_CustomerID_IsUpperCase"
        assert check.scope == [("Customer", "CustomerID")]
        
        code = check.to_code()
        assert "isupper" in code.lower() or "upper" in code.lower()
    
    def test_create_currency_check(self):
        """Test creating currency check."""
        check = create_currency_check_logic("Order", "Currency")
        
        assert check.function_name == "OData_Order_Currency_IsCurrency"
        assert check.scope == [("Order", "Currency")]
        
        code = check.to_code()
        assert "[A-Z]{3}" in code  # ISO 4217 pattern


class TestTermRegexPatterns:
    """Tests for the TERM_REGEX_PATTERNS dictionary."""
    
    def test_all_known_terms_have_patterns(self):
        """Test that expected terms have patterns."""
        expected_terms = [
            "IsDigitSequence",
            "IsCalendarYear",
            "IsCalendarMonth",
            "IsCalendarQuarter",
            "IsFiscalYear",
            "IsFiscalPeriod",
        ]
        
        for term in expected_terms:
            assert term in TERM_REGEX_PATTERNS, f"Missing pattern for {term}"
    
    def test_patterns_are_valid_regex(self):
        """Test that all patterns are valid regex."""
        import re
        
        for term, pattern in TERM_REGEX_PATTERNS.items():
            try:
                re.compile(pattern)
            except re.error as e:
                pytest.fail(f"Invalid regex for {term}: {pattern} - {e}")


class TestDeriveODataChecks:
    """Tests for derive_odata_checks function."""
    
    def test_derive_basic_checks(self):
        """Test deriving checks from simple annotations."""
        annotations = {
            "Customer": {
                "CustomerID": ["IsUpperCase"],
                "PostalCode": ["IsDigitSequence"],
            }
        }
        
        checks = derive_odata_checks(annotations)
        
        assert len(checks) == 2
        assert "OData_Customer_CustomerID_IsUpperCase" in checks
        assert "OData_Customer_PostalCode_IsDigitSequence" in checks
    
    def test_derive_multiple_checks_per_column(self):
        """Test deriving multiple checks for a single column."""
        annotations = {
            "Customer": {
                "Code": ["IsUpperCase", "IsDigitSequence"],
            }
        }
        
        checks = derive_odata_checks(annotations)
        
        assert len(checks) == 2
        assert "OData_Customer_Code_IsUpperCase" in checks
        assert "OData_Customer_Code_IsDigitSequence" in checks
    
    def test_derive_checks_multiple_tables(self):
        """Test deriving checks for multiple tables."""
        annotations = {
            "Customer": {
                "CustomerID": ["IsUpperCase"],
            },
            "Order": {
                "FiscalYear": ["IsFiscalYear"],
                "FiscalPeriod": ["IsFiscalPeriod"],
            },
        }
        
        checks = derive_odata_checks(annotations)
        
        assert len(checks) == 3
        assert "OData_Customer_CustomerID_IsUpperCase" in checks
        assert "OData_Order_FiscalYear_IsFiscalYear" in checks
        assert "OData_Order_FiscalPeriod_IsFiscalPeriod" in checks
    
    def test_derive_calendar_checks(self):
        """Test deriving calendar date checks."""
        annotations = {
            "Invoice": {
                "Year": ["IsCalendarYear"],
                "Month": ["IsCalendarMonth"],
                "Quarter": ["IsCalendarQuarter"],
            }
        }
        
        checks = derive_odata_checks(annotations)
        
        assert len(checks) == 3
        
        # Verify each check is a CheckLogic
        for check_name, check in checks.items():
            assert isinstance(check, CheckLogic)
            assert check_name.startswith("OData_")
    
    def test_derive_unknown_term_skipped(self):
        """Test that unknown terms are skipped with warning."""
        annotations = {
            "Customer": {
                "Field": ["UnknownODataTerm"],
            }
        }
        
        checks = derive_odata_checks(annotations)
        
        # Should be empty since the term is unknown
        assert len(checks) == 0
    
    def test_derive_empty_annotations(self):
        """Test with empty annotations."""
        checks = derive_odata_checks({})
        assert len(checks) == 0
    
    def test_derive_qualified_term_names(self):
        """Test with fully qualified term names."""
        annotations = {
            "Customer": {
                "Code": ["com.sap.vocabularies.Common.v1.IsDigitSequence"],
            }
        }
        
        checks = derive_odata_checks(annotations)
        
        assert len(checks) == 1
        assert "OData_Customer_Code_IsDigitSequence" in checks


class TestODataDatabaseExtension:
    """Tests for ODataDatabaseExtension class."""
    
    def test_init(self):
        """Test extension initialization."""
        # Create a mock database object
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        assert ext.database is db
        assert ext.column_annotations == {}
        assert len(ext._vocabularies_loaded) == 0
    
    def test_set_column_annotations(self):
        """Test setting column annotations."""
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        ext.set_column_annotations("Customer", "CustomerID", ["IsUpperCase"])
        
        assert "Customer" in ext.column_annotations
        assert "CustomerID" in ext.column_annotations["Customer"]
        assert ext.column_annotations["Customer"]["CustomerID"] == ["IsUpperCase"]
    
    def test_set_table_annotations(self):
        """Test setting all annotations for a table."""
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        ext.set_table_annotations("Order", {
            "FiscalYear": ["IsFiscalYear"],
            "FiscalPeriod": ["IsFiscalPeriod"],
        })
        
        assert "Order" in ext.column_annotations
        assert "FiscalYear" in ext.column_annotations["Order"]
        assert "FiscalPeriod" in ext.column_annotations["Order"]
    
    def test_get_annotations(self):
        """Test getting all annotations."""
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        ext.set_column_annotations("Customer", "ID", ["IsDigitSequence"])
        
        annotations = ext.get_annotations()
        
        assert "Customer" in annotations
        # Should be a copy, not the original
        annotations["Customer"]["ID"] = ["Modified"]
        assert ext.column_annotations["Customer"]["ID"] == ["IsDigitSequence"]
    
    def test_derive_odata_checks(self):
        """Test deriving and adding checks."""
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        ext.set_column_annotations("Customer", "CustomerID", ["IsUpperCase"])
        ext.set_column_annotations("Customer", "PostalCode", ["IsDigitSequence"])
        
        count = ext.derive_odata_checks()
        
        assert count == 2
        assert len(db.rule_based_checks) == 2
        assert "OData_Customer_CustomerID_IsUpperCase" in db.rule_based_checks
        assert "OData_Customer_PostalCode_IsDigitSequence" in db.rule_based_checks
    
    def test_get_available_terms(self):
        """Test getting available terms."""
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        terms = ext.get_available_terms()
        
        assert "IsDigitSequence" in terms
        assert "IsUpperCase" in terms
        assert "IsFiscalYear" in terms
        assert "IsCurrency" in terms
    
    def test_summary(self):
        """Test getting extension summary."""
        class MockDatabase:
            rule_based_checks = {}
        
        db = MockDatabase()
        ext = ODataDatabaseExtension(db)
        
        ext.set_column_annotations("Customer", "ID", ["IsDigitSequence"])
        ext.derive_odata_checks()
        
        summary = ext.summary()
        
        assert "vocabularies_loaded" in summary
        assert "tables_with_annotations" in summary
        assert "total_annotated_columns" in summary
        assert "available_terms" in summary
        assert "odata_checks_in_database" in summary
        
        assert summary["tables_with_annotations"] == ["Customer"]
        assert summary["total_annotated_columns"] == 1
        assert summary["odata_checks_in_database"] == 1


class TestCheckLogicExecution:
    """Tests for executing generated CheckLogic objects."""
    
    def test_digit_sequence_check_execution(self):
        """Test executing a digit sequence check."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="PostalCode",
            term_name="IsDigitSequence",
            regex_pattern=r"\d+",
        )
        
        # Create test data
        tables = {
            "Customer": pd.DataFrame({
                "PostalCode": ["12345", "67890", "abc", "123"]
            })
        }
        
        # Execute the check
        code = check.to_code()
        namespace = {"pd": pd}
        exec(code, namespace)
        
        result = namespace[check.function_name](tables)
        
        # Should find violation at index 2 (the "abc" value)
        assert "Customer" in result
        assert 2 in result["Customer"].tolist()
    
    def test_uppercase_check_execution(self):
        """Test executing an uppercase check."""
        check = create_uppercase_check_logic("Customer", "Code")
        
        tables = {
            "Customer": pd.DataFrame({
                "Code": ["ABC", "DEF", "abc", "GHI"]
            })
        }
        
        code = check.to_code()
        namespace = {"pd": pd}
        exec(code, namespace)
        
        result = namespace[check.function_name](tables)
        
        # Should find violation at index 2 (the "abc" value)
        assert "Customer" in result
        assert 2 in result["Customer"].tolist()
    
    def test_check_handles_empty_table(self):
        """Test that check handles empty table gracefully."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="PostalCode",
            term_name="IsDigitSequence",
            regex_pattern=r"\d+",
        )
        
        tables = {
            "Customer": pd.DataFrame({"PostalCode": []})
        }
        
        code = check.to_code()
        namespace = {"pd": pd}
        exec(code, namespace)
        
        result = namespace[check.function_name](tables)
        
        # Should return empty dict
        assert result == {}
    
    def test_check_handles_missing_table(self):
        """Test that check handles missing table gracefully."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="PostalCode",
            term_name="IsDigitSequence",
            regex_pattern=r"\d+",
        )
        
        tables = {}  # No Customer table
        
        code = check.to_code()
        namespace = {"pd": pd}
        exec(code, namespace)
        
        result = namespace[check.function_name](tables)
        
        # Should return empty dict
        assert result == {}
    
    def test_check_handles_null_values(self):
        """Test that check handles null values gracefully."""
        check = create_odata_check_logic(
            table_name="Customer",
            column_name="PostalCode",
            term_name="IsDigitSequence",
            regex_pattern=r"\d+",
        )
        
        tables = {
            "Customer": pd.DataFrame({
                "PostalCode": ["12345", None, "67890", pd.NA]
            })
        }
        
        code = check.to_code()
        namespace = {"pd": pd}
        exec(code, namespace)
        
        result = namespace[check.function_name](tables)
        
        # Should not flag null values as violations
        # Only non-null values that don't match the pattern should be violations
        if "Customer" in result:
            assert 1 not in result["Customer"].tolist()  # None
            assert 3 not in result["Customer"].tolist()  # pd.NA


if __name__ == "__main__":
    pytest.main([__file__, "-v"])