"""Utility functions for profiling table data."""

import pandas as pd
import json
from typing import Dict, Any
from ydata_profiling import ProfileReport


def profile_table_data(df: pd.DataFrame, max_columns: int = 20, sample_size: int = 10) -> Dict[str, Any]:
    """
    Generate a succinct profile of a DataFrame.

    Parameters
    ----------
    df : pd.DataFrame
        The DataFrame to profile
    max_columns : int
        Maximum number of columns to include in the profile (default: 20)
    sample_size : int
        Number of sample records to include (default: 10)

    Returns
    -------
    Dict[str, Any]
        A dictionary containing:
        - table: Table-level statistics
        - variables: Column-level statistics (limited to max_columns)
        - sample_records: List of sample records
    """
    # Generate full profile
    profile = ProfileReport(df, minimal=True, progress_bar=False)

    # Convert to JSON and parse - this is the most reliable way to get the data
    profile_json = profile.to_json()
    profile_data = json.loads(profile_json)

    # Build reduced profile with essential info
    reduced_profile = {
        "table": profile_data.get("table", {}),
        "variables": {},
        "sample_records": df.head(sample_size).to_dict(orient="records"),
    }

    # Extract variable statistics with more details
    variables = profile_data.get("variables", {})
    for name, var in list(variables.items())[:max_columns]:
        var_stats = {
            "type": var.get("type"),
            "n_distinct": var.get("n_distinct"),
            "p_missing": var.get("p_missing", 0),
            "memory_size": var.get("memory_size", 0),
        }

        # Add numerical statistics if available
        if var.get("type") in ["Numeric", "Numerical", "Real"]:
            # These stats should be in the profile report for numerical columns
            if "min" in var:
                var_stats["min"] = var.get("min")
            if "max" in var:
                var_stats["max"] = var.get("max")
            if "mean" in var:
                var_stats["mean"] = var.get("mean")
            if "std" in var:
                var_stats["std"] = var.get("std")
            if "5%" in var:
                var_stats["percentile_5"] = var.get("5%")
            if "25%" in var:
                var_stats["percentile_25"] = var.get("25%")
            if "50%" in var:
                var_stats["median"] = var.get("50%")
            if "75%" in var:
                var_stats["percentile_75"] = var.get("75%")
            if "95%" in var:
                var_stats["percentile_95"] = var.get("95%")

        # Add categorical statistics if available
        if var.get("type") in ["Categorical", "Text", "Boolean"]:
            if "n_category" in var:
                var_stats["n_category"] = var.get("n_category")
            # Top categories might be useful
            if "value_counts_without_nan" in var:
                top_values = var.get("value_counts_without_nan", {})
                if top_values and isinstance(top_values, dict):
                    # Get top 5 most common values and convert keys to strings
                    # to ensure JSON serialization works with int64 and other types
                    var_stats["top_values"] = {str(k): v for k, v in list(top_values.items())[:5]}

        reduced_profile["variables"][name] = var_stats

    return reduced_profile


def profile_table_column_data(df: pd.DataFrame, column_name: str, sample_size: int = 10) -> Dict[str, Any]:
    """
    Generate a detailed profile of a single column in a DataFrame.

    Parameters
    ----------
    df : pd.DataFrame
        The DataFrame containing the column
    column_name : str
        Name of the column to profile
    sample_size : int
        Number of sample values to include (default: 10)

    Returns
    -------
    Dict[str, Any]
        A dictionary containing:
        - column_name: Name of the column
        - type: Data type of the column
        - statistics: Detailed statistics for the column
        - sample_values: List of sample values
        - value_counts: Top value counts (for categorical/low cardinality)
    """
    if column_name not in df.columns:
        raise ValueError(f"Column '{column_name}' not found in DataFrame")

    # Get the single column as a DataFrame
    column_df = df[[column_name]]

    # Generate profile for just this column
    profile = ProfileReport(column_df, minimal=True, progress_bar=False)
    profile_json = profile.to_json()
    profile_data = json.loads(profile_json)

    # Extract column-specific data
    variables = profile_data.get("variables", {})
    column_data = variables.get(column_name, {})

    # Build detailed column profile
    column_profile = {
        "column_name": column_name,
        "type": column_data.get("type"),
        "count": column_data.get("count", len(df)),
        "n_distinct": column_data.get("n_distinct"),
        "p_missing": column_data.get("p_missing", 0),
        "n_missing": column_data.get("n_missing", 0),
        "memory_size": column_data.get("memory_size", 0),
        "sample_values": df[column_name].dropna().head(sample_size).tolist(),
    }

    # Add numerical statistics if available
    if column_data.get("type") in ["Numeric", "Numerical", "Real"]:
        numerical_stats = {}
        for stat_key in ["min", "max", "mean", "std", "variance", "kurtosis", "skewness"]:
            if stat_key in column_data:
                numerical_stats[stat_key] = column_data.get(stat_key)

        # Add percentiles
        for percentile in ["5%", "25%", "50%", "75%", "95%"]:
            if percentile in column_data:
                numerical_stats[f"percentile_{percentile.replace('%', '')}"] = column_data.get(percentile)

        if numerical_stats:
            column_profile["numerical_stats"] = numerical_stats

    # Add categorical statistics if available
    if (
        column_data.get("type") in ["Categorical", "Text", "Boolean"]
        or column_data.get("n_distinct", float("inf")) <= 20
    ):
        # Get value counts and convert keys to JSON-serializable types
        value_counts_series = df[column_name].value_counts().head(20)
        # Convert keys to strings to ensure JSON serialization works with int64 and other types
        value_counts = {str(k): int(v) for k, v in value_counts_series.items()}
        column_profile["value_counts"] = value_counts

        # Add categorical-specific stats
        if "n_category" in column_data:
            column_profile["n_category"] = column_data.get("n_category")

    # Add histogram data if available
    if "histogram" in column_data:
        column_profile["histogram"] = column_data.get("histogram")

    return column_profile
