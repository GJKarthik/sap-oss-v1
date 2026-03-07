#!/usr/bin/env python3
"""
OData Vocabulary Parser
Parses SAP OData vocabulary XML files and extracts semantic information
"""

import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional, List, Dict, Any
from dataclasses import dataclass, field
from enum import Enum


class AnnotationType(str, Enum):
    UI = "UI"
    COMMON = "Common"
    COMMUNICATION = "Communication"
    ANALYTICS = "Analytics"
    PERSONAL_DATA = "PersonalData"
    HTML5 = "HTML5"


@dataclass
class Term:
    """Represents an OData vocabulary term."""
    name: str
    type: str
    applies_to: List[str] = field(default_factory=list)
    description: str = ""
    default_value: Optional[Any] = None
    nullable: bool = True
    base_term: Optional[str] = None


@dataclass
class Property:
    """Represents a property within a complex type."""
    name: str
    type: str
    nullable: bool = True
    description: str = ""


@dataclass
class ComplexType:
    """Represents an OData complex type."""
    name: str
    properties: List[Property] = field(default_factory=list)
    base_type: Optional[str] = None
    description: str = ""


@dataclass
class EnumMember:
    """Represents an enum member."""
    name: str
    value: Optional[int] = None
    description: str = ""


@dataclass
class EnumType:
    """Represents an OData enum type."""
    name: str
    members: List[EnumMember] = field(default_factory=list)
    underlying_type: str = "Edm.Int32"
    is_flags: bool = False
    description: str = ""


@dataclass
class Vocabulary:
    """Represents a complete OData vocabulary."""
    namespace: str
    alias: str
    terms: List[Term] = field(default_factory=list)
    complex_types: List[ComplexType] = field(default_factory=list)
    enum_types: List[EnumType] = field(default_factory=list)
    description: str = ""


