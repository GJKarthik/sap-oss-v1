# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for OData vocabulary integration.

Tests cover:
- Semantic type inference from column names
- PII detection
- Validation rule generation
- OData MCP client (mocked)
- Annotation engine
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from odata.vocabulary import (
    SemanticType,
    ColumnAnnotation,
    EntityAnnotation,
    ODataVocabularyClient,
    AnnotationEngine,
    COLUMN_NAME_PATTERNS,
    PII_TYPES,
    SENSITIVE_TYPES,
    VALIDATION_RULES,
    get_vocab_client,
    get_annotation_engine,
    annotate_table,
    get_pii_columns_for_table,
    infer_column_type,
)


class TestSemanticTypes:
    """Test semantic type enum and classifications."""
    
    def test_pii_types_defined(self):
        assert SemanticType.EMAIL in PII_TYPES
        assert SemanticType.PHONE in PII_TYPES
        assert SemanticType.PERSON_NAME in PII_TYPES
        assert SemanticType.ADDRESS in PII_TYPES
        assert SemanticType.POSTAL_CODE in PII_TYPES
    
    def test_sensitive_types_defined(self):
        assert SemanticType.CURRENCY in SENSITIVE_TYPES
        assert SemanticType.AMOUNT in SENSITIVE_TYPES
    
    def test_non_pii_types(self):
        assert SemanticType.ID not in PII_TYPES
        assert SemanticType.DATE not in PII_TYPES
        assert SemanticType.DESCRIPTION not in PII_TYPES
        assert SemanticType.UNKNOWN not in PII_TYPES


class TestColumnNamePatterns:
    """Test column name pattern matching."""
    
    def test_email_patterns(self):
        assert COLUMN_NAME_PATTERNS["email"] == SemanticType.EMAIL
        assert COLUMN_NAME_PATTERNS["e_mail"] == SemanticType.EMAIL
        assert COLUMN_NAME_PATTERNS["mail"] == SemanticType.EMAIL
    
    def test_phone_patterns(self):
        assert COLUMN_NAME_PATTERNS["phone"] == SemanticType.PHONE
        assert COLUMN_NAME_PATTERNS["telephone"] == SemanticType.PHONE
        assert COLUMN_NAME_PATTERNS["mobile"] == SemanticType.PHONE
    
    def test_name_patterns(self):
        assert COLUMN_NAME_PATTERNS["firstname"] == SemanticType.PERSON_NAME
        assert COLUMN_NAME_PATTERNS["last_name"] == SemanticType.PERSON_NAME
        assert COLUMN_NAME_PATTERNS["full_name"] == SemanticType.PERSON_NAME
    
    def test_address_patterns(self):
        assert COLUMN_NAME_PATTERNS["address"] == SemanticType.ADDRESS
        assert COLUMN_NAME_PATTERNS["street"] == SemanticType.ADDRESS
        assert COLUMN_NAME_PATTERNS["city"] == SemanticType.CITY
    
    def test_financial_patterns(self):
        assert COLUMN_NAME_PATTERNS["amount"] == SemanticType.AMOUNT
        assert COLUMN_NAME_PATTERNS["price"] == SemanticType.AMOUNT
        assert COLUMN_NAME_PATTERNS["currency"] == SemanticType.CURRENCY


class TestValidationRules:
    """Test validation rules for semantic types."""
    
    def test_email_validation_rules(self):
        rules = VALIDATION_RULES[SemanticType.EMAIL]
        assert "format_email" in rules
        assert "max_length_254" in rules
    
    def test_phone_validation_rules(self):
        rules = VALIDATION_RULES[SemanticType.PHONE]
        assert "format_phone" in rules
        assert "min_length_7" in rules
    
    def test_amount_validation_rules(self):
        rules = VALIDATION_RULES[SemanticType.AMOUNT]
        assert "numeric" in rules
        assert "non_negative" in rules
    
    def test_uuid_validation_rules(self):
        rules = VALIDATION_RULES[SemanticType.UUID]
        assert "format_uuid" in rules
        assert "length_36" in rules


