"""
OData Metadata to Table Generator

Generates data-cleaning-copilot Table classes from OData $metadata CSDL documents.
This enables automatic creation of validation schemas from OData service definitions.

Features:
- Parse OData CSDL XML ($metadata responses)
- Generate pandera DataFrameModel subclasses
- Apply vocabulary annotations as pandera checks
- Support for primary keys, foreign keys, and nullable constraints

Example:
    from definition.odata.table_generator import ODataTableGenerator
    
    generator = ODataTableGenerator()
    
    # Generate Table class from metadata file
    tables = generator.generate_from_file("metadata.xml")
    
    # Or from metadata URL
    tables = generator.generate_from_url(
        "https://services.odata.org/V4/Northwind/$metadata"
    )
    
    # Register generated tables with Database
    db = Database("northwind")
    for table_name, table_class in tables.items():
        db.create_table(table_name, table_class)
"""

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple, Type, Union
import urllib.request
import urllib.error

import pandera as pa
from pandera import Column, DataFrameSchema, Check
from pandera.typing import Series
from loguru import logger

from definition.odata.vocabulary_parser import (
    ODataVocabularyParser,
    ODataVocabulary,
    ValidationTermRegistry,
)
from definition.odata.term_converter import ODataTermConverter


# OData EDM type to pandas/pandera type mapping
EDM_TYPE_MAPPING: Dict[str, str] = {
    # String types
    "Edm.String": "object",
    "Edm.Guid": "object",
    
    # Numeric types
    "Edm.Int16": "int64",
    "Edm.Int32": "int64",
    "Edm.Int64": "int64",
    "Edm.Byte": "int64",
    "Edm.SByte": "int64",
    "Edm.Single": "float64",
    "Edm.Double": "float64",
    "Edm.Decimal": "float64",
    
    # Boolean
    "Edm.Boolean": "bool",
    
    # Date/Time types
    "Edm.Date": "object",  # ISO date string
    "Edm.Time": "object",  # ISO time string
    "Edm.DateTime": "datetime64[ns]",
    "Edm.DateTimeOffset": "datetime64[ns]",
    "Edm.Duration": "object",
    "Edm.TimeOfDay": "object",
    
    # Binary
    "Edm.Binary": "object",
    
    # Geographic (stored as objects/JSON)
    "Edm.Geography": "object",
    "Edm.GeographyPoint": "object",
    "Edm.Geometry": "object",
    "Edm.GeometryPoint": "object",
    
    # Stream
    "Edm.Stream": "object",
}


@dataclass
class ODataProperty:
    """Represents an OData entity property."""
    
    name: str
    type: str
    nullable: bool = True
    max_length: Optional[int] = None
    precision: Optional[int] = None
    scale: Optional[int] = None
    default_value: Optional[Any] = None
    annotations: List[str] = field(default_factory=list)  # Vocabulary term names
    is_key: bool = False


@dataclass
class ODataNavigationProperty:
    """Represents an OData navigation property (foreign key relationship)."""
    
    name: str
    type: str  # Target entity type
    partner: Optional[str] = None
    nullable: bool = True
    is_collection: bool = False
    referential_constraints: Dict[str, str] = field(default_factory=dict)  # local -> referenced


@dataclass  
class ODataEntityType:
    """Represents an OData entity type."""
    
    name: str
    namespace: str
    properties: Dict[str, ODataProperty] = field(default_factory=dict)
    navigation_properties: Dict[str, ODataNavigationProperty] = field(default_factory=dict)
    key_properties: List[str] = field(default_factory=list)
    base_type: Optional[str] = None
    
    @property
    def qualified_name(self) -> str:
        return f"{self.namespace}.{self.name}"


@dataclass
class ODataMetadata:
    """Represents parsed OData $metadata."""
    
    namespace: str
    entity_types: Dict[str, ODataEntityType] = field(default_factory=dict)
    entity_sets: Dict[str, str] = field(default_factory=dict)  # set name -> entity type name


