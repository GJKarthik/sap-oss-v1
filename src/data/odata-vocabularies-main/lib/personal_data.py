"""
Personal Data Classifier for OData Vocabularies

Phase 4.1: PersonalData Vocabulary Integration
Automatic GDPR classification in entity extraction using OData PersonalData vocabulary.

This module provides automatic detection and classification of personal data fields
based on the SAP PersonalData vocabulary annotations.
"""

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set
from enum import Enum


class DataSubjectRole(Enum):
    """GDPR Data Subject Roles from PersonalData vocabulary"""
    DATA_SUBJECT = "DataSubject"
    DATA_SUBJECT_DETAILS = "DataSubjectDetails"
    OTHER = "Other"


class FieldSemantics(Enum):
    """PersonalData.FieldSemantics enum values"""
    # Contact info
    GIVEN_NAME = "givenName"
    FAMILY_NAME = "familyName"
    MIDDLE_NAME = "middleName"
    NICKNAME = "nickName"
    EMAIL_ADDRESS = "emailAddress"
    PHONE_NUMBER = "phoneNumber"
    FAX_NUMBER = "faxNumber"
    POSTAL_ADDRESS = "postalAddress"
    
    # Identity
    DATE_OF_BIRTH = "birthDate"
    GENDER = "gender"
    NATIONALITY = "nationality"
    
    # Financial
    BANK_ACCOUNT = "bankAccountNumber"
    TAX_ID = "taxIdentificationNumber"
    
    # Government IDs
    SOCIAL_SECURITY_NUMBER = "socialSecurityNumber"
    PASSPORT_NUMBER = "passportNumber"
    DRIVERS_LICENSE = "driversLicenseNumber"
    
    # Location
    GEO_LOCATION = "geoLocation"
    IP_ADDRESS = "ipAddress"
    
    # Other
    PHOTO = "photo"
    USER_ID = "userId"


@dataclass
class PersonalDataClassification:
    """Classification result for an entity or property"""
    entity_type: str
    is_data_subject: bool = False
    data_subject_role: Optional[DataSubjectRole] = None
    potentially_personal_fields: List[str] = field(default_factory=list)
    potentially_sensitive_fields: List[str] = field(default_factory=list)
    field_semantics: Dict[str, FieldSemantics] = field(default_factory=dict)
    end_of_business_date_field: Optional[str] = None
    data_retention_period: Optional[str] = None
    legal_basis: Optional[str] = None
    requires_consent: bool = False
    
    def to_dict(self) -> dict:
        return {
            "entity_type": self.entity_type,
            "is_data_subject": self.is_data_subject,
            "data_subject_role": self.data_subject_role.value if self.data_subject_role else None,
            "potentially_personal_fields": self.potentially_personal_fields,
            "potentially_sensitive_fields": self.potentially_sensitive_fields,
            "field_semantics": {k: v.value for k, v in self.field_semantics.items()},
            "end_of_business_date_field": self.end_of_business_date_field,
            "data_retention_period": self.data_retention_period,
            "legal_basis": self.legal_basis,
            "requires_consent": self.requires_consent
        }


