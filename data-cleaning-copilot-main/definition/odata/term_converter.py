"""
OData Term to Pandera Check Converter

Converts OData vocabulary terms to pandera Check objects that can be used
in data-cleaning-copilot's validation framework.

This module provides:
- Mapping from OData terms to pandera Check factories
- Support for regex-based validation terms
- Field control conversion (Mandatory → nullable=False)
- Cardinality constraint handling

Example:
    from definition.odata.term_converter import ODataTermConverter
    
    converter = ODataTermConverter()
    
    # Get pandera check for IsDigitSequence
    check = converter.term_to_check("IsDigitSequence")
    # Returns: pa.Check.str_matches(r'^\d+$', name="IsDigitSequence")
    
    # Get multiple checks for a column with annotations
    checks = converter.annotations_to_checks([
        "com.sap.vocabularies.Common.v1.IsUpperCase",
        "com.sap.vocabularies.Common.v1.IsDigitSequence"
    ])
"""

import re
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Union

import pandera as pa
from pandera import Check
from loguru import logger

from definition.odata.vocabulary_parser import (
    ODataTerm,
    ODataVocabulary,
    TermCategory,
    ValidationTermRegistry,
)


@dataclass
class CheckDefinition:
    """Definition of how to create a pandera Check from an OData term."""
    
    name: str
    check_factory: Callable[..., Check]
    description: str
    applies_to_types: List[str]  # e.g., ["string", "object"]
    requires_regex: bool = False
    is_nullable_check: bool = False


