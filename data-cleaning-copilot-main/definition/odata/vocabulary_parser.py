"""
OData Vocabulary Parser

Parses OData CSDL vocabulary XML files (e.g., SAP Common.xml, Validation.xml)
and extracts terms with validation semantics that can be converted to pandera checks.

This module handles:
- XML parsing of OData vocabulary files
- Extraction of term definitions, types, and descriptions
- Identification of validation-relevant terms (regex patterns, constraints)
- Building a registry of terms for easy lookup

References:
- OData CSDL XML: https://docs.oasis-open.org/odata/odata-csdl-xml/v4.01/
- SAP Vocabularies: https://github.com/SAP/odata-vocabularies
"""

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Union
from loguru import logger


class TermCategory(Enum):
    """Categories of OData vocabulary terms based on their validation semantics."""
    
    STRING_FORMAT = "string_format"      # Terms like IsDigitSequence, IsUpperCase
    DATE_FORMAT = "date_format"          # Calendar and fiscal date patterns
    FIELD_CONTROL = "field_control"      # Mandatory, Optional, ReadOnly
    CARDINALITY = "cardinality"          # MinOccurs, MaxOccurs
    SEMANTIC_TYPE = "semantic_type"      # IsCurrency, IsUnit
    VALUE_CONSTRAINT = "value_constraint"  # Value ranges, enumerations
    OTHER = "other"                       # Non-validation terms


@dataclass
class ODataTerm:
    """Represents a single OData vocabulary term."""
    
    name: str
    qualified_name: str  # e.g., "com.sap.vocabularies.Common.v1.IsDigitSequence"
    type: str  # e.g., "Edm.Boolean", "Tag", "String"
    description: str
    applies_to: List[str] = field(default_factory=list)  # e.g., ["Property", "Parameter"]
    is_collection: bool = False
    default_value: Optional[Any] = None
    
    # Validation-specific fields
    category: TermCategory = TermCategory.OTHER
    regex_pattern: Optional[str] = None  # Extracted from description if present
    is_nullable: bool = True
    enum_values: List[str] = field(default_factory=list)  # For enumeration types
    
    # Metadata
    is_experimental: bool = False
    is_deprecated: bool = False


@dataclass
class ODataEnumType:
    """Represents an OData enumeration type."""
    
    name: str
    qualified_name: str
    underlying_type: str  # e.g., "Edm.Int32", "Edm.Byte"
    members: Dict[str, int] = field(default_factory=dict)  # member name -> value
    is_flags: bool = False


@dataclass
class ODataComplexType:
    """Represents an OData complex type."""
    
    name: str
    qualified_name: str
    properties: Dict[str, str] = field(default_factory=dict)  # property name -> type
    base_type: Optional[str] = None


@dataclass
class ODataVocabulary:
    """Represents a parsed OData vocabulary."""
    
    namespace: str
    alias: Optional[str]
    terms: Dict[str, ODataTerm] = field(default_factory=dict)
    enum_types: Dict[str, ODataEnumType] = field(default_factory=dict)
    complex_types: Dict[str, ODataComplexType] = field(default_factory=dict)
    
    def get_term(self, name: str) -> Optional[ODataTerm]:
        """Get a term by name (short or qualified)."""
        if name in self.terms:
            return self.terms[name]
        # Try qualified name
        qualified = f"{self.namespace}.{name}"
        return self.terms.get(qualified)
    
    def get_validation_terms(self) -> List[ODataTerm]:
        """Get all terms with validation semantics."""
        return [
            term for term in self.terms.values()
            if term.category != TermCategory.OTHER
        ]


