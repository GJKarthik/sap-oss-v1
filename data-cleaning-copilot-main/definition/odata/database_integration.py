"""
OData Database Integration

Integrates OData vocabulary-derived validation checks with the
data-cleaning-copilot Database class.

This module provides:
- Extension of Database.derive_rule_based_checks() to include OData checks
- Helper functions to add OData-based validation to existing databases
- Automatic check generation from OData vocabulary annotations

Example:
    from definition.base.database import Database
    from definition.odata.database_integration import (
        derive_odata_checks,
        add_odata_checks_to_database,
        ODataDatabaseExtension,
    )
    
    # Create database
    db = Database("my_database")
    
    # Add OData-derived checks
    add_odata_checks_to_database(
        database=db,
        vocabulary_path="odata-vocabularies-main/vocabularies/Common.xml",
        annotations={
            "Customer": {
                "CustomerID": ["IsUpperCase"],
                "PostalCode": ["IsDigitSequence"],
            }
        }
    )
    
    # Validate with OData checks included
    db.validate()
"""

from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple, Type, Union

import pandas as pd
from loguru import logger

from definition.base.executable_code import CheckLogic
from definition.odata.vocabulary_parser import (
    ODataVocabularyParser,
    ODataVocabulary,
    ValidationTermRegistry,
    ODataTerm,
    TermCategory,
)
from definition.odata.term_converter import (
    ODataTermConverter,
    PanderaCheckFactory,
)


def create_odata_check_logic(
    table_name: str,
    column_name: str,
    term_name: str,
    regex_pattern: Optional[str] = None,
    check_function: Optional[str] = None,
) -> CheckLogic:
    """
    Create a CheckLogic object for an OData vocabulary term.
    
    Args:
        table_name: Name of the table to validate
        column_name: Name of the column to validate
        term_name: OData vocabulary term name (e.g., "IsDigitSequence")
        regex_pattern: Optional regex pattern for the check
        check_function: Optional custom check function body
        
    Returns:
        CheckLogic object that can be executed by the validation system
    """
    function_name = f"OData_{table_name}_{column_name}_{term_name}"
    
    # Build the validation function body
    if regex_pattern:
        # Regex-based check
        body_lines = [
            f"    violations = {{}}",
            f"    table_df = tables.get('{table_name}', pd.DataFrame())",
            f"    if table_df.empty:",
            f"        return violations",
            f"    if '{column_name}' not in table_df.columns:",
            f"        return violations",
            f"    col = table_df['{column_name}']",
            f"    # Skip null values - only check non-null values",
            f"    mask = col.notna() & (col.astype(str) != '')",
            f"    if not mask.any():",
            f"        return violations",
            f"    import re",
            f"    pattern = re.compile(r'^{regex_pattern}$')",
            f"    invalid_mask = mask & ~col.astype(str).str.match(pattern, na=False)",
            f"    if invalid_mask.any():",
            f"        invalid_indices = table_df.index[invalid_mask].tolist()",
            f"        violations['{table_name}'] = pd.Series(invalid_indices, name='{column_name}')",
            f"    return violations",
        ]
    elif check_function:
        # Custom check function provided
        body_lines = check_function.split("\n")
    else:
        # Default: empty check (placeholder)
        body_lines = [
            f"    # OData term: {term_name}",
            f"    # No validation logic defined",
            f"    return {{}}",
        ]
    
    return CheckLogic(
        function_name=function_name,
        body_lines=body_lines,
        scope=[(table_name, column_name)],
    )


def create_uppercase_check_logic(table_name: str, column_name: str) -> CheckLogic:
    """Create a CheckLogic for IsUpperCase validation."""
    function_name = f"OData_{table_name}_{column_name}_IsUpperCase"
    
    body_lines = [
        f"    violations = {{}}",
        f"    table_df = tables.get('{table_name}', pd.DataFrame())",
        f"    if table_df.empty:",
        f"        return violations",
        f"    if '{column_name}' not in table_df.columns:",
        f"        return violations",
        f"    col = table_df['{column_name}']",
        f"    # Skip null values and empty strings",
        f"    mask = col.notna() & (col.astype(str).str.strip() != '')",
        f"    if not mask.any():",
        f"        return violations",
        f"    # Check if all characters are uppercase",
        f"    str_col = col[mask].astype(str)",
        f"    # Only check alphabetic characters",
        f"    invalid_mask = mask.copy()",
        f"    invalid_mask[mask] = ~str_col.str.upper().eq(str_col)",
        f"    if invalid_mask.any():",
        f"        invalid_indices = table_df.index[invalid_mask].tolist()",
        f"        violations['{table_name}'] = pd.Series(invalid_indices, name='{column_name}')",
        f"    return violations",
    ]
    
    return CheckLogic(
        function_name=function_name,
        body_lines=body_lines,
        scope=[(table_name, column_name)],
    )


