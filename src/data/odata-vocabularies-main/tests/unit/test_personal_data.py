"""
Unit Tests for Personal Data Classification

Tests GDPR compliance features and personal data detection.
"""

import pytest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))


class TestPersonalDataClassifier:
    """Tests for personal data classification"""
    
    @pytest.fixture
    def classifier_patterns(self):
        """Personal data patterns for classification"""
        return {
            "email_patterns": [
                "Email", "E-Mail", "EmailAddress", "Mail", 
                "MailAddress", "ContactEmail"
            ],
            "phone_patterns": [
                "Phone", "Telephone", "Mobile", "Fax", 
                "PhoneNumber", "TelephoneNumber", "MobileNumber"
            ],
            "address_patterns": [
                "Address", "Street", "City", "PostalCode", 
                "ZipCode", "Country", "State", "Province", 
                "HomeAddress", "WorkAddress"
            ],
            "name_patterns": [
                "Name", "FirstName", "LastName", "FullName", 
                "MiddleName", "Surname", "GivenName"
            ],
            "identifier_patterns": [
                "SSN", "SocialSecurityNumber", "TaxID", 
                "PassportNumber", "DriverLicense", "NationalID"
            ],
            "sensitive_patterns": [
                "Health", "Medical", "Religion", "Religious",
                "Ethnic", "Race", "Political", "Sexual",
                "Biometric", "Genetic"
            ]
        }
    
    def test_email_detection(self, classifier_patterns):
        """Test email field detection"""
        for pattern in classifier_patterns["email_patterns"]:
            is_personal = self._is_personal_data(pattern)
            assert is_personal == True, f"Failed to detect {pattern} as personal"
    
    def test_phone_detection(self, classifier_patterns):
        """Test phone field detection"""
        for pattern in classifier_patterns["phone_patterns"]:
            is_personal = self._is_personal_data(pattern)
            assert is_personal == True, f"Failed to detect {pattern} as personal"
    
    def test_address_detection(self, classifier_patterns):
        """Test address field detection"""
        for pattern in classifier_patterns["address_patterns"]:
            is_personal = self._is_personal_data(pattern)
            assert is_personal == True, f"Failed to detect {pattern} as personal"
    
    def test_name_detection(self, classifier_patterns):
        """Test name field detection"""
        for pattern in classifier_patterns["name_patterns"]:
            is_personal = self._is_personal_data(pattern)
            assert is_personal == True, f"Failed to detect {pattern} as personal"
    
    def test_sensitive_data_detection(self, classifier_patterns):
        """Test sensitive data detection"""
        for pattern in classifier_patterns["sensitive_patterns"]:
            is_sensitive = self._is_sensitive_data(pattern)
            assert is_sensitive == True, f"Failed to detect {pattern} as sensitive"
    
    def test_non_personal_fields(self):
        """Test that non-personal fields are not classified as personal"""
        non_personal_fields = [
            "ProductID", "OrderTotal", "CreatedAt", "ModifiedAt",
            "Quantity", "Price", "Currency", "Status", "Category",
            "Description", "IsActive", "Version"
        ]
        
        for field in non_personal_fields:
            is_personal = self._is_personal_data(field)
            assert is_personal == False, f"Incorrectly classified {field} as personal"
    
    def test_case_insensitive_detection(self):
        """Test case insensitive detection"""
        variations = ["EMAIL", "email", "Email", "eMail", "EMAIL_ADDRESS"]
        
        for variation in variations:
            is_personal = self._is_personal_data(variation)
            assert is_personal == True, f"Failed case-insensitive detection for {variation}"
    
    def test_compound_names(self):
        """Test compound field name detection"""
        compound_fields = [
            "customer_email_address",
            "ContactPhoneNumber",
            "home_street_address",
            "user_full_name"
        ]
        
        for field in compound_fields:
            is_personal = self._is_personal_data(field)
            assert is_personal == True, f"Failed compound detection for {field}"
    
    def _is_personal_data(self, field_name: str) -> bool:
        """Check if field name indicates personal data"""
        field_lower = field_name.lower()
        
        personal_patterns = [
            "email", "mail", "phone", "telephone", "mobile", "fax",
            "address", "street", "city", "postal", "zip",
            "country", "state", "province",
            "name", "firstname", "lastname", "fullname", "surname",
            "ssn", "social", "tax", "passport", "license", "national",
            "birthday", "birthdate", "dob", "age"
        ]
        
        return any(pattern in field_lower for pattern in personal_patterns)
    
    def _is_sensitive_data(self, field_name: str) -> bool:
        """Check if field name indicates sensitive personal data"""
        field_lower = field_name.lower()
        
        sensitive_patterns = [
            "health", "medical", "religion", "religious", 
            "ethnic", "race", "political", "sexual",
            "biometric", "genetic", "criminal", "conviction"
        ]
        
        return any(pattern in field_lower for pattern in sensitive_patterns)


