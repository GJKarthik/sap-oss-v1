# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for OData Vocabulary Parser.

Tests the parsing of OData vocabulary XML files and term extraction.
"""

import pytest
from pathlib import Path
from definition.odata.vocabulary_parser import (
    ODataVocabularyParser,
    ODataVocabulary,
    ODataTerm,
    ODataEnumType,
    ODataComplexType,
    ValidationTermRegistry,
    TermCategory,
)


# Sample vocabulary XML for testing
SAMPLE_VOCABULARY_XML = """<?xml version="1.0" encoding="utf-8"?>
<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
  <edmx:DataServices>
    <Schema Namespace="com.sap.test.vocabularies.v1" Alias="Test" xmlns="http://docs.oasis-open.org/odata/ns/edm">
      
      <EnumType Name="FieldControlType" UnderlyingType="Edm.Byte">
        <Member Name="Mandatory" Value="7"/>
        <Member Name="Optional" Value="3"/>
        <Member Name="ReadOnly" Value="1"/>
        <Member Name="Inapplicable" Value="0"/>
      </EnumType>
      
      <ComplexType Name="DataFieldAbstract">
        <Property Name="Label" Type="Edm.String"/>
        <Property Name="Criticality" Type="Edm.Int32"/>
      </ComplexType>
      
      <Term Name="IsDigitSequence" Type="Edm.Boolean" AppliesTo="Property Parameter" DefaultValue="true">
        <Annotation Term="Core.Description" String="Contains only digits"/>
      </Term>
      
      <Term Name="IsUpperCase" Type="Edm.Boolean" AppliesTo="Property">
        <Annotation Term="Core.Description" String="Contains only uppercase characters"/>
      </Term>
      
      <Term Name="FieldControl" Type="Test.FieldControlType" AppliesTo="Property">
        <Annotation Term="Core.Description" String="Control state of a field"/>
      </Term>
      
      <Term Name="IsCalendarYear" Type="Edm.Boolean" AppliesTo="Property">
        <Annotation Term="Core.Description" String="Year number matching regex -?([1-9][0-9]{3,}|0[0-9]{3})"/>
      </Term>
      
    </Schema>
  </edmx:DataServices>