def create_currency_check_logic(table_name: str, column_name: str) -> CheckLogic:
    """Create a CheckLogic for IsCurrency validation (ISO 4217 currency codes)."""
    function_name = f"OData_{table_name}_{column_name}_IsCurrency"
    
    body_lines = [
        f"    violations = {{}}",
        f"    table_df = tables.get('{table_name}', pd.DataFrame())",
        f"    if table_df.empty:",
        f"        return violations",
        f"    if '{column_name}' not in table_df.columns:",
        f"        return violations",
        f"    col = table_df['{column_name}']",
        f"    # Skip null values",
        f"    mask = col.notna() & (col.astype(str).str.strip() != '')",
        f"    if not mask.any():",
        f"        return violations",
        f"    import re",
        f"    # ISO 4217 currency code: exactly 3 uppercase letters",
        f"    pattern = re.compile(r'^[A-Z]{{3}}$')",
        f"    invalid_mask = mask & ~col.astype(str).str.match(pattern, na=False)",
        f"    if invalid_mask.any():",
        f"        invalid_indices = table_df.index[invalid_mask].tolist()",
        f"        violations['{table_name}'] = pd.Series(invalid_indices, name='{column_name}')",
        f"    return violations",
    ]
    
    return CheckLogic(
        function_name=function_name,
        body_lines=body_lines,
        scope=[(table_name, column_name)],
    )


def create_language_identifier_check_logic(table_name: str, column_name: str) -> CheckLogic:
    """Create a CheckLogic for IsLanguageIdentifier validation (BCP 47)."""
    function_name = f"OData_{table_name}_{column_name}_IsLanguageIdentifier"
    
    body_lines = [
        f"    violations = {{}}",
        f"    table_df = tables.get('{table_name}', pd.DataFrame())",
        f"    if table_df.empty:",
        f"        return violations",
        f"    if '{column_name}' not in table_df.columns:",
        f"        return violations",
        f"    col = table_df['{column_name}']",
        f"    # Skip null values",
        f"    mask = col.notna() & (col.astype(str).str.strip() != '')",
        f"    if not mask.any():",
        f"        return violations",
        f"    import re",
        f"    # BCP 47 language tag pattern (simplified)",
        f"    pattern = re.compile(r'^[a-z]{{2,3}}(-[A-Z]{{2}})?(-[A-Za-z]{{4}})?$')",
        f"    invalid_mask = mask & ~col.astype(str).str.match(pattern, na=False)",
        f"    if invalid_mask.any():",
        f"        invalid_indices = table_df.index[invalid_mask].tolist()",
        f"        violations['{table_name}'] = pd.Series(invalid_indices, name='{column_name}')",
        f"    return violations",
    ]
    
    return CheckLogic(
        function_name=function_name,
        body_lines=body_lines,
        scope=[(table_name, column_name)],
    )


# Mapping of OData terms to CheckLogic factory functions
TERM_TO_CHECK_LOGIC_FACTORY: Dict[str, callable] = {
    "IsUpperCase": create_uppercase_check_logic,
    "IsCurrency": create_currency_check_logic,
    "IsLanguageIdentifier": create_language_identifier_check_logic,
}

# Known regex patterns for terms
TERM_REGEX_PATTERNS: Dict[str, str] = {
    "IsDigitSequence": r"\d+",
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
    "IsUnit": r"[A-Za-z0-9]{1,3}",
    "IsTimezone": r"([A-Za-z_]+/[A-Za-z_]+|UTC([+-]\d{1,2}(:\d{2})?)?)",
}