class TestAnnotationEngine:
    """Test the annotation engine."""
    
    @pytest.fixture
    def engine(self):
        """Create annotation engine with unavailable vocab client."""
        client = ODataVocabularyClient()
        client._available = False
        return AnnotationEngine(client)
    
    def test_infer_email_type(self, engine):
        sem_type = engine.infer_semantic_type("email")
        assert sem_type == SemanticType.EMAIL
    
    def test_infer_email_type_variations(self, engine):
        assert engine.infer_semantic_type("Email") == SemanticType.EMAIL
        assert engine.infer_semantic_type("EMAIL") == SemanticType.EMAIL
        assert engine.infer_semantic_type("user_email") == SemanticType.EMAIL
        assert engine.infer_semantic_type("customer-email") == SemanticType.EMAIL
    
    def test_infer_phone_type(self, engine):
        assert engine.infer_semantic_type("phone") == SemanticType.PHONE
        assert engine.infer_semantic_type("PhoneNumber") == SemanticType.PHONE
        assert engine.infer_semantic_type("mobile_phone") == SemanticType.PHONE
    
    def test_infer_name_type(self, engine):
        assert engine.infer_semantic_type("FirstName") == SemanticType.PERSON_NAME
        assert engine.infer_semantic_type("last_name") == SemanticType.PERSON_NAME
        assert engine.infer_semantic_type("CustomerName") == SemanticType.PERSON_NAME
    
    def test_infer_from_data_type(self, engine):
        assert engine.infer_semantic_type("created", "TIMESTAMP") == SemanticType.TIMESTAMP
        assert engine.infer_semantic_type("birth", "DATE") == SemanticType.DATE
        assert engine.infer_semantic_type("total", "DECIMAL") == SemanticType.AMOUNT
        # Use a name that doesn't match any pattern to test data type inference
        assert engine.infer_semantic_type("xyz_col", "UUID") == SemanticType.UUID
    
    def test_infer_unknown_type(self, engine):
        assert engine.infer_semantic_type("xyz123") == SemanticType.UNKNOWN
        assert engine.infer_semantic_type("random_col") == SemanticType.UNKNOWN
    
    def test_annotate_column_pii_flag(self, engine):
        email_col = engine.annotate_column("email")
        assert email_col.is_pii is True
        
        id_col = engine.annotate_column("id")
        assert id_col.is_pii is False
    
    def test_annotate_column_sensitive_flag(self, engine):
        amount_col = engine.annotate_column("amount")
        assert amount_col.is_sensitive is True
        
        # PII columns are also sensitive
        email_col = engine.annotate_column("email")
        assert email_col.is_sensitive is True
        
        id_col = engine.annotate_column("id")
        assert id_col.is_sensitive is False
    
    def test_annotate_column_validation_rules(self, engine):
        email_col = engine.annotate_column("email")
        assert "format_email" in email_col.validation_rules
        
        phone_col = engine.annotate_column("phone")
        assert "format_phone" in phone_col.validation_rules
    
    def test_annotate_entity(self, engine):
        columns = [
            {"name": "Id", "type": "INTEGER"},
            {"name": "Email", "type": "VARCHAR"},
            {"name": "FirstName", "type": "VARCHAR"},
            {"name": "Amount", "type": "DECIMAL"},
        ]
        
        entity = engine.annotate_entity("Users", columns)
        
        assert entity.entity_name == "Users"
        assert len(entity.columns) == 4
        
        # Check semantic types
        col_dict = {c.column_name: c for c in entity.columns}
        assert col_dict["Id"].semantic_type == SemanticType.ID
        assert col_dict["Email"].semantic_type == SemanticType.EMAIL
        assert col_dict["FirstName"].semantic_type == SemanticType.PERSON_NAME
        assert col_dict["Amount"].semantic_type == SemanticType.AMOUNT
    
    def test_get_pii_columns(self, engine):
        columns = [
            {"name": "Id", "type": "INTEGER"},
            {"name": "Email", "type": "VARCHAR"},
            {"name": "FirstName", "type": "VARCHAR"},
            {"name": "LastName", "type": "VARCHAR"},
            {"name": "Amount", "type": "DECIMAL"},
        ]
        
        entity = engine.annotate_entity("Users", columns)
        pii_cols = engine.get_pii_columns(entity)
        
        assert "Email" in pii_cols
        assert "FirstName" in pii_cols
        assert "LastName" in pii_cols
        assert "Id" not in pii_cols
        assert "Amount" not in pii_cols
    
    def test_get_validation_rules_for_entity(self, engine):
        columns = [
            {"name": "Id", "type": "INTEGER"},
            {"name": "Email", "type": "VARCHAR"},
        ]
        
        entity = engine.annotate_entity("Users", columns)
        rules = engine.get_validation_rules_for_entity(entity)
        
        assert "Id" in rules
        assert "not_null" in rules["Id"]
        
        assert "Email" in rules
        assert "format_email" in rules["Email"]


