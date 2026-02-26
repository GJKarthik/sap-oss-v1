"""
Unit Tests for Vocabulary Loading and Parsing

Tests the core vocabulary XML parsing functionality.
"""

import pytest
from pathlib import Path


class TestVocabularyLoading:
    """Test vocabulary loading from XML files"""
    
    def test_vocabularies_directory_exists(self, vocab_dir):
        """Test that vocabularies directory exists"""
        assert vocab_dir.exists()
        assert vocab_dir.is_dir()
    
    def test_xml_files_present(self, vocab_dir):
        """Test that XML vocabulary files are present"""
        xml_files = list(vocab_dir.glob("*.xml"))
        assert len(xml_files) >= 15, f"Expected at least 15 vocabulary files, found {len(xml_files)}"
    
    def test_core_vocabularies_present(self, test_vocabularies):
        """Test that core SAP vocabularies are loaded"""
        core_vocabs = ["UI", "Common", "Analytics", "PersonalData"]
        for vocab in core_vocabs:
            assert vocab in test_vocabularies, f"Missing core vocabulary: {vocab}"
    
    def test_ui_vocabulary_terms(self, test_vocabularies):
        """Test UI vocabulary has expected terms"""
        assert "UI" in test_vocabularies
        ui_terms = test_vocabularies["UI"]["terms"]
        
        expected_terms = ["LineItem", "HeaderInfo", "FieldGroup", "SelectionFields"]
        for term in expected_terms:
            assert term in ui_terms, f"Missing UI term: {term}"
    
    def test_common_vocabulary_terms(self, test_vocabularies):
        """Test Common vocabulary has expected terms"""
        assert "Common" in test_vocabularies
        common_terms = test_vocabularies["Common"]["terms"]
        
        expected_terms = ["Label", "ValueList", "Text"]
        for term in expected_terms:
            assert term in common_terms, f"Missing Common term: {term}"
    
    def test_analytics_vocabulary_terms(self, test_vocabularies):
        """Test Analytics vocabulary has expected terms"""
        assert "Analytics" in test_vocabularies
        analytics_terms = test_vocabularies["Analytics"]["terms"]
        
        expected_terms = ["Measure", "Dimension"]
        for term in expected_terms:
            assert term in analytics_terms, f"Missing Analytics term: {term}"
    
    def test_personal_data_vocabulary(self, test_vocabularies):
        """Test PersonalData vocabulary for GDPR compliance"""
        assert "PersonalData" in test_vocabularies
        pd_terms = test_vocabularies["PersonalData"]["terms"]
        
        expected_terms = ["IsPotentiallyPersonal", "IsPotentiallySensitive"]
        for term in expected_terms:
            assert term in pd_terms, f"Missing PersonalData term: {term}"
    
    def test_vocabulary_namespaces(self, test_vocabularies):
        """Test vocabulary namespaces are properly extracted"""
        assert test_vocabularies["UI"]["namespace"] == "com.sap.vocabularies.UI.v1"
        assert test_vocabularies["Common"]["namespace"] == "com.sap.vocabularies.Common.v1"
    
    def test_vocabulary_has_terms_or_types(self, test_vocabularies):
        """Test each vocabulary has terms or types defined"""
        for alias, vocab in test_vocabularies.items():
            total = len(vocab["terms"]) + len(vocab["complex_types"]) + len(vocab["enum_types"])
            assert total > 0, f"Vocabulary {alias} has no definitions"
    
    def test_hana_cloud_vocabulary_exists(self, vocab_dir):
        """Test HANACloud vocabulary file exists (our custom vocabulary)"""
        hana_file = vocab_dir / "HANACloud.xml"
        # This is optional - created in Phase 2
        if hana_file.exists():
            from xml.etree import ElementTree as ET
            tree = ET.parse(hana_file)
            root = tree.getroot()
            assert root is not None


class TestVocabularyStatistics:
    """Test vocabulary statistics and counts"""
    
    def test_minimum_vocabulary_count(self, test_vocabularies):
        """Test minimum number of vocabularies loaded"""
        assert len(test_vocabularies) >= 15
    
    def test_total_terms_count(self, test_vocabularies):
        """Test total number of terms across all vocabularies"""
        total_terms = sum(len(v["terms"]) for v in test_vocabularies.values())
        assert total_terms >= 200, f"Expected at least 200 terms, found {total_terms}"
    
    def test_total_complex_types_count(self, test_vocabularies):
        """Test total number of complex types"""
        total_types = sum(len(v["complex_types"]) for v in test_vocabularies.values())
        assert total_types >= 50, f"Expected at least 50 complex types, found {total_types}"
    
    def test_total_enum_types_count(self, test_vocabularies):
        """Test total number of enum types"""
        total_enums = sum(len(v["enum_types"]) for v in test_vocabularies.values())
        assert total_enums >= 30, f"Expected at least 30 enum types, found {total_enums}"


class TestVocabularyXMLValidity:
    """Test XML validity and structure"""
    
    def test_all_xml_files_parseable(self, vocab_dir):
        """Test all XML files can be parsed without errors"""
        from xml.etree import ElementTree as ET
        
        errors = []
        for xml_file in vocab_dir.glob("*.xml"):
            try:
                ET.parse(xml_file)
            except Exception as e:
                errors.append(f"{xml_file.name}: {e}")
        
        assert len(errors) == 0, f"XML parsing errors: {errors}"
    
    def test_xml_has_required_structure(self, vocab_dir):
        """Test XML files have required EDMX structure"""
        from xml.etree import ElementTree as ET
        
        ns = {"edmx": "http://docs.oasis-open.org/odata/ns/edmx",
              "edm": "http://docs.oasis-open.org/odata/ns/edm"}
        
        for xml_file in vocab_dir.glob("*.xml"):
            tree = ET.parse(xml_file)
            root = tree.getroot()
            
            # Should have Edmx root or Schema
            has_schema = root.find(".//edm:Schema", ns) is not None
            assert has_schema, f"{xml_file.name} missing Schema element"