def derive_odata_checks(
    table_annotations: Dict[str, Dict[str, List[str]]],
    vocabulary_registry: Optional[ValidationTermRegistry] = None,
) -> Dict[str, CheckLogic]:
    """
    Derive CheckLogic objects from OData vocabulary annotations.
    
    Args:
        table_annotations: Dict mapping table names to column annotations.
            Format: {"TableName": {"ColumnName": ["Term1", "Term2", ...], ...}, ...}
        vocabulary_registry: Optional registry for looking up term definitions
        
    Returns:
        Dict mapping check names to CheckLogic objects
    """
    checks: Dict[str, CheckLogic] = {}
    
    for table_name, column_annotations in table_annotations.items():
        for column_name, terms in column_annotations.items():
            for term in terms:
                # Extract short name from qualified name
                short_name = term.split(".")[-1] if "." in term else term
                
                # Check if we have a custom factory for this term
                if short_name in TERM_TO_CHECK_LOGIC_FACTORY:
                    factory = TERM_TO_CHECK_LOGIC_FACTORY[short_name]
                    check = factory(table_name, column_name)
                    checks[check.function_name] = check
                    logger.debug(f"Created OData check: {check.function_name}")
                
                # Check if we have a regex pattern for this term
                elif short_name in TERM_REGEX_PATTERNS:
                    regex = TERM_REGEX_PATTERNS[short_name]
                    check = create_odata_check_logic(
                        table_name=table_name,
                        column_name=column_name,
                        term_name=short_name,
                        regex_pattern=regex,
                    )
                    checks[check.function_name] = check
                    logger.debug(f"Created OData regex check: {check.function_name}")
                
                # Try to get pattern from registry
                elif vocabulary_registry:
                    registry_term = vocabulary_registry.get_term(term)
                    if registry_term and registry_term.regex_pattern:
                        check = create_odata_check_logic(
                            table_name=table_name,
                            column_name=column_name,
                            term_name=short_name,
                            regex_pattern=registry_term.regex_pattern,
                        )
                        checks[check.function_name] = check
                        logger.debug(f"Created OData check from registry: {check.function_name}")
                    else:
                        logger.warning(f"No validation logic for OData term: {term}")
                else:
                    logger.warning(f"Unknown OData term: {term}")
    
    return checks


def add_odata_checks_to_database(
    database: "Database",
    annotations: Dict[str, Dict[str, List[str]]],
    vocabulary_path: Optional[Union[str, Path]] = None,
) -> int:
    """
    Add OData vocabulary-derived checks to an existing Database.
    
    This function:
    1. Optionally loads vocabulary definitions from a file
    2. Converts vocabulary terms to CheckLogic objects
    3. Adds the checks to the database's rule_based_checks
    
    Args:
        database: The Database instance to add checks to
        annotations: Dict mapping table names to column annotations.
            Format: {"TableName": {"ColumnName": ["Term1", "Term2"], ...}, ...}
        vocabulary_path: Optional path to OData vocabulary XML file
        
    Returns:
        Number of checks added
        
    Example:
        add_odata_checks_to_database(
            database=db,
            annotations={
                "Customer": {
                    "CustomerID": ["IsUpperCase", "IsDigitSequence"],
                    "PostalCode": ["IsDigitSequence"],
                    "Currency": ["IsCurrency"],
                },
                "Order": {
                    "FiscalYear": ["IsFiscalYear"],
                    "FiscalPeriod": ["IsFiscalPeriod"],
                },
            },
            vocabulary_path="odata-vocabularies-main/vocabularies/Common.xml"
        )
    """
    # Optionally load vocabulary for extended term lookup
    registry = None
    if vocabulary_path:
        try:
            parser = ODataVocabularyParser()
            vocabulary = parser.parse_file(vocabulary_path)
            registry = ValidationTermRegistry()
            registry.register_vocabulary(vocabulary)
            logger.info(f"Loaded vocabulary from {vocabulary_path}")
        except Exception as e:
            logger.warning(f"Failed to load vocabulary from {vocabulary_path}: {e}")
    
    # Derive checks from annotations
    odata_checks = derive_odata_checks(annotations, registry)
    
    # Add checks to database's rule_based_checks
    for check_name, check in odata_checks.items():
        database.rule_based_checks[check_name] = check
    
    logger.info(f"Added {len(odata_checks)} OData-derived checks to database")
    return len(odata_checks)