class ODataMetadataParser:
    """
    Parser for OData $metadata CSDL XML documents.
    
    Extracts entity types, properties, keys, and annotations from
    OData service metadata.
    """
    
    # XML namespaces used in OData CSDL
    NAMESPACES = {
        "edmx": "http://docs.oasis-open.org/odata/ns/edmx",
        "edm": "http://docs.oasis-open.org/odata/ns/edm",
    }
    
    def __init__(self):
        """Initialize the parser."""
        self._vocabularies: Dict[str, ODataVocabulary] = {}
    
    def parse_file(self, file_path: Union[str, Path]) -> ODataMetadata:
        """
        Parse OData metadata from a file.
        
        Args:
            file_path: Path to the $metadata XML file
            
        Returns:
            Parsed ODataMetadata object
        """
        file_path = Path(file_path)
        if not file_path.exists():
            raise FileNotFoundError(f"Metadata file not found: {file_path}")
        
        logger.info(f"Parsing metadata file: {file_path}")
        tree = ET.parse(file_path)
        root = tree.getroot()
        
        return self._parse_root(root)
    
    def parse_string(self, xml_content: str) -> ODataMetadata:
        """
        Parse OData metadata from XML string.
        
        Args:
            xml_content: XML content as string
            
        Returns:
            Parsed ODataMetadata object
        """
        root = ET.fromstring(xml_content)
        return self._parse_root(root)
    
    def parse_url(self, url: str, timeout: int = 30) -> ODataMetadata:
        """
        Parse OData metadata from a URL.
        
        Args:
            url: URL to fetch $metadata from
            timeout: Request timeout in seconds
            
        Returns:
            Parsed ODataMetadata object
        """
        logger.info(f"Fetching metadata from: {url}")
        
        try:
            req = urllib.request.Request(
                url,
                headers={"Accept": "application/xml"}
            )
            with urllib.request.urlopen(req, timeout=timeout) as response:
                xml_content = response.read().decode("utf-8")
            
            return self.parse_string(xml_content)
        except urllib.error.URLError as e:
            raise ConnectionError(f"Failed to fetch metadata from {url}: {e}")
    
    def _parse_root(self, root: ET.Element) -> ODataMetadata:
        """Parse the root element of the metadata document."""
        # Find the Schema element
        schema = root.find(".//edm:Schema", self.NAMESPACES)
        if schema is None:
            schema = root.find(".//Schema")
        
        if schema is None:
            raise ValueError("No Schema element found in metadata document")
        
        namespace = schema.get("Namespace", "")
        metadata = ODataMetadata(namespace=namespace)
        
        # Parse entity types
        for entity_elem in schema.findall("edm:EntityType", self.NAMESPACES):
            entity_type = self._parse_entity_type(entity_elem, namespace)
            metadata.entity_types[entity_type.name] = entity_type
        
        # Also try without namespace prefix
        for entity_elem in schema.findall("EntityType"):
            entity_type = self._parse_entity_type(entity_elem, namespace)
            if entity_type.name not in metadata.entity_types:
                metadata.entity_types[entity_type.name] = entity_type
        
        # Parse entity container for entity sets
        container = schema.find("edm:EntityContainer", self.NAMESPACES)
        if container is None:
            container = schema.find("EntityContainer")
        
        if container is not None:
            for entity_set in container.findall("edm:EntitySet", self.NAMESPACES):
                set_name = entity_set.get("Name", "")
                entity_type = entity_set.get("EntityType", "")
                # Extract type name from qualified name
                type_name = entity_type.split(".")[-1]
                metadata.entity_sets[set_name] = type_name
            
            for entity_set in container.findall("EntitySet"):
                set_name = entity_set.get("Name", "")
                entity_type = entity_set.get("EntityType", "")
                type_name = entity_type.split(".")[-1]
                if set_name not in metadata.entity_sets:
                    metadata.entity_sets[set_name] = type_name
        
        logger.info(
            f"Parsed metadata {namespace}: "
            f"{len(metadata.entity_types)} entity types, "
            f"{len(metadata.entity_sets)} entity sets"
        )
        
        return metadata
    
    def _parse_entity_type(self, elem: ET.Element, namespace: str) -> ODataEntityType:
        """Parse an EntityType element."""
        name = elem.get("Name", "")
        base_type = elem.get("BaseType")
        
        entity_type = ODataEntityType(
            name=name,
            namespace=namespace,
            base_type=base_type,
        )
        
        # Parse key
        key_elem = elem.find("edm:Key", self.NAMESPACES)
        if key_elem is None:
            key_elem = elem.find("Key")
        
        if key_elem is not None:
            for prop_ref in key_elem.findall("edm:PropertyRef", self.NAMESPACES):
                entity_type.key_properties.append(prop_ref.get("Name", ""))
            for prop_ref in key_elem.findall("PropertyRef"):
                key_name = prop_ref.get("Name", "")
                if key_name not in entity_type.key_properties:
                    entity_type.key_properties.append(key_name)
        
        # Parse properties
        for prop_elem in elem.findall("edm:Property", self.NAMESPACES):
            prop = self._parse_property(prop_elem, entity_type.key_properties)
            entity_type.properties[prop.name] = prop
        
        for prop_elem in elem.findall("Property"):
            prop = self._parse_property(prop_elem, entity_type.key_properties)
            if prop.name not in entity_type.properties:
                entity_type.properties[prop.name] = prop
        
        # Parse navigation properties
        for nav_elem in elem.findall("edm:NavigationProperty", self.NAMESPACES):
            nav = self._parse_navigation_property(nav_elem)
            entity_type.navigation_properties[nav.name] = nav
        
        for nav_elem in elem.findall("NavigationProperty"):
            nav = self._parse_navigation_property(nav_elem)
            if nav.name not in entity_type.navigation_properties:
                entity_type.navigation_properties[nav.name] = nav
        
        return entity_type
    
    def _parse_property(
        self, elem: ET.Element, key_properties: List[str]
    ) -> ODataProperty:
        """Parse a Property element."""
        name = elem.get("Name", "")
        prop_type = elem.get("Type", "Edm.String")
        nullable = elem.get("Nullable", "true").lower() == "true"
        max_length = elem.get("MaxLength")
        precision = elem.get("Precision")
        scale = elem.get("Scale")
        default_value = elem.get("DefaultValue")
        
        # Parse annotations
        annotations = []
        for annot in elem.findall("edm:Annotation", self.NAMESPACES):
            term = annot.get("Term", "")
            if term:
                annotations.append(term)
        
        for annot in elem.findall("Annotation"):
            term = annot.get("Term", "")
            if term and term not in annotations:
                annotations.append(term)
        
        return ODataProperty(
            name=name,
            type=prop_type,
            nullable=nullable,
            max_length=int(max_length) if max_length else None,
            precision=int(precision) if precision else None,
            scale=int(scale) if scale else None,
            default_value=default_value,
            annotations=annotations,
            is_key=name in key_properties,
        )
    
    def _parse_navigation_property(self, elem: ET.Element) -> ODataNavigationProperty:
        """Parse a NavigationProperty element."""
        name = elem.get("Name", "")
        nav_type = elem.get("Type", "")
        partner = elem.get("Partner")
        nullable = elem.get("Nullable", "true").lower() == "true"
        
        # Check if collection type
        is_collection = nav_type.startswith("Collection(")
        if is_collection:
            nav_type = nav_type[11:-1]  # Remove "Collection(" and ")"
        
        # Parse referential constraints
        constraints = {}
        for ref_elem in elem.findall("edm:ReferentialConstraint", self.NAMESPACES):
            local_prop = ref_elem.get("Property", "")
            referenced_prop = ref_elem.get("ReferencedProperty", "")
            if local_prop and referenced_prop:
                constraints[local_prop] = referenced_prop
        
        for ref_elem in elem.findall("ReferentialConstraint"):
            local_prop = ref_elem.get("Property", "")
            referenced_prop = ref_elem.get("ReferencedProperty", "")
            if local_prop and referenced_prop and local_prop not in constraints:
                constraints[local_prop] = referenced_prop
        
        return ODataNavigationProperty(
            name=name,
            type=nav_type.split(".")[-1],  # Extract type name
            partner=partner,
            nullable=nullable,
            is_collection=is_collection,
            referential_constraints=constraints,
        )