class TestODataVocabularyClient:
    """Test OData vocabulary MCP client."""
    
    def test_client_unavailable_by_default(self):
        client = ODataVocabularyClient()
        # Will be False if MCP server not running
        # Just check it doesn't crash
        assert isinstance(client.available(), bool)
    
    def test_client_caches_availability(self):
        client = ODataVocabularyClient()
        client._available = True
        assert client.available() is True
        
        client._available = False
        assert client.available() is False
    
    def test_get_vocabulary_returns_none_when_unavailable(self):
        client = ODataVocabularyClient()
        client._available = False
        
        result = client.get_vocabulary("Common")
        # Should return None or cached value, not crash
        assert result is None or isinstance(result, dict)
    
    def test_get_entity_relationships_returns_empty_when_unavailable(self):
        client = ODataVocabularyClient()
        client._available = False
        
        result = client.get_entity_relationships("Users")
        assert result == []


class TestConvenienceFunctions:
    """Test module-level convenience functions."""
    
    def test_get_vocab_client_singleton(self):
        import odata.vocabulary as vocab_module
        vocab_module._vocab_client = None
        
        client1 = get_vocab_client()
        client2 = get_vocab_client()
        
        assert client1 is client2
    
    def test_get_annotation_engine_singleton(self):
        import odata.vocabulary as vocab_module
        vocab_module._annotation_engine = None
        
        engine1 = get_annotation_engine()
        engine2 = get_annotation_engine()
        
        assert engine1 is engine2
    
    def test_annotate_table_convenience(self):
        columns = [
            {"name": "Id", "type": "INTEGER"},
            {"name": "Email", "type": "VARCHAR"},
        ]
        
        annotation = annotate_table("Users", columns)
        
        assert annotation.entity_name == "Users"
        assert len(annotation.columns) == 2
    
    def test_get_pii_columns_for_table_convenience(self):
        columns = [
            {"name": "Id", "type": "INTEGER"},
            {"name": "Email", "type": "VARCHAR"},
            {"name": "PhoneNumber", "type": "VARCHAR"},
        ]
        
        pii_cols = get_pii_columns_for_table("Users", columns)
        
        assert "Email" in pii_cols
        assert "PhoneNumber" in pii_cols
        assert "Id" not in pii_cols
    
    def test_infer_column_type_convenience(self):
        result = infer_column_type("email")
        
        assert result["column_name"] == "email"
        assert result["semantic_type"] == "email"
        assert result["is_pii"] is True
        assert "format_email" in result["validation_rules"]


class TestEdgeCases:
    """Test edge cases and error handling."""
    
    def test_empty_column_name(self):
        engine = AnnotationEngine()
        sem_type = engine.infer_semantic_type("")
        assert sem_type == SemanticType.UNKNOWN
    
    def test_empty_columns_list(self):
        engine = AnnotationEngine()
        entity = engine.annotate_entity("Empty", [])
        assert entity.entity_name == "Empty"
        assert len(entity.columns) == 0
    
    def test_column_with_special_characters(self):
        engine = AnnotationEngine()
        # Should normalize and still match
        sem_type = engine.infer_semantic_type("user-email-address")
        assert sem_type == SemanticType.EMAIL
    
    def test_column_with_spaces(self):
        engine = AnnotationEngine()
        sem_type = engine.infer_semantic_type("First Name")
        # After normalization: first_name
        assert sem_type == SemanticType.PERSON_NAME
    
    def test_mixed_case_column(self):
        engine = AnnotationEngine()
        assert engine.infer_semantic_type("EMAIL") == SemanticType.EMAIL
        assert engine.infer_semantic_type("Email") == SemanticType.EMAIL
        assert engine.infer_semantic_type("eMaIl") == SemanticType.EMAIL


class TestODataAnnotationIntegration:
    """Test OData annotation handling."""
    
    def test_annotate_column_with_odata_semantic_type(self):
        engine = AnnotationEngine()
        odata_annot = {"semanticType": "email"}
        
        col = engine.annotate_column("contact", odata_annotation=odata_annot)
        
        assert col.semantic_type == SemanticType.EMAIL
        assert col.source == "odata"
    
    def test_annotate_column_with_invalid_odata_type(self):
        engine = AnnotationEngine()
        odata_annot = {"semanticType": "invalid_type_xyz"}
        
        col = engine.annotate_column("email", odata_annotation=odata_annot)
        
        # Falls back to inference
        assert col.semantic_type == SemanticType.EMAIL
        assert col.source == "inferred"
    
    def test_annotate_column_with_odata_constraints(self):
        engine = AnnotationEngine()
        odata_annot = {
            "nullable": False,
            "maxLength": 100,
        }
        
        col = engine.annotate_column("name", odata_annotation=odata_annot)
        
        assert "not_null" in col.validation_rules
        assert "max_length_100" in col.validation_rules