# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Utilities for packaging data‑quality violations as DataFrames."""

from __future__ import annotations

from typing import List, Dict
from pydantic import BaseModel, Field

import pandas as pd
from pandera.errors import SchemaErrors

COLUMNS: List[str] = [
    "table_name",
    "schema_context",
    "column",
    "check",
    "check_number",
    "failure_case",
    "index",
    "from_pandera",
]


def corruption_from_pandera(table_name: str, err: SchemaErrors) -> pd.DataFrame:
    """Convert `err.failure_cases` into a normalised DataFrame."""
    err.failure_cases["table_name"] = table_name
    err.failure_cases["from_pandera"] = True
    return err.failure_cases[COLUMNS]


def corruption_from_validation_func(
    validation_result: Dict[str, pd.Series], check_name: str, table_data: Dict[str, pd.DataFrame]
) -> pd.DataFrame:
    """
    Convert the output of an LLM-generated validation function into a corruption DataFrame.
    """
    corruption_rows = [
        {
            "table_name": table_name,
            "schema_context": "Custom",
            "column": violation_series.name,
            "check": check_name,
            "check_number": None,
            "failure_case": table_data[table_name].loc[int(row_idx), str(violation_series.name)],
            "index": row_idx,
            "from_pandera": False,
        }
        for table_name, violation_series in validation_result.items()
        for row_idx in violation_series.values
    ]
    return pd.DataFrame(corruption_rows, columns=COLUMNS) if corruption_rows else pd.DataFrame(columns=COLUMNS)