class ODataTableGenerator:
    """
    Generates data-cleaning-copilot Table classes from OData metadata.
    
    Creates pandera DataFrameModel subclasses with appropriate columns,
    types, and validation checks based on OData entity definitions.
    """
    
    def __init__(
        self,
        vocabularies: Optional[List[ODataVocabulary]] = None,
        term_converter: Optional[ODataTermConverter] = None,
    ):
        """
        Initialize the generator.
        
        Args:
            vocabularies: Optional list of loaded OData vocabularies
            term_converter: Optional term converter instance
        """
        self.parser = ODataMetadataParser()
        self.term_converter = term_converter or ODataTermConverter()
        
        # Build vocabulary registry if vocabularies provided
        self.registry = ValidationTermRegistry()
        if vocabularies:
            for vocab in vocabularies:
                self.registry.register_vocabulary(vocab)
    
    def generate_from_file(
        self, file_path: Union[str, Path]
    ) -> Dict[str, Type]:
        """
        Generate Table classes from a metadata file.
        
        Args:
            file_path: Path to the $metadata XML file
            
        Returns:
            Dict mapping entity type names to generated Table classes
        """
        metadata = self.parser.parse_file(file_path)
        return self._generate_tables(metadata)
    
    def generate_from_string(self, xml_content: str) -> Dict[str, Type]:
        """
        Generate Table classes from XML string.
        
        Args:
            xml_content: OData $metadata XML content
            
        Returns:
            Dict mapping entity type names to generated Table classes
        """
        metadata = self.parser.parse_string(xml_content)
        return self._generate_tables(metadata)
    
    def generate_from_url(
        self, url: str, timeout: int = 30
    ) -> Dict[str, Type]:
        """
        Generate Table classes from a metadata URL.
        
        Args:
            url: URL to fetch $metadata from
            timeout: Request timeout in seconds
            
        Returns:
            Dict mapping entity type names to generated Table classes
        """
        metadata = self.parser.parse_url(url, timeout)
        return self._generate_tables(metadata)
    
    def _generate_tables(self, metadata: ODataMetadata) -> Dict[str, Type]:
        """Generate Table classes from parsed metadata."""
        tables = {}
        
        for entity_name, entity_type in metadata.entity_types.items():
            table_class = self._generate_table_class(entity_type, metadata)
            tables[entity_name] = table_class
            logger.info(f"Generated Table class for {entity_name}")
        
        return tables
    
    def _generate_table_class(
        self, entity_type: ODataEntityType, metadata: ODataMetadata
    ) -> Type:
        """
        Generate a Table class for an entity type.
        
        The generated class is a pandera DataFrameModel with:
        - Columns for each property with appropriate types
        - Checks derived from OData vocabulary annotations
        - Primary key metadata
        - Foreign key metadata from navigation properties
        """
        # Build column definitions
        columns = {}
        for prop_name, prop in entity_type.properties.items():
            column = self._create_column(prop)
            columns[prop_name] = column
        
        # Build foreign keys from navigation properties
        foreign_keys = {}
        for nav_name, nav_prop in entity_type.navigation_properties.items():
            for local_prop, ref_prop in nav_prop.referential_constraints.items():
                foreign_keys[local_prop] = (nav_prop.type, ref_prop)
        
        # Create the Table class dynamically
        class_name = f"{entity_type.name}Table"
        
        # Create schema with columns
        schema_dict = {
            "__annotations__": {},
        }
        
        for col_name, col_def in columns.items():
            schema_dict["__annotations__"][col_name] = Series[col_def["dtype"]]
        
        # Create the class
        table_class = type(
            class_name,
            (pa.DataFrameModel,),
            schema_dict,
        )
        
        # Add metadata as class attributes
        table_class._odata_entity_name = entity_type.name
        table_class._odata_namespace = entity_type.namespace
        table_class._primary_keys = entity_type.key_properties
        table_class._foreign_keys = foreign_keys
        table_class._column_checks = {
            name: col.get("checks", []) for name, col in columns.items()
        }
        
        # Add class methods for Table interface compatibility
        @classmethod
        def primary_keys(cls) -> List[str]:
            return cls._primary_keys
        
        @classmethod  
        def foreign_keys_method(cls) -> Dict[str, Tuple[str, str]]:
            return cls._foreign_keys
        
        @classmethod
        def columns(cls) -> Dict[str, Any]:
            return {
                name: pa.Column(
                    dtype=col["dtype"],
                    nullable=col["nullable"],
                    checks=col.get("checks", []),
                )
                for name, col in columns.items()
            }
        
        table_class.primary_keys = primary_keys
        table_class.foreign_keys = foreign_keys_method
        table_class.columns = columns
        
        return table_class
    
    def _create_column(self, prop: ODataProperty) -> Dict[str, Any]:
        """Create a column definition from an OData property."""
        # Map OData type to pandas dtype
        dtype = EDM_TYPE_MAPPING.get(prop.type, "object")
        
        # Get checks from annotations
        checks = []
        if prop.annotations:
            checks = self.term_converter.annotations_to_checks(prop.annotations)
        
        return {
            "dtype": dtype,
            "nullable": prop.nullable,
            "checks": checks,
            "max_length": prop.max_length,
            "is_key": prop.is_key,
        }