class PanderaCheckFactory:
    """
    Factory for creating pandera Check objects from OData term specifications.
    
    Provides static methods for common check patterns used in OData vocabularies.
    """
    
    @staticmethod
    def regex_check(pattern: str, name: str, description: str = "") -> Check:
        """
        Create a regex matching check.
        
        Args:
            pattern: Regex pattern to match
            name: Check name
            description: Optional description
            
        Returns:
            pandera Check object
        """
        # Ensure pattern is anchored for full string match
        if not pattern.startswith("^"):
            pattern = f"^{pattern}"
        if not pattern.endswith("$"):
            pattern = f"{pattern}$"
        
        return pa.Check.str_matches(
            pattern,
            name=name,
            description=description or f"Value must match pattern: {pattern}",
            raise_warning=False,
        )
    
    @staticmethod
    def uppercase_check(name: str = "IsUpperCase") -> Check:
        """
        Create a check that validates all characters are uppercase.
        
        Returns:
            pandera Check for uppercase validation
        """
        def check_uppercase(series):
            # Handle NaN values and empty strings
            mask = series.notna() & (series != "")
            if not mask.any():
                return True
            return series[mask].str.isupper().all()
        
        return pa.Check(
            check_uppercase,
            name=name,
            description="Value must contain only uppercase characters",
            element_wise=False,
        )
    
    @staticmethod
    def digit_sequence_check(name: str = "IsDigitSequence") -> Check:
        """
        Create a check that validates the value contains only digits.
        
        Returns:
            pandera Check for digit sequence validation
        """
        return pa.Check.str_matches(
            r"^\d+$",
            name=name,
            description="Value must contain only digits",
        )
    
    @staticmethod
    def currency_code_check(name: str = "IsCurrency") -> Check:
        """
        Create a check for ISO 4217 currency code format.
        
        Returns:
            pandera Check for currency code validation
        """
        # ISO 4217 currency codes are 3 uppercase letters
        return pa.Check.str_matches(
            r"^[A-Z]{3}$",
            name=name,
            description="Value must be a valid ISO 4217 currency code (3 uppercase letters)",
        )
    
    @staticmethod
    def unit_check(name: str = "IsUnit") -> Check:
        """
        Create a check for unit of measure format.
        
        Returns:
            pandera Check for unit validation
        """
        # Units are typically alphanumeric, up to 3 characters
        return pa.Check.str_matches(
            r"^[A-Za-z0-9]{1,3}$",
            name=name,
            description="Value must be a valid unit of measure code",
        )
    
    @staticmethod
    def language_identifier_check(name: str = "IsLanguageIdentifier") -> Check:
        """
        Create a check for language identifier format (BCP 47).
        
        Returns:
            pandera Check for language identifier validation
        """
        # BCP 47 language tags: 2-3 letter primary subtag, optional region/script
        return pa.Check.str_matches(
            r"^[a-z]{2,3}(-[A-Z]{2})?(-[A-Za-z]{4})?$",
            name=name,
            description="Value must be a valid BCP 47 language identifier",
        )
    
    @staticmethod
    def timezone_check(name: str = "IsTimezone") -> Check:
        """
        Create a check for IANA timezone format.
        
        Returns:
            pandera Check for timezone validation
        """
        # IANA timezone format: Region/City or UTC offsets
        return pa.Check.str_matches(
            r"^([A-Za-z_]+/[A-Za-z_]+|UTC([+-]\d{1,2}(:\d{2})?)?)$",
            name=name,
            description="Value must be a valid IANA timezone identifier",
        )
    
    @staticmethod
    def min_occurs_check(min_value: int, name: str = "MinOccurs") -> Check:
        """
        Create a check for minimum collection length.
        
        Args:
            min_value: Minimum number of items
            
        Returns:
            pandera Check for minimum cardinality
        """
        def check_min(series):
            # For collection columns (stored as lists or arrays)
            return series.apply(lambda x: len(x) >= min_value if hasattr(x, "__len__") else True)
        
        return pa.Check(
            check_min,
            name=f"{name}_{min_value}",
            description=f"Collection must contain at least {min_value} items",
            element_wise=False,
        )
    
    @staticmethod
    def max_occurs_check(max_value: int, name: str = "MaxOccurs") -> Check:
        """
        Create a check for maximum collection length.
        
        Args:
            max_value: Maximum number of items
            
        Returns:
            pandera Check for maximum cardinality
        """
        def check_max(series):
            return series.apply(lambda x: len(x) <= max_value if hasattr(x, "__len__") else True)
        
        return pa.Check(
            check_max,
            name=f"{name}_{max_value}",
            description=f"Collection must contain at most {max_value} items",
            element_wise=False,
        )
    
    @staticmethod
    def day_of_month_check(name: str = "IsDayOfCalendarMonth") -> Check:
        """
        Create a check for day of month (1-31).
        
        Returns:
            pandera Check for day of month validation
        """
        def check_day(series):
            numeric = pa.to_numeric(series, errors="coerce")
            return (numeric >= 1) & (numeric <= 31)
        
        return pa.Check(
            check_day,
            name=name,
            description="Value must be a valid day of month (1-31)",
            element_wise=False,
        )
    
    @staticmethod
    def day_of_year_check(name: str = "IsDayOfCalendarYear") -> Check:
        """
        Create a check for day of year (1-366).
        
        Returns:
            pandera Check for day of year validation
        """
        def check_day(series):
            numeric = pa.to_numeric(series, errors="coerce")
            return (numeric >= 1) & (numeric <= 366)
        
        return pa.Check(
            check_day,
            name=name,
            description="Value must be a valid day of year (1-366)",
            element_wise=False,
        )
    
    @staticmethod
    def day_of_fiscal_year_check(name: str = "IsDayOfFiscalYear") -> Check:
        """
        Create a check for day of fiscal year (1-371).
        
        Returns:
            pandera Check for day of fiscal year validation
        """
        def check_day(series):
            numeric = pa.to_numeric(series, errors="coerce")
            return (numeric >= 1) & (numeric <= 371)
        
        return pa.Check(
            check_day,
            name=name,
            description="Value must be a valid day of fiscal year (1-371)",
            element_wise=False,
        )