class ODataDatabaseExtension:
    """
    Extension class that adds OData vocabulary support to a Database.
    
    This class wraps a Database instance and provides additional methods
    for working with OData vocabularies.
    
    Example:
        db = Database("my_database")
        odata_db = ODataDatabaseExtension(db)
        
        # Load vocabulary
        odata_db.load_vocabulary("odata-vocabularies-main/vocabularies/Common.xml")
        
        # Add annotations
        odata_db.set_column_annotations("Customer", "CustomerID", ["IsUpperCase"])
        odata_db.set_column_annotations("Customer", "PostalCode", ["IsDigitSequence"])
        
        # Derive checks
        odata_db.derive_odata_checks()
        
        # Validate
        db.validate()
    """
    
    def __init__(self, database: "Database"):
        """
        Initialize the extension.
        
        Args:
            database: The Database instance to extend
        """
        self.database = database
        self.vocabulary_registry = ValidationTermRegistry()
        self.column_annotations: Dict[str, Dict[str, List[str]]] = {}
        self._vocabularies_loaded: List[str] = []
    
    def load_vocabulary(self, vocabulary_path: Union[str, Path]) -> int:
        """
        Load an OData vocabulary file.
        
        Args:
            vocabulary_path: Path to the vocabulary XML file
            
        Returns:
            Number of validation terms loaded
        """
        parser = ODataVocabularyParser()
        vocabulary = parser.parse_file(vocabulary_path)
        count = self.vocabulary_registry.register_vocabulary(vocabulary)
        self._vocabularies_loaded.append(str(vocabulary_path))
        logger.info(f"Loaded {count} validation terms from {vocabulary_path}")
        return count
    
    def set_column_annotations(
        self, table_name: str, column_name: str, terms: List[str]
    ) -> None:
        """
        Set OData vocabulary annotations for a column.
        
        Args:
            table_name: Name of the table
            column_name: Name of the column
            terms: List of OData vocabulary term names
        """
        if table_name not in self.column_annotations:
            self.column_annotations[table_name] = {}
        
        self.column_annotations[table_name][column_name] = terms
        logger.debug(f"Set annotations for {table_name}.{column_name}: {terms}")
    
    def set_table_annotations(
        self, table_name: str, column_annotations: Dict[str, List[str]]
    ) -> None:
        """
        Set OData vocabulary annotations for all columns in a table.
        
        Args:
            table_name: Name of the table
            column_annotations: Dict mapping column names to term lists
        """
        self.column_annotations[table_name] = column_annotations
        logger.debug(f"Set annotations for table {table_name}: {len(column_annotations)} columns")
    
    def get_annotations(self) -> Dict[str, Dict[str, List[str]]]:
        """Get all column annotations."""
        return self.column_annotations.copy()
    
    def derive_odata_checks(self) -> int:
        """
        Derive and add OData checks to the database.
        
        Returns:
            Number of checks added
        """
        checks = derive_odata_checks(
            self.column_annotations,
            self.vocabulary_registry if self._vocabularies_loaded else None,
        )
        
        # Add to database's rule_based_checks
        for check_name, check in checks.items():
            self.database.rule_based_checks[check_name] = check
        
        logger.info(f"Derived {len(checks)} OData checks")
        return len(checks)
    
    def get_available_terms(self) -> List[str]:
        """Get list of all available validation terms."""
        # Built-in terms
        terms = list(TERM_REGEX_PATTERNS.keys()) + list(TERM_TO_CHECK_LOGIC_FACTORY.keys())
        
        # Terms from loaded vocabularies
        if self.vocabulary_registry:
            for term in self.vocabulary_registry.get_all_terms():
                if term.name not in terms:
                    terms.append(term.name)
        
        return sorted(set(terms))
    
    def summary(self) -> Dict[str, Any]:
        """Get a summary of the OData extension state."""
        return {
            "vocabularies_loaded": self._vocabularies_loaded,
            "tables_with_annotations": list(self.column_annotations.keys()),
            "total_annotated_columns": sum(
                len(cols) for cols in self.column_annotations.values()
            ),
            "available_terms": len(self.get_available_terms()),
            "odata_checks_in_database": len([
                name for name in self.database.rule_based_checks.keys()
                if name.startswith("OData_")
            ]),
        }