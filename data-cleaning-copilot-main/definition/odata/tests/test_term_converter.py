"""
Unit tests for OData Term Converter.

Tests the conversion of OData vocabulary terms to pandera checks.
"""

import pytest
import pandas as pd
from definition.odata.term_converter import (
    ODataTermConverter,
    PanderaCheckFactory,
    create_checks_from_odata_annotations,
)
from definition.odata.vocabulary_parser import ValidationTermRegistry


class TestPanderaCheckFactory:
    """Tests for PanderaCheckFactory."""
    
    def test_regex_check_valid(self):
        """Test regex check with valid data."""
        check = PanderaCheckFactory.regex_check(r"\d+", "TestCheck")
        
        valid_data = pd.Series(["123", "456789", "0"])
        result = check(valid_data)
        assert result.all()
    
    def test_regex_check_invalid(self):
        """Test regex check with invalid data."""
        check = PanderaCheckFactory.regex_check(r"\d+", "TestCheck")
        
        invalid_data = pd.Series(["abc", "12a", ""])
        result = check(invalid_data)
        assert not result.all()
    
    def test_digit_sequence_check(self):
        """Test digit sequence check."""
        check = PanderaCheckFactory.digit_sequence_check()
        
        valid = pd.Series(["123", "0", "999999"])
        assert check(valid).all()
        
        invalid = pd.Series(["12.3", "abc", "12-3"])
        assert not check(invalid).all()
    
    def test_uppercase_check_valid(self):
        """Test uppercase check with valid data."""
        check = PanderaCheckFactory.uppercase_check()
        
        valid = pd.Series(["HELLO", "WORLD", "ABC"])
        result = check(valid)
        assert result == True
    
    def test_uppercase_check_invalid(self):
        """Test uppercase check with invalid data."""
        check = PanderaCheckFactory.uppercase_check()
        
        invalid = pd.Series(["Hello", "world", "Abc"])
        result = check(invalid)
        assert result == False
    
    def test_currency_code_check(self):
        """Test currency code check."""
        check = PanderaCheckFactory.currency_code_check()
        
        valid = pd.Series(["USD", "EUR", "GBP"])
        assert check(valid).all()
        
        invalid = pd.Series(["us", "EURO", "1234"])
        assert not check(invalid).all()
    
    def test_language_identifier_check(self):
        """Test language identifier check."""
        check = PanderaCheckFactory.language_identifier_check()
        
        valid = pd.Series(["en", "de", "fr-FR", "zh-CN"])
        assert check(valid).all()
    
    def test_calendar_year_check(self):
        """Test calendar year regex pattern."""
        check = PanderaCheckFactory.regex_check(
            r"-?([1-9][0-9]{3,}|0[0-9]{3})",
            "IsCalendarYear"
        )
        
        valid = pd.Series(["2024", "0001", "-2000", "10000"])
        assert check(valid).all()
        
        invalid = pd.Series(["24", "abc", "999"])
        assert not check(invalid).all()
    
    def test_fiscal_year_check(self):
        """Test fiscal year regex pattern."""
        check = PanderaCheckFactory.regex_check(r"[1-9][0-9]{3}", "IsFiscalYear")
        
        valid = pd.Series(["2024", "1999", "2100"])
        assert check(valid).all()
        
        invalid = pd.Series(["0000", "999", "20245"])
        assert not check(invalid).all()
    
    def test_calendar_month_check(self):
        """Test calendar month regex pattern."""
        check = PanderaCheckFactory.regex_check(r"0[1-9]|1[0-2]", "IsCalendarMonth")
        
        valid = pd.Series(["01", "06", "12"])
        assert check(valid).all()
        
        invalid = pd.Series(["00", "13", "1"])
        assert not check(invalid).all()
    
    def test_calendar_quarter_check(self):
        """Test calendar quarter regex pattern."""
        check = PanderaCheckFactory.regex_check(r"[1-4]", "IsCalendarQuarter")
        
        valid = pd.Series(["1", "2", "3", "4"])
        assert check(valid).all()
        
        invalid = pd.Series(["0", "5", "Q1"])
        assert not check(invalid).all()