class ODataVocabularyParser:
    """
    Parser for OData vocabulary XML files.
    
    Extracts terms, types, and validation-relevant metadata from
    SAP OData vocabulary definitions.
    """
    
    # XML namespaces used in OData CSDL
    NAMESPACES = {
        "edmx": "http://docs.oasis-open.org/odata/ns/edmx",
        "edm": "http://docs.oasis-open.org/odata/ns/edm",
    }
    
    # Regex patterns commonly found in SAP vocabulary descriptions
    DESCRIPTION_REGEX_PATTERNS = {
        # Calendar patterns
        r"matches the regex pattern\s+([^\s]+)": lambda m: m.group(1),
        r"The string matches the regex pattern\s+([^\s]+)": lambda m: m.group(1),
        r"regex pattern\s+([A-Za-z0-9\[\]\|\-\?\+\*\(\)\{\}\^\\]+)": lambda m: m.group(1),
    }
    
    # Known validation terms and their categories
    VALIDATION_TERM_CATEGORIES: Dict[str, TermCategory] = {
        # String format terms
        "IsDigitSequence": TermCategory.STRING_FORMAT,
        "IsUpperCase": TermCategory.STRING_FORMAT,
        
        # Calendar date terms
        "IsCalendarYear": TermCategory.DATE_FORMAT,
        "IsCalendarHalfyear": TermCategory.DATE_FORMAT,
        "IsCalendarQuarter": TermCategory.DATE_FORMAT,
        "IsCalendarMonth": TermCategory.DATE_FORMAT,
        "IsCalendarWeek": TermCategory.DATE_FORMAT,
        "IsDayOfCalendarMonth": TermCategory.DATE_FORMAT,
        "IsDayOfCalendarYear": TermCategory.DATE_FORMAT,
        "IsCalendarYearHalfyear": TermCategory.DATE_FORMAT,
        "IsCalendarYearQuarter": TermCategory.DATE_FORMAT,
        "IsCalendarYearMonth": TermCategory.DATE_FORMAT,
        "IsCalendarYearWeek": TermCategory.DATE_FORMAT,
        "IsCalendarDate": TermCategory.DATE_FORMAT,
        
        # Fiscal date terms
        "IsFiscalYear": TermCategory.DATE_FORMAT,
        "IsFiscalPeriod": TermCategory.DATE_FORMAT,
        "IsFiscalYearPeriod": TermCategory.DATE_FORMAT,
        "IsFiscalQuarter": TermCategory.DATE_FORMAT,
        "IsFiscalYearQuarter": TermCategory.DATE_FORMAT,
        "IsFiscalWeek": TermCategory.DATE_FORMAT,
        "IsFiscalYearWeek": TermCategory.DATE_FORMAT,
        "IsDayOfFiscalYear": TermCategory.DATE_FORMAT,
        "IsFiscalYearVariant": TermCategory.DATE_FORMAT,
        
        # Field control
        "FieldControl": TermCategory.FIELD_CONTROL,
        "Nullable": TermCategory.FIELD_CONTROL,
        
        # Cardinality
        "MinOccurs": TermCategory.CARDINALITY,
        "MaxOccurs": TermCategory.CARDINALITY,
        
        # Semantic types
        "IsCurrency": TermCategory.SEMANTIC_TYPE,
        "IsUnit": TermCategory.SEMANTIC_TYPE,
        "IsLanguageIdentifier": TermCategory.SEMANTIC_TYPE,
        "IsTimezone": TermCategory.SEMANTIC_TYPE,
    }
    
    # Known regex patterns for terms (extracted from Common.md documentation)
    KNOWN_REGEX_PATTERNS: Dict[str, str] = {
        "IsCalendarYear": r"-?([1-9][0-9]{3,}|0[0-9]{3})",
        "IsCalendarHalfyear": r"[1-2]",
        "IsCalendarQuarter": r"[1-4]",
        "IsCalendarMonth": r"0[1-9]|1[0-2]",
        "IsCalendarWeek": r"0[1-9]|[1-4][0-9]|5[0-3]",
        "IsCalendarYearHalfyear": r"-?([1-9][0-9]{3,}|0[0-9]{3})[1-2]",
        "IsCalendarYearQuarter": r"-?([1-9][0-9]{3,}|0[0-9]{3})[1-4]",
        "IsCalendarYearMonth": r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|1[0-2])",
        "IsCalendarYearWeek": r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|[1-4][0-9]|5[0-3])",
        "IsCalendarDate": r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])",
        "IsFiscalYear": r"[1-9][0-9]{3}",
        "IsFiscalPeriod": r"[0-9]{3}",
        "IsFiscalYearPeriod": r"([1-9][0-9]{3})([0-9]{3})",
        "IsFiscalQuarter": r"[1-4]",
        "IsFiscalYearQuarter": r"[1-9][0-9]{3}[1-4]",
        "IsFiscalWeek": r"0[1-9]|[1-4][0-9]|5[0-3]",
        "IsFiscalYearWeek": r"[1-9][0-9]{3}(0[1-9]|[1-4][0-9]|5[0-3])",
        "IsDigitSequence": r"^\d+$",
    }
    
    def __init__(self):
        """Initialize the parser."""
        self._vocabularies: Dict[str, ODataVocabulary] = {}
    
    def parse_file(self, file_path: Union[str, Path]) -> ODataVocabulary:
        """
        Parse an OData vocabulary XML file.
        
        Args:
            file_path: Path to the vocabulary XML file
            
        Returns:
            Parsed ODataVocabulary object
            
        Raises:
            FileNotFoundError: If the file doesn't exist
            ET.ParseError: If the XML is malformed
        """
        file_path = Path(file_path)
        if not file_path.exists():
            raise FileNotFoundError(f"Vocabulary file not found: {file_path}")
        
        logger.info(f"Parsing vocabulary file: {file_path}")
        tree = ET.parse(file_path)
        root = tree.getroot()
        
        return self._parse_root(root)
    
    def parse_string(self, xml_content: str) -> ODataVocabulary:
        """
        Parse OData vocabulary from XML string.
        
        Args:
            xml_content: XML content as string
            
        Returns:
            Parsed ODataVocabulary object
        """
        root = ET.fromstring(xml_content)
        return self._parse_root(root)
    
    def _parse_root(self, root: ET.Element) -> ODataVocabulary:
        """Parse the root element of the vocabulary document."""
        # Find the Schema element
        schema = root.find(".//edm:Schema", self.NAMESPACES)
        if schema is None:
            # Try without namespace
            schema = root.find(".//Schema")
        
        if schema is None:
            raise ValueError("No Schema element found in vocabulary document")
        
        namespace = schema.get("Namespace", "")
        alias = schema.get("Alias")
        
        vocabulary = ODataVocabulary(namespace=namespace, alias=alias)
        
        # Parse enum types
        for enum_elem in schema.findall("edm:EnumType", self.NAMESPACES):
            enum_type = self._parse_enum_type(enum_elem, namespace)
            vocabulary.enum_types[enum_type.name] = enum_type
        
        # Also try without namespace
        for enum_elem in schema.findall("EnumType"):
            enum_type = self._parse_enum_type(enum_elem, namespace)
            vocabulary.enum_types[enum_type.name] = enum_type
        
        # Parse complex types
        for complex_elem in schema.findall("edm:ComplexType", self.NAMESPACES):
            complex_type = self._parse_complex_type(complex_elem, namespace)
            vocabulary.complex_types[complex_type.name] = complex_type
        
        for complex_elem in schema.findall("ComplexType"):
            complex_type = self._parse_complex_type(complex_elem, namespace)
            vocabulary.complex_types[complex_type.name] = complex_type
        
        # Parse terms
        for term_elem in schema.findall("edm:Term", self.NAMESPACES):
            term = self._parse_term(term_elem, namespace, vocabulary)
            vocabulary.terms[term.name] = term
        
        for term_elem in schema.findall("Term"):
            term = self._parse_term(term_elem, namespace, vocabulary)
            vocabulary.terms[term.name] = term
        
        logger.info(
            f"Parsed vocabulary {namespace}: "
            f"{len(vocabulary.terms)} terms, "
            f"{len(vocabulary.enum_types)} enums, "
            f"{len(vocabulary.complex_types)} complex types"
        )
        
        return vocabulary
    
    def _parse_enum_type(self, elem: ET.Element, namespace: str) -> ODataEnumType:
        """Parse an EnumType element."""
        name = elem.get("Name", "")
        underlying_type = elem.get("UnderlyingType", "Edm.Int32")
        is_flags = elem.get("IsFlags", "false").lower() == "true"
        
        members = {}
        for member_elem in elem.findall("edm:Member", self.NAMESPACES):
            member_name = member_elem.get("Name", "")
            member_value = int(member_elem.get("Value", len(members)))
            members[member_name] = member_value
        
        # Try without namespace
        for member_elem in elem.findall("Member"):
            member_name = member_elem.get("Name", "")
            member_value = int(member_elem.get("Value", len(members)))
            members[member_name] = member_value
        
        return ODataEnumType(
            name=name,
            qualified_name=f"{namespace}.{name}",
            underlying_type=underlying_type,
            members=members,
            is_flags=is_flags,
        )
    
    def _parse_complex_type(self, elem: ET.Element, namespace: str) -> ODataComplexType:
        """Parse a ComplexType element."""
        name = elem.get("Name", "")
        base_type = elem.get("BaseType")
        
        properties = {}
        for prop_elem in elem.findall("edm:Property", self.NAMESPACES):
            prop_name = prop_elem.get("Name", "")
            prop_type = prop_elem.get("Type", "Edm.String")
            properties[prop_name] = prop_type
        
        for prop_elem in elem.findall("Property"):
            prop_name = prop_elem.get("Name", "")
            prop_type = prop_elem.get("Type", "Edm.String")
            properties[prop_name] = prop_type
        
        return ODataComplexType(
            name=name,
            qualified_name=f"{namespace}.{name}",
            properties=properties,
            base_type=base_type,
        )
    
    def _parse_term(
        self, elem: ET.Element, namespace: str, vocabulary: ODataVocabulary
    ) -> ODataTerm:
        """Parse a Term element."""
        name = elem.get("Name", "")
        term_type = elem.get("Type", "Edm.String")
        applies_to_str = elem.get("AppliesTo", "")
        applies_to = [a.strip() for a in applies_to_str.split()] if applies_to_str else []
        default_value = elem.get("DefaultValue")
        nullable = elem.get("Nullable", "true").lower() == "true"
        
        # Check if it's a collection type
        is_collection = term_type.startswith("Collection(")
        if is_collection:
            term_type = term_type[11:-1]  # Remove "Collection(" and ")"
        
        # Get description from nested Annotation
        description = ""
        for annot in elem.findall("edm:Annotation", self.NAMESPACES):
            if annot.get("Term", "").endswith("Description"):
                description = annot.get("String", "")
                break
        
        for annot in elem.findall("Annotation"):
            if annot.get("Term", "").endswith("Description"):
                description = annot.get("String", "")
                break
        
        # Check for experimental/deprecated status
        is_experimental = False
        is_deprecated = False
        for annot in elem.findall("edm:Annotation", self.NAMESPACES):
            term = annot.get("Term", "")
            if "Experimental" in term:
                is_experimental = True
            if "Deprecated" in term or "Revisions" in term:
                is_deprecated = True
        
        for annot in elem.findall("Annotation"):
            term = annot.get("Term", "")
            if "Experimental" in term:
                is_experimental = True
            if "Deprecated" in term or "Revisions" in term:
                is_deprecated = True
        
        # Determine category and regex pattern
        category = self.VALIDATION_TERM_CATEGORIES.get(name, TermCategory.OTHER)
        regex_pattern = self.KNOWN_REGEX_PATTERNS.get(name)
        
        # Try to extract regex from description if not known
        if regex_pattern is None and description:
            regex_pattern = self._extract_regex_from_description(description)
        
        # Get enum values if type is an enum
        enum_values = []
        if term_type in vocabulary.enum_types:
            enum_values = list(vocabulary.enum_types[term_type].members.keys())
        
        return ODataTerm(
            name=name,
            qualified_name=f"{namespace}.{name}",
            type=term_type,
            description=description,
            applies_to=applies_to,
            is_collection=is_collection,
            default_value=default_value,
            category=category,
            regex_pattern=regex_pattern,
            is_nullable=nullable,
            enum_values=enum_values,
            is_experimental=is_experimental,
            is_deprecated=is_deprecated,
        )
    
    def _extract_regex_from_description(self, description: str) -> Optional[str]:
        """Try to extract a regex pattern from the term description."""
        for pattern, extractor in self.DESCRIPTION_REGEX_PATTERNS.items():
            match = re.search(pattern, description)
            if match:
                return extractor(match)
        return None


