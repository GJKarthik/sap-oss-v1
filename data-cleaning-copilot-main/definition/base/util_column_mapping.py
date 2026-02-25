"""Utility functions for column name mapping and normalization."""

from typing import Dict, Set, Mapping


def normalize_column_name(name: str) -> str:
    """
    Normalize column name: remove underscores, convert to lowercase.

    This matches the normalization logic used in Table.load_from_csv().

    Parameters
    ----------
    name : str
        The column name to normalize

    Returns
    -------
    str
        Normalized column name

    Examples
    --------
    >>> normalize_column_name("CUSTOMER_ID")
    'customerid'
    >>> normalize_column_name("ship_to_party")
    'shiptoparty'
    >>> normalize_column_name("SALESDOCUMENT")
    'salesdocument'
    """
    return name.replace("_", "").lower()


def create_column_mapping(csv_columns: Set[str], table_attrs: Set[str]) -> Dict[str, str]:
    """
    Create a mapping from CSV column names to table attribute names.

    Parameters
    ----------
    csv_columns : Set[str]
        Set of column names from the CSV file
    table_attrs : Set[str]
        Set of attribute names from the table class

    Returns
    -------
    Dict[str, str]
        Mapping from csv_column -> table_attr
    """
    # Create normalized lookup: normalized_name -> original_attr_name
    attr_lookup = {normalize_column_name(attr): attr for attr in table_attrs}

    # Build column mapping: csv_column -> table_attr
    column_mapping = {}

    for csv_col in csv_columns:
        normalized_csv = normalize_column_name(csv_col)
        if normalized_csv in attr_lookup:
            table_attr = attr_lookup[normalized_csv]
            column_mapping[csv_col] = table_attr

    return column_mapping


def find_matching_table_column(csv_column: str, table_attrs: Set[str]) -> str | None:
    """
    Find the matching table attribute for a given CSV column name.

    Parameters
    ----------
    csv_column : str
        CSV column name to match
    table_attrs : Set[str]
        Set of table attribute names

    Returns
    -------
    str | None
        Matching table attribute name, or None if no match found

    Examples
    --------
    >>> table_attrs = {"customer", "address_id", "sales_document"}
    >>> find_matching_table_column("CUSTOMER", table_attrs)
    'customer'
    >>> find_matching_table_column("ADDRESSID", table_attrs)
    'address_id'
    >>> find_matching_table_column("UNKNOWN_COLUMN", table_attrs)
    None
    """
    normalized_csv = normalize_column_name(csv_column)

    for attr in table_attrs:
        if normalize_column_name(attr) == normalized_csv:
            return attr

    return None


def normalize_column_mapping(data_mapping: Mapping[str, str], table_attrs: Set[str]) -> Dict[str, str]:
    """
    Normalize a column mapping to use table attribute names instead of CSV column names.

    This is useful for converting corruptor parameters that might use CSV column names
    to the correct table attribute names.

    Parameters
    ----------
    data_mapping : Mapping[str, str]
        Original mapping that might use CSV column names
    table_attrs : Set[str]
        Set of table attribute names

    Returns
    -------
    Dict[str, str]
        Normalized mapping using table attribute names
    """
    normalized_mapping = {}

    for key, value in data_mapping.items():
        # Try to find matching table attributes
        normalized_key = find_matching_table_column(key, table_attrs) or key
        normalized_value = find_matching_table_column(value, table_attrs) or value

        normalized_mapping[normalized_key] = normalized_value

    return normalized_mapping