class TestODataTermConverter:
    """Tests for ODataTermConverter."""
    
    def test_init(self):
        """Test converter initialization."""
        converter = ODataTermConverter()
        assert converter is not None
        assert len(converter.get_supported_terms()) > 0
    
    def test_get_supported_terms(self):
        """Test getting supported terms list."""
        converter = ODataTermConverter()
        terms = converter.get_supported_terms()
        
        assert "IsDigitSequence" in terms
        assert "IsUpperCase" in terms
        assert "IsCalendarYear" in terms
        assert "IsFiscalYear" in terms
        assert "IsCurrency" in terms
    
    def test_term_to_check_digit_sequence(self):
        """Test converting IsDigitSequence term."""
        converter = ODataTermConverter()
        check = converter.term_to_check("IsDigitSequence")
        
        assert check is not None
        assert check.name == "IsDigitSequence"
        
        # Test the check works
        valid = pd.Series(["123", "456"])
        assert check(valid).all()
    
    def test_term_to_check_uppercase(self):
        """Test converting IsUpperCase term."""
        converter = ODataTermConverter()
        check = converter.term_to_check("IsUpperCase")
        
        assert check is not None
        assert check.name == "IsUpperCase"
    
    def test_term_to_check_calendar_year(self):
        """Test converting IsCalendarYear term."""
        converter = ODataTermConverter()
        check = converter.term_to_check("IsCalendarYear")
        
        assert check is not None
        assert check.name == "IsCalendarYear"
    
    def test_term_to_check_qualified_name(self):
        """Test converting term with qualified name."""
        converter = ODataTermConverter()
        check = converter.term_to_check("com.sap.vocabularies.Common.v1.IsDigitSequence")
        
        assert check is not None
        assert check.name == "IsDigitSequence"
    
    def test_term_to_check_unknown(self):
        """Test converting unknown term returns None."""
        converter = ODataTermConverter()
        check = converter.term_to_check("UnknownTerm")
        
        assert check is None
    
    def test_has_check_for_term(self):
        """Test checking if term has a check."""
        converter = ODataTermConverter()
        
        assert converter.has_check_for_term("IsDigitSequence") == True
        assert converter.has_check_for_term("IsUpperCase") == True
        assert converter.has_check_for_term("UnknownTerm") == False
    
    def test_annotations_to_checks(self):
        """Test converting list of annotations."""
        converter = ODataTermConverter()
        
        checks = converter.annotations_to_checks([
            "IsDigitSequence",
            "IsUpperCase",
            "IsFiscalYear",
        ])
        
        assert len(checks) == 3
        check_names = [c.name for c in checks]
        assert "IsDigitSequence" in check_names
        assert "IsUpperCase" in check_names
        assert "IsFiscalYear" in check_names
    
    def test_annotations_to_checks_skip_unsupported(self):
        """Test that unsupported terms are skipped by default."""
        converter = ODataTermConverter()
        
        checks = converter.annotations_to_checks([
            "IsDigitSequence",
            "UnknownTerm",
            "IsFiscalYear",
        ])
        
        # Only 2 checks should be returned (UnknownTerm skipped)
        assert len(checks) == 2
    
    def test_get_nullable_from_field_control_mandatory(self):
        """Test field control mandatory detection."""
        converter = ODataTermConverter()
        
        assert converter.get_nullable_from_field_control("Mandatory") == False
        assert converter.get_nullable_from_field_control(7) == False
        assert converter.get_nullable_from_field_control("7") == False
    
    def test_get_nullable_from_field_control_optional(self):
        """Test field control optional detection."""
        converter = ODataTermConverter()
        
        assert converter.get_nullable_from_field_control("Optional") == True
        assert converter.get_nullable_from_field_control(3) == True
        assert converter.get_nullable_from_field_control("ReadOnly") == True


class TestCreateChecksFromODataAnnotations:
    """Tests for create_checks_from_odata_annotations function."""
    
    def test_basic_usage(self):
        """Test basic usage of the function."""
        annotations = {
            "CustomerID": ["IsUpperCase", "IsDigitSequence"],
            "PostalCode": ["IsDigitSequence"],
        }
        
        checks = create_checks_from_odata_annotations(annotations)
        
        assert "CustomerID" in checks
        assert "PostalCode" in checks
        assert len(checks["CustomerID"]) == 2
        assert len(checks["PostalCode"]) == 1
    
    def test_empty_annotations(self):
        """Test with empty annotation list."""
        annotations = {
            "Column1": [],
            "Column2": ["IsDigitSequence"],
        }
        
        checks = create_checks_from_odata_annotations(annotations)
        
        # Column1 should not be in result (no checks)
        assert "Column1" not in checks
        assert "Column2" in checks
    
    def test_with_custom_converter(self):
        """Test with custom converter instance."""
        converter = ODataTermConverter()
        annotations = {
            "FiscalYear": ["IsFiscalYear"],
        }
        
        checks = create_checks_from_odata_annotations(annotations, converter)
        
        assert "FiscalYear" in checks
        assert len(checks["FiscalYear"]) == 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])