class ODataVocabularyParser:
    """Parser for OData vocabulary XML files."""
    
    ODATA_NS = {
        "edmx": "http://docs.oasis-open.org/odata/ns/edmx",
        "edm": "http://docs.oasis-open.org/odata/ns/edm",
    }
    
    def __init__(self, vocab_dir: Optional[Path] = None):
        self.vocab_dir = vocab_dir or Path(__file__).parent.parent.parent / "vocabularies"
    
    def parse_file(self, xml_path: Path) -> Vocabulary:
        """Parse a single vocabulary XML file."""
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        # Find the Schema element
        schema = root.find(".//edm:Schema", self.ODATA_NS)
        if schema is None:
            # Try without namespace
            schema = root.find(".//{http://docs.oasis-open.org/odata/ns/edm}Schema")
        
        if schema is None:
            raise ValueError(f"No Schema element found in {xml_path}")
        
        namespace = schema.get("Namespace", "")
        alias = schema.get("Alias", "")
        
        vocab = Vocabulary(
            namespace=namespace,
            alias=alias,
            terms=self._parse_terms(schema),
            complex_types=self._parse_complex_types(schema),
            enum_types=self._parse_enum_types(schema),
        )
        
        return vocab
    
    def _parse_terms(self, schema: ET.Element) -> List[Term]:
        """Parse Term elements from schema."""
        terms = []
        for term_elem in schema.findall("{http://docs.oasis-open.org/odata/ns/edm}Term"):
            term = Term(
                name=term_elem.get("Name", ""),
                type=term_elem.get("Type", "Edm.Boolean"),
                applies_to=self._parse_applies_to(term_elem.get("AppliesTo", "")),
                nullable=term_elem.get("Nullable", "true").lower() == "true",
                default_value=term_elem.get("DefaultValue"),
                base_term=term_elem.get("BaseTerm"),
            )
            
            # Get description from Annotation
            for anno in term_elem.findall("{http://docs.oasis-open.org/odata/ns/edm}Annotation"):
                if "Description" in anno.get("Term", ""):
                    term.description = anno.get("String", "")
            
            terms.append(term)
        
        return terms
    
    def _parse_applies_to(self, applies_to: str) -> List[str]:
        """Parse AppliesTo attribute."""
        if not applies_to:
            return []
        return [s.strip() for s in applies_to.split()]
    
    def _parse_complex_types(self, schema: ET.Element) -> List[ComplexType]:
        """Parse ComplexType elements from schema."""
        types = []
        for ct_elem in schema.findall("{http://docs.oasis-open.org/odata/ns/edm}ComplexType"):
            ct = ComplexType(
                name=ct_elem.get("Name", ""),
                base_type=ct_elem.get("BaseType"),
                properties=self._parse_properties(ct_elem),
            )
            types.append(ct)
        return types
    
    def _parse_properties(self, parent: ET.Element) -> List[Property]:
        """Parse Property elements."""
        props = []
        for prop_elem in parent.findall("{http://docs.oasis-open.org/odata/ns/edm}Property"):
            prop = Property(
                name=prop_elem.get("Name", ""),
                type=prop_elem.get("Type", "Edm.String"),
                nullable=prop_elem.get("Nullable", "true").lower() == "true",
            )
            props.append(prop)
        return props
    
    def _parse_enum_types(self, schema: ET.Element) -> List[EnumType]:
        """Parse EnumType elements from schema."""
        enums = []
        for enum_elem in schema.findall("{http://docs.oasis-open.org/odata/ns/edm}EnumType"):
            enum = EnumType(
                name=enum_elem.get("Name", ""),
                underlying_type=enum_elem.get("UnderlyingType", "Edm.Int32"),
                is_flags=enum_elem.get("IsFlags", "false").lower() == "true",
                members=self._parse_enum_members(enum_elem),
            )
            enums.append(enum)
        return enums
    
    def _parse_enum_members(self, enum_elem: ET.Element) -> List[EnumMember]:
        """Parse enum members."""
        members = []
        for member_elem in enum_elem.findall("{http://docs.oasis-open.org/odata/ns/edm}Member"):
            value_str = member_elem.get("Value")
            member = EnumMember(
                name=member_elem.get("Name", ""),
                value=int(value_str) if value_str else None,
            )
            members.append(member)
        return members
    
    def parse_all_vocabularies(self) -> Dict[str, Vocabulary]:
        """Parse all vocabulary files in the vocabularies directory."""
        vocabs = {}
        for xml_file in self.vocab_dir.glob("*.xml"):
            try:
                vocab = self.parse_file(xml_file)
                vocabs[vocab.alias or vocab.namespace] = vocab
            except Exception as e:
                print(f"Error parsing {xml_file}: {e}")
        return vocabs
    
    def get_ui_annotations(self) -> Dict[str, Term]:
        """Get all UI-related terms for form generation."""
        vocabs = self.parse_all_vocabularies()
        ui_terms = {}
        
        if "UI" in vocabs:
            for term in vocabs["UI"].terms:
                ui_terms[term.name] = term
        
        return ui_terms
    
    def get_validation_terms(self) -> Dict[str, Term]:
        """Get terms useful for data validation."""
        vocabs = self.parse_all_vocabularies()
        validation_terms = {}
        
        # Common vocabulary has validation-related terms
        if "Common" in vocabs:
            for term in vocabs["Common"].terms:
                if any(kw in term.name.lower() for kw in ["require", "valid", "pattern", "range"]):
                    validation_terms[term.name] = term
        
        return validation_terms


def vocabulary_to_dict(vocab: Vocabulary) -> Dict[str, Any]:
    """Convert vocabulary to dictionary for JSON serialization."""
    return {
        "namespace": vocab.namespace,
        "alias": vocab.alias,
        "description": vocab.description,
        "terms": [
            {
                "name": t.name,
                "type": t.type,
                "applies_to": t.applies_to,
                "description": t.description,
                "nullable": t.nullable,
            }
            for t in vocab.terms
        ],
        "complex_types": [
            {
                "name": ct.name,
                "base_type": ct.base_type,
                "properties": [
                    {"name": p.name, "type": p.type, "nullable": p.nullable}
                    for p in ct.properties
                ],
            }
            for ct in vocab.complex_types
        ],
        "enum_types": [
            {
                "name": et.name,
                "is_flags": et.is_flags,
                "members": [{"name": m.name, "value": m.value} for m in et.members],
            }
            for et in vocab.enum_types
        ],
    }


if __name__ == "__main__":
    # Example usage
    parser = ODataVocabularyParser()
    vocabs = parser.parse_all_vocabularies()
    
    print(f"Parsed {len(vocabs)} vocabularies:")
    for name, vocab in vocabs.items():
        print(f"  - {name}: {len(vocab.terms)} terms, {len(vocab.complex_types)} types")