class PersonalDataClassifier:
    """
    Classifies entities and properties for GDPR compliance using PersonalData vocabulary.
    
    Uses pattern matching and vocabulary annotations to automatically detect:
    - Data subject entities (customers, employees, etc.)
    - Potentially personal fields (names, emails, addresses)
    - Potentially sensitive fields (health, religion, ethnicity)
    - Field semantics for GDPR reporting
    """
    
    # Patterns for detecting personal data properties
    PERSONAL_PATTERNS = {
        # Names
        r"(?i)(first|given|last|family|middle|nick).*name": FieldSemantics.GIVEN_NAME,
        r"(?i)^name$": FieldSemantics.GIVEN_NAME,
        r"(?i)full.*name": FieldSemantics.GIVEN_NAME,
        
        # Contact
        r"(?i)e?mail": FieldSemantics.EMAIL_ADDRESS,
        r"(?i)phone|tel(ephone)?|mobile|cell": FieldSemantics.PHONE_NUMBER,
        r"(?i)fax": FieldSemantics.FAX_NUMBER,
        r"(?i)address|street|city|zip|postal|country": FieldSemantics.POSTAL_ADDRESS,
        
        # Identity
        r"(?i)(date.*birth|birth.*date|dob)": FieldSemantics.DATE_OF_BIRTH,
        r"(?i)gender|sex": FieldSemantics.GENDER,
        r"(?i)national": FieldSemantics.NATIONALITY,
        
        # Government IDs
        r"(?i)ssn|social.*security": FieldSemantics.SOCIAL_SECURITY_NUMBER,
        r"(?i)passport": FieldSemantics.PASSPORT_NUMBER,
        r"(?i)driver.*license|license.*number": FieldSemantics.DRIVERS_LICENSE,
        r"(?i)tax.*id": FieldSemantics.TAX_ID,
        
        # Financial
        r"(?i)bank.*account|iban|account.*number": FieldSemantics.BANK_ACCOUNT,
        
        # Technical
        r"(?i)ip.*address": FieldSemantics.IP_ADDRESS,
        r"(?i)(geo.*)?location|latitude|longitude|coords": FieldSemantics.GEO_LOCATION,
        r"(?i)photo|image|picture|avatar": FieldSemantics.PHOTO,
        r"(?i)user.*id|username|login": FieldSemantics.USER_ID,
    }
    
    # Patterns for sensitive data (GDPR special categories)
    SENSITIVE_PATTERNS = [
        r"(?i)health|medical|diagnosis|disease|treatment",
        r"(?i)ethnic|race|racial",
        r"(?i)religion|religious|belief",
        r"(?i)political|party|vote",
        r"(?i)sexual|orientation",
        r"(?i)genetic|dna|genome",
        r"(?i)biometric|fingerprint|facial",
        r"(?i)criminal|conviction|offense",
        r"(?i)union|membership",
    ]
    
    # Entity patterns that indicate data subjects
    DATA_SUBJECT_PATTERNS = [
        r"(?i)customer",
        r"(?i)employee|worker|staff",
        r"(?i)user|person|individual",
        r"(?i)contact|lead|prospect",
        r"(?i)patient|client",
        r"(?i)vendor|supplier|partner",
        r"(?i)applicant|candidate",
        r"(?i)member|subscriber",
    ]
    
    def __init__(self, vocabularies: Optional[Dict] = None):
        """
        Initialize classifier with optional vocabulary definitions.
        
        Args:
            vocabularies: Dict of vocabulary definitions (from MCP server)
        """
        self.vocabularies = vocabularies or {}
        self._compile_patterns()
    
    def _compile_patterns(self):
        """Pre-compile regex patterns for performance"""
        self._personal_patterns = [
            (re.compile(pattern), semantics) 
            for pattern, semantics in self.PERSONAL_PATTERNS.items()
        ]
        self._sensitive_patterns = [re.compile(p) for p in self.SENSITIVE_PATTERNS]
        self._data_subject_patterns = [re.compile(p) for p in self.DATA_SUBJECT_PATTERNS]
    
    def classify_entity(self, entity_type: str, properties: List[str] = None) -> PersonalDataClassification:
        """
        Classify an entity type for personal data.
        
        Args:
            entity_type: Name of the entity type
            properties: List of property names
            
        Returns:
            PersonalDataClassification with detected personal data fields
        """
        classification = PersonalDataClassification(entity_type=entity_type)
        
        # Check if entity is a data subject
        for pattern in self._data_subject_patterns:
            if pattern.search(entity_type):
                classification.is_data_subject = True
                classification.data_subject_role = DataSubjectRole.DATA_SUBJECT
                break
        
        # Classify properties
        if properties:
            for prop in properties:
                # Check for personal data
                for pattern, semantics in self._personal_patterns:
                    if pattern.search(prop):
                        classification.potentially_personal_fields.append(prop)
                        classification.field_semantics[prop] = semantics
                        break
                
                # Check for sensitive data
                for pattern in self._sensitive_patterns:
                    if pattern.search(prop):
                        if prop not in classification.potentially_sensitive_fields:
                            classification.potentially_sensitive_fields.append(prop)
                        break
                
                # Check for end of business date
                if re.search(r"(?i)(end|term|expire).*date|valid.*until", prop):
                    classification.end_of_business_date_field = prop
        
        # If personal fields found, check if consent required
        if classification.potentially_sensitive_fields:
            classification.requires_consent = True
        
        return classification
    
    def classify_from_annotations(self, entity_type: str, annotations: Dict) -> PersonalDataClassification:
        """
        Classify an entity using its OData PersonalData annotations.
        
        Args:
            entity_type: Name of the entity type
            annotations: Dict of OData annotations
            
        Returns:
            PersonalDataClassification based on annotations
        """
        classification = PersonalDataClassification(entity_type=entity_type)
        
        # Check for EntitySemantics annotation
        entity_semantics = annotations.get("@PersonalData.EntitySemantics")
        if entity_semantics:
            if entity_semantics == "DataSubject":
                classification.is_data_subject = True
                classification.data_subject_role = DataSubjectRole.DATA_SUBJECT
            elif entity_semantics == "DataSubjectDetails":
                classification.is_data_subject = True
                classification.data_subject_role = DataSubjectRole.DATA_SUBJECT_DETAILS
        
        # Check for IsPotentiallyPersonal annotations
        for key, value in annotations.items():
            if key.startswith("@PersonalData.IsPotentiallyPersonal#"):
                prop = key.split("#")[1]
                if value:
                    classification.potentially_personal_fields.append(prop)
            elif key.startswith("@PersonalData.IsPotentiallySensitive#"):
                prop = key.split("#")[1]
                if value:
                    classification.potentially_sensitive_fields.append(prop)
            elif key.startswith("@PersonalData.FieldSemantics#"):
                prop = key.split("#")[1]
                try:
                    classification.field_semantics[prop] = FieldSemantics(value)
                except ValueError:
                    pass
        
        return classification
    
    def mask_sensitive_fields(self, data: Dict, classification: PersonalDataClassification) -> Dict:
        """
        Mask sensitive fields in entity data.
        
        Args:
            data: Entity data dict
            classification: PersonalDataClassification for the entity
            
        Returns:
            Data with sensitive fields masked
        """
        masked = {}
        sensitive_fields = set(classification.potentially_sensitive_fields)
        
        for key, value in data.items():
            if key in sensitive_fields:
                masked[key] = "***MASKED***"
            elif isinstance(value, str) and len(value) > 4:
                # Partial masking for personal fields
                if key in classification.potentially_personal_fields:
                    masked[key] = value[:2] + "*" * (len(value) - 4) + value[-2:]
                else:
                    masked[key] = value
            else:
                masked[key] = value
        
        return masked
    
    def get_gdpr_metadata(self, entity_type: str, properties: List[str]) -> Dict:
        """
        Get GDPR metadata for data catalog.
        
        Args:
            entity_type: Name of the entity type
            properties: List of property names
            
        Returns:
            Dict with GDPR metadata for data catalog
        """
        classification = self.classify_entity(entity_type, properties)
        
        return {
            "gdpr_classification": {
                "entity_type": entity_type,
                "contains_personal_data": len(classification.potentially_personal_fields) > 0,
                "contains_sensitive_data": len(classification.potentially_sensitive_fields) > 0,
                "is_data_subject": classification.is_data_subject,
                "data_subject_role": classification.data_subject_role.value if classification.data_subject_role else None,
                "requires_consent": classification.requires_consent,
                "personal_fields_count": len(classification.potentially_personal_fields),
                "sensitive_fields_count": len(classification.potentially_sensitive_fields)
            },
            "personal_fields": classification.potentially_personal_fields,
            "sensitive_fields": classification.potentially_sensitive_fields,
            "field_semantics": {k: v.value for k, v in classification.field_semantics.items()},
            "recommended_annotations": self._generate_annotation_recommendations(classification)
        }
    
    def _generate_annotation_recommendations(self, classification: PersonalDataClassification) -> List[Dict]:
        """Generate recommended PersonalData annotations"""
        recommendations = []
        
        if classification.is_data_subject:
            recommendations.append({
                "annotation": "@PersonalData.EntitySemantics",
                "value": classification.data_subject_role.value if classification.data_subject_role else "DataSubject",
                "reason": "Entity represents a natural person"
            })
        
        for prop in classification.potentially_personal_fields:
            recommendations.append({
                "annotation": f"@PersonalData.IsPotentiallyPersonal#{prop}",
                "value": True,
                "reason": f"Field '{prop}' may contain personal data"
            })
        
        for prop in classification.potentially_sensitive_fields:
            recommendations.append({
                "annotation": f"@PersonalData.IsPotentiallySensitive#{prop}",
                "value": True,
                "reason": f"Field '{prop}' may contain sensitive personal data (GDPR special category)"
            })
        
        for prop, semantics in classification.field_semantics.items():
            recommendations.append({
                "annotation": f"@PersonalData.FieldSemantics#{prop}",
                "value": semantics.value,
                "reason": f"Field '{prop}' contains {semantics.value} data"
            })
        
        return recommendations


# Singleton instance for MCP server
_classifier_instance: Optional[PersonalDataClassifier] = None


def get_classifier(vocabularies: Dict = None) -> PersonalDataClassifier:
    """Get or create the PersonalDataClassifier singleton"""
    global _classifier_instance
    if _classifier_instance is None:
        _classifier_instance = PersonalDataClassifier(vocabularies)
    return _classifier_instance