class ODataTermConverter:
    """
    Converts OData vocabulary terms to pandera Check objects.
    
    Maintains a mapping of term names to check factories and provides
    methods to convert individual terms or lists of annotations.
    """
    
    def __init__(self, registry: Optional[ValidationTermRegistry] = None):
        """
        Initialize the converter.
        
        Args:
            registry: Optional ValidationTermRegistry for term lookup
        """
        self.registry = registry
        self._check_mappings: Dict[str, Callable[[], Check]] = self._build_check_mappings()
    
    def _build_check_mappings(self) -> Dict[str, Callable[[], Check]]:
        """Build the mapping from term names to check factories."""
        factory = PanderaCheckFactory
        
        return {
            # String format terms
            "IsDigitSequence": factory.digit_sequence_check,
            "IsUpperCase": factory.uppercase_check,
            
            # Semantic type terms
            "IsCurrency": factory.currency_code_check,
            "IsUnit": factory.unit_check,
            "IsLanguageIdentifier": factory.language_identifier_check,
            "IsTimezone": factory.timezone_check,
            
            # Day-based terms (numeric range checks)
            "IsDayOfCalendarMonth": factory.day_of_month_check,
            "IsDayOfCalendarYear": factory.day_of_year_check,
            "IsDayOfFiscalYear": factory.day_of_fiscal_year_check,
            
            # Calendar date terms (regex-based)
            "IsCalendarYear": lambda: factory.regex_check(
                r"-?([1-9][0-9]{3,}|0[0-9]{3})",
                "IsCalendarYear",
                "Year number: optional minus, at least 4 digits"
            ),
            "IsCalendarHalfyear": lambda: factory.regex_check(
                r"[1-2]",
                "IsCalendarHalfyear",
                "Halfyear: 1 or 2"
            ),
            "IsCalendarQuarter": lambda: factory.regex_check(
                r"[1-4]",
                "IsCalendarQuarter",
                "Quarter: 1, 2, 3, or 4"
            ),
            "IsCalendarMonth": lambda: factory.regex_check(
                r"0[1-9]|1[0-2]",
                "IsCalendarMonth",
                "Month: 01-12"
            ),
            "IsCalendarWeek": lambda: factory.regex_check(
                r"0[1-9]|[1-4][0-9]|5[0-3]",
                "IsCalendarWeek",
                "Week: 01-53"
            ),
            "IsCalendarYearHalfyear": lambda: factory.regex_check(
                r"-?([1-9][0-9]{3,}|0[0-9]{3})[1-2]",
                "IsCalendarYearHalfyear",
                "Year + halfyear: YYYY(Y*)H"
            ),
            "IsCalendarYearQuarter": lambda: factory.regex_check(
                r"-?([1-9][0-9]{3,}|0[0-9]{3})[1-4]",
                "IsCalendarYearQuarter",
                "Year + quarter: YYYY(Y*)Q"
            ),
            "IsCalendarYearMonth": lambda: factory.regex_check(
                r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|1[0-2])",
                "IsCalendarYearMonth",
                "Year + month: YYYY(Y*)MM"
            ),
            "IsCalendarYearWeek": lambda: factory.regex_check(
                r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|[1-4][0-9]|5[0-3])",
                "IsCalendarYearWeek",
                "Year + week: YYYY(Y*)WW"
            ),
            "IsCalendarDate": lambda: factory.regex_check(
                r"-?([1-9][0-9]{3,}|0[0-9]{3})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])",
                "IsCalendarDate",
                "Calendar date: YYYY(Y*)MMDD"
            ),
            
            # Fiscal date terms (regex-based)
            "IsFiscalYear": lambda: factory.regex_check(
                r"[1-9][0-9]{3}",
                "IsFiscalYear",
                "Fiscal year: 4 digits"
            ),
            "IsFiscalPeriod": lambda: factory.regex_check(
                r"[0-9]{3}",
                "IsFiscalPeriod",
                "Fiscal period: 3 digits"
            ),
            "IsFiscalYearPeriod": lambda: factory.regex_check(
                r"([1-9][0-9]{3})([0-9]{3})",
                "IsFiscalYearPeriod",
                "Fiscal year + period: YYYYPPP"
            ),
            "IsFiscalQuarter": lambda: factory.regex_check(
                r"[1-4]",
                "IsFiscalQuarter",
                "Fiscal quarter: 1, 2, 3, or 4"
            ),
            "IsFiscalYearQuarter": lambda: factory.regex_check(
                r"[1-9][0-9]{3}[1-4]",
                "IsFiscalYearQuarter",
                "Fiscal year + quarter: YYYYQ"
            ),
            "IsFiscalWeek": lambda: factory.regex_check(
                r"0[1-9]|[1-4][0-9]|5[0-3]",
                "IsFiscalWeek",
                "Fiscal week: 01-53"
            ),
            "IsFiscalYearWeek": lambda: factory.regex_check(
                r"[1-9][0-9]{3}(0[1-9]|[1-4][0-9]|5[0-3])",
                "IsFiscalYearWeek",
                "Fiscal year + week: YYYYWW"
            ),
        }
    
    def term_to_check(self, term_name: str) -> Optional[Check]:
        """
        Convert an OData term to a pandera Check.
        
        Args:
            term_name: Name of the term (short or qualified)
            
        Returns:
            pandera Check object, or None if term not supported
        """
        # Extract short name from qualified name
        short_name = term_name.split(".")[-1] if "." in term_name else term_name
        
        # Look up in direct mappings
        if short_name in self._check_mappings:
            check_factory = self._check_mappings[short_name]
            logger.debug(f"Converting term '{short_name}' to pandera check")
            return check_factory()
        
        # Try to find term in registry and use regex if available
        if self.registry:
            term = self.registry.get_term(term_name)
            if term and term.regex_pattern:
                logger.debug(f"Creating regex check for term '{term_name}' from registry")
                return PanderaCheckFactory.regex_check(
                    term.regex_pattern,
                    term.name,
                    term.description,
                )
        
        logger.warning(f"No check mapping found for term: {term_name}")
        return None
    
    def annotations_to_checks(
        self, annotations: List[str], skip_unsupported: bool = True
    ) -> List[Check]:
        """
        Convert a list of OData annotations to pandera Checks.
        
        Args:
            annotations: List of annotation term names
            skip_unsupported: If True, skip terms without mappings
            
        Returns:
            List of pandera Check objects
        """
        checks = []
        for annotation in annotations:
            check = self.term_to_check(annotation)
            if check is not None:
                checks.append(check)
            elif not skip_unsupported:
                logger.warning(f"Unsupported annotation term: {annotation}")
        
        return checks
    
    def get_nullable_from_field_control(
        self, field_control_value: Union[str, int]
    ) -> bool:
        """
        Determine nullable setting from FieldControl annotation value.
        
        Args:
            field_control_value: FieldControl enum value or member name
            
        Returns:
            True if field is nullable, False if mandatory
        """
        # FieldControlType enum values
        # Mandatory = 7, Optional = 3, ReadOnly = 1, Inapplicable/Hidden = 0
        mandatory_values = {"Mandatory", "7", 7}
        
        if field_control_value in mandatory_values:
            return False
        return True
    
    def get_supported_terms(self) -> List[str]:
        """Get list of term names that have check mappings."""
        return list(self._check_mappings.keys())
    
    def has_check_for_term(self, term_name: str) -> bool:
        """Check if a term has a check mapping."""
        short_name = term_name.split(".")[-1] if "." in term_name else term_name
        return short_name in self._check_mappings


def create_checks_from_odata_annotations(
    annotations: Dict[str, Any],
    converter: Optional[ODataTermConverter] = None,
) -> Dict[str, List[Check]]:
    """
    Create pandera checks from OData property annotations.
    
    Args:
        annotations: Dict mapping property names to their OData annotations
                    Format: {"PropertyName": ["Term1", "Term2", ...]}
        converter: Optional ODataTermConverter instance
        
    Returns:
        Dict mapping property names to lists of pandera Checks
    """
    if converter is None:
        converter = ODataTermConverter()
    
    result = {}
    for prop_name, prop_annotations in annotations.items():
        if isinstance(prop_annotations, list):
            checks = converter.annotations_to_checks(prop_annotations)
            if checks:
                result[prop_name] = checks
    
    return result