class ValidationTermRegistry:
    """
    Registry of validation-relevant OData terms.
    
    Provides easy access to terms that can be converted to pandera checks.
    """
    
    def __init__(self):
        """Initialize the registry."""
        self._terms: Dict[str, ODataTerm] = {}
        self._by_category: Dict[TermCategory, List[ODataTerm]] = {
            cat: [] for cat in TermCategory
        }
    
    def register_vocabulary(self, vocabulary: ODataVocabulary) -> int:
        """
        Register all validation terms from a vocabulary.
        
        Args:
            vocabulary: Parsed OData vocabulary
            
        Returns:
            Number of validation terms registered
        """
        count = 0
        for term in vocabulary.get_validation_terms():
            self._terms[term.name] = term
            self._terms[term.qualified_name] = term
            self._by_category[term.category].append(term)
            count += 1
        
        logger.info(f"Registered {count} validation terms from {vocabulary.namespace}")
        return count
    
    def get_term(self, name: str) -> Optional[ODataTerm]:
        """Get a term by name or qualified name."""
        return self._terms.get(name)
    
    def get_terms_by_category(self, category: TermCategory) -> List[ODataTerm]:
        """Get all terms in a specific category."""
        return self._by_category.get(category, [])
    
    def get_all_terms(self) -> List[ODataTerm]:
        """Get all registered validation terms (deduplicated)."""
        seen = set()
        result = []
        for term in self._terms.values():
            if term.qualified_name not in seen:
                seen.add(term.qualified_name)
                result.append(term)
        return result
    
    def get_string_format_terms(self) -> List[ODataTerm]:
        """Get terms for string format validation."""
        return self.get_terms_by_category(TermCategory.STRING_FORMAT)
    
    def get_date_format_terms(self) -> List[ODataTerm]:
        """Get terms for date format validation."""
        return self.get_terms_by_category(TermCategory.DATE_FORMAT)
    
    def get_terms_with_regex(self) -> List[ODataTerm]:
        """Get all terms that have a regex pattern."""
        return [term for term in self.get_all_terms() if term.regex_pattern]
    
    def summary(self) -> Dict[str, Any]:
        """Get a summary of registered terms."""
        return {
            "total_terms": len(self.get_all_terms()),
            "by_category": {
                cat.value: len(terms) for cat, terms in self._by_category.items()
            },
            "with_regex": len(self.get_terms_with_regex()),
        }


def load_sap_vocabularies(vocabulary_dir: Union[str, Path]) -> ValidationTermRegistry:
    """
    Load all SAP vocabularies from a directory.
    
    Args:
        vocabulary_dir: Path to directory containing vocabulary XML files
        
    Returns:
        ValidationTermRegistry with all terms loaded
    """
    vocabulary_dir = Path(vocabulary_dir)
    parser = ODataVocabularyParser()
    registry = ValidationTermRegistry()
    
    # List of SAP vocabulary files to load
    vocabulary_files = [
        "Common.xml",
        "Validation.xml",
        # Add more as needed
    ]
    
    for vocab_file in vocabulary_files:
        vocab_path = vocabulary_dir / vocab_file
        if vocab_path.exists():
            try:
                vocabulary = parser.parse_file(vocab_path)
                registry.register_vocabulary(vocabulary)
            except Exception as e:
                logger.warning(f"Failed to parse {vocab_file}: {e}")
    
    return registry