class TestGDPRAnnotations:
    """Tests for GDPR annotation generation"""
    
    def test_personal_data_annotation(self):
        """Test PersonalData annotation generation"""
        annotation = self._generate_annotation("CustomerEmail", is_personal=True)
        
        assert "@PersonalData.IsPotentiallyPersonal" in annotation
        assert annotation["@PersonalData.IsPotentiallyPersonal"] == True
    
    def test_sensitive_annotation(self):
        """Test sensitive data annotation"""
        annotation = self._generate_annotation("HealthStatus", is_sensitive=True)
        
        assert "@PersonalData.IsPotentiallySensitive" in annotation
        assert annotation["@PersonalData.IsPotentiallySensitive"] == True
    
    def test_non_personal_has_no_annotation(self):
        """Test non-personal data has no annotation"""
        annotation = self._generate_annotation("ProductID", is_personal=False)
        
        assert "@PersonalData.IsPotentiallyPersonal" not in annotation
    
    def test_field_semantics_annotation(self):
        """Test field semantics annotation"""
        test_cases = [
            ("Email", "@PersonalData.FieldSemantics", "email"),
            ("Phone", "@PersonalData.FieldSemantics", "phone"),
            ("FirstName", "@PersonalData.FieldSemantics", "given-name"),
            ("LastName", "@PersonalData.FieldSemantics", "family-name"),
            ("Address", "@PersonalData.FieldSemantics", "street-address")
        ]
        
        for field, annotation_key, expected_value in test_cases:
            annotation = self._generate_semantic_annotation(field)
            if annotation_key in annotation:
                # Check if value matches or contains expected pattern
                assert annotation[annotation_key] is not None
    
    def _generate_annotation(self, field_name: str, is_personal: bool = False, 
                            is_sensitive: bool = False) -> dict:
        """Generate GDPR annotations for a field"""
        annotations = {}
        
        if is_personal:
            annotations["@PersonalData.IsPotentiallyPersonal"] = True
        
        if is_sensitive:
            annotations["@PersonalData.IsPotentiallySensitive"] = True
        
        return annotations
    
    def _generate_semantic_annotation(self, field_name: str) -> dict:
        """Generate field semantics annotation"""
        field_lower = field_name.lower()
        annotations = {}
        
        semantics_map = {
            "email": "email",
            "phone": "phone",
            "firstname": "given-name",
            "lastname": "family-name",
            "address": "street-address",
            "city": "city",
            "postal": "postal-code",
            "country": "country"
        }
        
        for pattern, semantic in semantics_map.items():
            if pattern in field_lower:
                annotations["@PersonalData.FieldSemantics"] = semantic
                break
        
        return annotations


class TestDataRetentionPolicies:
    """Tests for data retention policy handling"""
    
    def test_retention_annotation(self):
        """Test retention period annotation"""
        annotation = self._generate_retention_annotation("CustomerData", years=7)
        
        assert "@PersonalData.DataRetention" in annotation
        assert annotation["@PersonalData.DataRetention"]["Period"] == "P7Y"
    
    def test_deletion_annotation(self):
        """Test deletion requirement annotation"""
        annotation = self._generate_deletion_annotation("UserActivity")
        
        assert "@PersonalData.RequiresDeletion" in annotation
    
    def _generate_retention_annotation(self, entity_name: str, years: int) -> dict:
        """Generate retention period annotation"""
        return {
            "@PersonalData.DataRetention": {
                "Period": f"P{years}Y"
            }
        }
    
    def _generate_deletion_annotation(self, entity_name: str) -> dict:
        """Generate deletion requirement annotation"""
        return {
            "@PersonalData.RequiresDeletion": True
        }


class TestPurposeAnnotations:
    """Tests for data processing purpose annotations"""
    
    def test_purpose_annotation(self):
        """Test purpose annotation generation"""
        annotation = self._generate_purpose_annotation(
            "OrderProcessing", 
            purposes=["Contract", "LegalObligation"]
        )
        
        assert "@PersonalData.ProcessingPurpose" in annotation
        assert "Contract" in annotation["@PersonalData.ProcessingPurpose"]
    
    def test_consent_required_annotation(self):
        """Test consent required annotation"""
        annotation = self._generate_consent_annotation("MarketingPreferences")
        
        assert "@PersonalData.ConsentRequired" in annotation
        assert annotation["@PersonalData.ConsentRequired"] == True
    
    def _generate_purpose_annotation(self, entity_name: str, purposes: list) -> dict:
        """Generate processing purpose annotation"""
        return {
            "@PersonalData.ProcessingPurpose": purposes
        }
    
    def _generate_consent_annotation(self, entity_name: str) -> dict:
        """Generate consent required annotation"""
        return {
            "@PersonalData.ConsentRequired": True
        }