</edmx:Edmx>
"""


class TestODataVocabularyParser:
    """Tests for ODataVocabularyParser."""
    
    def test_parse_string_basic(self):
        """Test parsing vocabulary from XML string."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        assert vocab is not None
        assert vocab.namespace == "com.sap.test.vocabularies.v1"
        assert vocab.alias == "Test"
    
    def test_parse_terms(self):
        """Test that terms are parsed correctly."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        assert "IsDigitSequence" in vocab.terms
        assert "IsUpperCase" in vocab.terms
        assert "FieldControl" in vocab.terms
        assert "IsCalendarYear" in vocab.terms
    
    def test_term_attributes(self):
        """Test term attributes are parsed correctly."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        term = vocab.terms["IsDigitSequence"]
        assert term.name == "IsDigitSequence"
        assert term.type == "Edm.Boolean"
        assert "Property" in term.applies_to
        assert "Parameter" in term.applies_to
        assert term.default_value == "true"
        assert "digits" in term.description.lower()
    
    def test_parse_enum_types(self):
        """Test enum type parsing."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        assert "FieldControlType" in vocab.enum_types
        enum = vocab.enum_types["FieldControlType"]
        assert enum.name == "FieldControlType"
        assert enum.underlying_type == "Edm.Byte"
        assert enum.members["Mandatory"] == 7
        assert enum.members["Optional"] == 3
    
    def test_parse_complex_types(self):
        """Test complex type parsing."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        assert "DataFieldAbstract" in vocab.complex_types
        complex_type = vocab.complex_types["DataFieldAbstract"]
        assert "Label" in complex_type.properties
        assert "Criticality" in complex_type.properties
    
    def test_term_category_detection(self):
        """Test that term categories are detected."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        digit_term = vocab.terms["IsDigitSequence"]
        assert digit_term.category == TermCategory.STRING_FORMAT
        
        calendar_term = vocab.terms["IsCalendarYear"]
        assert calendar_term.category == TermCategory.DATE_FORMAT
    
    def test_get_validation_terms(self):
        """Test getting only validation terms."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        validation_terms = vocab.get_validation_terms()
        assert len(validation_terms) >= 2
        
        # Should include terms with validation categories
        term_names = [t.name for t in validation_terms]
        assert "IsDigitSequence" in term_names
        assert "IsCalendarYear" in term_names
    
    def test_get_term_by_name(self):
        """Test getting term by name."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        term = vocab.get_term("IsDigitSequence")
        assert term is not None
        assert term.name == "IsDigitSequence"
        
        # Non-existent term
        assert vocab.get_term("NonExistent") is None


class TestValidationTermRegistry:
    """Tests for ValidationTermRegistry."""
    
    def test_register_vocabulary(self):
        """Test registering a vocabulary."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        registry = ValidationTermRegistry()
        count = registry.register_vocabulary(vocab)
        
        assert count > 0
    
    def test_get_term(self):
        """Test getting term by name."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        registry = ValidationTermRegistry()
        registry.register_vocabulary(vocab)
        
        term = registry.get_term("IsDigitSequence")
        assert term is not None
        assert term.name == "IsDigitSequence"
    
    def test_get_term_by_qualified_name(self):
        """Test getting term by qualified name."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        registry = ValidationTermRegistry()
        registry.register_vocabulary(vocab)
        
        term = registry.get_term("com.sap.test.vocabularies.v1.IsDigitSequence")
        assert term is not None
        assert term.name == "IsDigitSequence"
    
    def test_get_terms_by_category(self):
        """Test getting terms by category."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        registry = ValidationTermRegistry()
        registry.register_vocabulary(vocab)
        
        string_terms = registry.get_terms_by_category(TermCategory.STRING_FORMAT)
        assert len(string_terms) > 0
        
        date_terms = registry.get_terms_by_category(TermCategory.DATE_FORMAT)
        assert len(date_terms) > 0
    
    def test_summary(self):
        """Test registry summary."""
        parser = ODataVocabularyParser()
        vocab = parser.parse_string(SAMPLE_VOCABULARY_XML)
        
        registry = ValidationTermRegistry()
        registry.register_vocabulary(vocab)
        
        summary = registry.summary()
        assert "total_terms" in summary
        assert "by_category" in summary
        assert summary["total_terms"] > 0


class TestODataTerm:
    """Tests for ODataTerm dataclass."""
    
    def test_term_creation(self):
        """Test creating a term."""
        term = ODataTerm(
            name="TestTerm",
            qualified_name="com.test.TestTerm",
            type="Edm.Boolean",
            description="Test description",
            applies_to=["Property"],
            category=TermCategory.STRING_FORMAT,
        )
        
        assert term.name == "TestTerm"
        assert term.qualified_name == "com.test.TestTerm"
        assert term.category == TermCategory.STRING_FORMAT
    
    def test_term_with_regex(self):
        """Test term with regex pattern."""
        term = ODataTerm(
            name="IsDigitSequence",
            qualified_name="com.test.IsDigitSequence",
            type="Edm.Boolean",
            description="Contains only digits",
            regex_pattern=r"^\d+$",
        )
        
        assert term.regex_pattern == r"^\d+$"


class TestODataEnumType:
    """Tests for ODataEnumType dataclass."""
    
    def test_enum_creation(self):
        """Test creating an enum type."""
        enum = ODataEnumType(
            name="TestEnum",
            qualified_name="com.test.TestEnum",
            underlying_type="Edm.Int32",
            members={"Value1": 1, "Value2": 2},
            is_flags=False,
        )
        
        assert enum.name == "TestEnum"
        assert len(enum.members) == 2
        assert enum.members["Value1"] == 1


if __name__ == "__main__":
    pytest.main([__file__, "-v"])