def generate_table_from_vocabulary(
    columns: Dict[str, str],
    annotations: Dict[str, List[str]],
    vocabularies: Optional[List[ODataVocabulary]] = None,
    table_name: str = "GeneratedTable",
    primary_keys: Optional[List[str]] = None,
    foreign_keys: Optional[Dict[str, Tuple[str, str]]] = None,
) -> Type:
    """
    Generate a Table class from column definitions and vocabulary annotations.
    
    This is a convenience function for creating Table classes without
    parsing full OData metadata.
    
    Args:
        columns: Dict mapping column names to OData type strings
        annotations: Dict mapping column names to lists of vocabulary terms
        vocabularies: Optional list of loaded OData vocabularies
        table_name: Name for the generated class
        primary_keys: Optional list of primary key column names
        foreign_keys: Optional dict mapping column to (target_table, target_column)
        
    Returns:
        Generated Table class
        
    Example:
        table = generate_table_from_vocabulary(
            columns={
                "CustomerID": "Edm.String",
                "PostalCode": "Edm.String",
                "FiscalYear": "Edm.String",
            },
            annotations={
                "CustomerID": ["IsUpperCase"],
                "PostalCode": ["IsDigitSequence"],
                "FiscalYear": ["IsFiscalYear"],
            },
            table_name="CustomerTable",
            primary_keys=["CustomerID"],
        )
    """
    # Initialize converter
    converter = ODataTermConverter()
    if vocabularies:
        registry = ValidationTermRegistry()
        for vocab in vocabularies:
            registry.register_vocabulary(vocab)
        converter = ODataTermConverter(registry)
    
    # Build column definitions
    schema_columns = {}
    for col_name, col_type in columns.items():
        dtype = EDM_TYPE_MAPPING.get(col_type, "object")
        checks = []
        
        if col_name in annotations:
            checks = converter.annotations_to_checks(annotations[col_name])
        
        schema_columns[col_name] = {
            "dtype": dtype,
            "checks": checks,
        }
    
    # Create schema dict for class
    schema_dict = {"__annotations__": {}}
    for col_name, col_def in schema_columns.items():
        schema_dict["__annotations__"][col_name] = Series[col_def["dtype"]]
    
    # Create the class
    table_class = type(
        table_name,
        (pa.DataFrameModel,),
        schema_dict,
    )
    
    # Add metadata
    table_class._primary_keys = primary_keys or []
    table_class._foreign_keys = foreign_keys or {}
    table_class._column_checks = {
        name: col.get("checks", []) for name, col in schema_columns.items()
    }
    
    # Add methods
    @classmethod
    def pk_method(cls) -> List[str]:
        return cls._primary_keys
    
    @classmethod
    def fk_method(cls) -> Dict[str, Tuple[str, str]]:
        return cls._foreign_keys
    
    table_class.primary_keys = pk_method
    table_class.foreign_keys = fk_method
    
    return table_class