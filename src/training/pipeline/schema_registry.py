# =============================================================================
# schema_registry.py — In-memory registry of extracted table schemas
# =============================================================================
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class Domain(str, Enum):
    TREASURY = "treasury"
    ESG = "esg"
    PERFORMANCE = "performance"


@dataclass
class Column:
    name: str
    data_type: str = "NVARCHAR"
    description: str = ""
    is_key: bool = False
    nullable: bool = True


@dataclass
class TableSchema:
    name: str
    schema_name: str
    domain: Domain = Domain.PERFORMANCE
    columns: list[Column] = field(default_factory=list)
    hierarchy_levels: list[str] = field(default_factory=list)
    row_count: int = 0
    description: str = ""


class SchemaRegistry:
    """Holds extracted table schemas for the text-to-SQL pipeline."""

    def __init__(self) -> None:
        self._tables: list[TableSchema] = []
        self._index: dict[str, int] = {}

    @property
    def tables(self) -> list[TableSchema]:
        return self._tables

    def table_count(self) -> int:
        return len(self._tables)

    def add_table(self, table: TableSchema) -> None:
        if table.name in self._index:
            return
        self._index[table.name] = len(self._tables)
        self._tables.append(table)

    def get_table(self, name: str) -> Optional[TableSchema]:
        idx = self._index.get(name)
        return self._tables[idx] if idx is not None else None

    def add_column(self, table_name: str, column: Column) -> None:
        table = self.get_table(table_name)
        if table is not None:
            table.columns.append(column)

    def to_dict(self) -> list[dict]:
        """Serialize the registry to a list of dicts for JSON export."""
        result = []
        for t in self._tables:
            result.append(
                {
                    "name": t.name,
                    "schema_name": t.schema_name,
                    "domain": t.domain.value,
                    "columns": [
                        {
                            "name": c.name,
                            "data_type": c.data_type,
                            "description": c.description,
                            "is_key": c.is_key,
                            "nullable": c.nullable,
                        }
                        for c in t.columns
                    ],
                    "hierarchy_levels": t.hierarchy_levels,
                    "row_count": t.row_count,
                    "description": t.description,
                }
            )
        return result
