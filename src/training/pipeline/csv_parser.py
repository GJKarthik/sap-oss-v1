# =============================================================================
# csv_parser.py — CSV parsing utilities for the text-to-SQL pipeline
# =============================================================================
from __future__ import annotations

import csv
import io
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator


@dataclass
class CsvRow:
    fields: list[str] = field(default_factory=list)


def parse_csv_string(data: str, delimiter: str = ",") -> list[CsvRow]:
    """Parse a CSV string into a list of CsvRow objects."""
    reader = csv.reader(io.StringIO(data), delimiter=delimiter)
    return [CsvRow(fields=row) for row in reader]


def parse_csv_file(path: str | Path, encoding: str = "utf-8", delimiter: str = ",") -> list[CsvRow]:
    """Parse a CSV file into a list of CsvRow objects."""
    path = Path(path)
    with path.open("r", encoding=encoding, errors="replace") as fh:
        reader = csv.reader(fh, delimiter=delimiter)
        return [CsvRow(fields=row) for row in reader]


def iter_csv_file(path: str | Path, encoding: str = "utf-8", delimiter: str = ",") -> Iterator[CsvRow]:
    """Lazily iterate over rows of a CSV file."""
    path = Path(path)
    with path.open("r", encoding=encoding, errors="replace") as fh:
        reader = csv.reader(fh, delimiter=delimiter)
        for row in reader:
            yield CsvRow(fields=row)
