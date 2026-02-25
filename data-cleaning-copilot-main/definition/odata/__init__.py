"""
OData Vocabularies Integration for Data Cleaning Copilot

This module provides integration between SAP OData vocabularies and
the data-cleaning-copilot validation framework. It enables:

1. Parsing OData vocabulary definitions (XML/JSON)
2. Converting OData validation terms to pandera checks
3. Generating Table classes from OData $metadata

Example Usage:
    from definition.odata import (
        ODataVocabularyParser,
        ODataTermConverter,
        generate_table_from_vocabulary
    )
    
    # Parse SAP Common vocabulary
    parser = ODataVocabularyParser()
    vocab = parser.parse_file("vocabularies/Common.xml")
    
    # Convert terms to pandera checks
    converter = ODataTermConverter()
    checks = converter.get_checks_for_term("IsDigitSequence")
    
    # Generate a Table class with vocabulary-derived constraints
    CustomerTable = generate_table_from_vocabulary(
        columns={"CustomerID": "string", "PostalCode": "string"},
        annotations={
            "CustomerID": ["com.sap.vocabularies.Common.v1.IsUpperCase"],
            "PostalCode": ["com.sap.vocabularies.Common.v1.IsDigitSequence"]
        },
        vocabularies=[vocab]
    )
"""

from definition.odata.vocabulary_parser import (
    ODataVocabularyParser,
    ODataTerm,
    ODataVocabulary,
    ValidationTermRegistry,
    TermCategory,
)
from definition.odata.term_converter import (
    ODataTermConverter,
    PanderaCheckFactory,
    create_checks_from_odata_annotations,
)
from definition.odata.table_generator import (
    ODataTableGenerator,
    ODataMetadataParser,
    ODataMetadata,
    ODataEntityType,
    ODataProperty,
    generate_table_from_vocabulary,
    EDM_TYPE_MAPPING,
)
from definition.odata.database_integration import (
    derive_odata_checks,
    add_odata_checks_to_database,
    ODataDatabaseExtension,
    create_odata_check_logic,
    TERM_REGEX_PATTERNS,
    TERM_TO_CHECK_LOGIC_FACTORY,
)

__all__ = [
    # Vocabulary Parser
    "ODataVocabularyParser",
    "ODataTerm",
    "ODataVocabulary",
    "ValidationTermRegistry",
    "TermCategory",
    # Term Converter
    "ODataTermConverter",
    "PanderaCheckFactory",
    "create_checks_from_odata_annotations",
    # Table Generator
    "ODataTableGenerator",
    "ODataMetadataParser",
    "ODataMetadata",
    "ODataEntityType",
    "ODataProperty",
    "generate_table_from_vocabulary",
    "EDM_TYPE_MAPPING",
    # Database Integration
    "derive_odata_checks",
    "add_odata_checks_to_database",
    "ODataDatabaseExtension",
    "create_odata_check_logic",
    "TERM_REGEX_PATTERNS",
    "TERM_TO_CHECK_LOGIC_FACTORY",
]
