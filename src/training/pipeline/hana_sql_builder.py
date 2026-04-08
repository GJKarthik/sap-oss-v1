# =============================================================================
# hana_sql_builder.py — Generate SAP HANA SQL from schema + template context
# =============================================================================
from __future__ import annotations

from dataclasses import dataclass

from .schema_registry import Column, Domain, TableSchema


@dataclass
class SqlQuery:
    sql: str
    tables_used: list[str]
    domain: Domain


def build_select(
    table: TableSchema,
    columns: list[str] | None = None,
    where_clauses: list[str] | None = None,
    group_by: list[str] | None = None,
    order_by: str | None = None,
    order_dir: str = "DESC",
    limit: int | None = None,
) -> SqlQuery:
    """Build a HANA-compatible SELECT statement from schema metadata."""
    col_names = columns or [c.name for c in table.columns]
    if not col_names:
        col_names = ["*"]

    quoted_cols = ", ".join(f'"{c}"' for c in col_names)
    sql = f'SELECT {quoted_cols}\nFROM "{table.schema_name}"."{table.name}"'

    if where_clauses:
        sql += "\nWHERE " + "\n  AND ".join(where_clauses)

    if group_by:
        quoted_gb = ", ".join(f'"{c}"' for c in group_by)
        sql += f"\nGROUP BY {quoted_gb}"

    if order_by:
        sql += f'\nORDER BY "{order_by}" {order_dir}'

    if limit is not None:
        sql += f"\nLIMIT {limit}"

    return SqlQuery(sql=sql, tables_used=[table.name], domain=table.domain)


def build_aggregation(
    table: TableSchema,
    measure_col: str,
    agg_func: str = "SUM",
    dimension_cols: list[str] | None = None,
    where_clauses: list[str] | None = None,
    order_dir: str = "DESC",
    limit: int | None = None,
) -> SqlQuery:
    """Build an aggregation query (SUM, COUNT, AVG, etc.)."""
    dims = dimension_cols or []
    dim_parts = [f'"{d}"' for d in dims]
    agg_part = f'{agg_func}("{measure_col}") AS "{agg_func.lower()}_{measure_col}"'

    select_parts = dim_parts + [agg_part]
    sql = f'SELECT {", ".join(select_parts)}\nFROM "{table.schema_name}"."{table.name}"'

    if where_clauses:
        sql += "\nWHERE " + "\n  AND ".join(where_clauses)

    if dims:
        sql += f"\nGROUP BY {', '.join(dim_parts)}"

    order_col = f"{agg_func.lower()}_{measure_col}"
    sql += f'\nORDER BY "{order_col}" {order_dir}'

    if limit is not None:
        sql += f"\nLIMIT {limit}"

    return SqlQuery(sql=sql, tables_used=[table.name], domain=table.domain)


def build_join(
    left_table: TableSchema,
    right_table: TableSchema,
    join_col: str,
    select_cols: list[str] | None = None,
    where_clauses: list[str] | None = None,
    limit: int | None = None,
) -> SqlQuery:
    """Build a HANA-compatible JOIN query."""
    left_alias = "t1"
    right_alias = "t2"

    if select_cols:
        quoted_cols = ", ".join(f'{left_alias}."{c}"' for c in select_cols)
    else:
        quoted_cols = f"{left_alias}.*"

    sql = (
        f"SELECT {quoted_cols}\n"
        f'FROM "{left_table.schema_name}"."{left_table.name}" {left_alias}\n'
        f'INNER JOIN "{right_table.schema_name}"."{right_table.name}" {right_alias}\n'
        f'  ON {left_alias}."{join_col}" = {right_alias}."{join_col}"'
    )

    if where_clauses:
        sql += "\nWHERE " + "\n  AND ".join(where_clauses)

    if limit is not None:
        sql += f"\nLIMIT {limit}"

    return SqlQuery(
        sql=sql,
        tables_used=[left_table.name, right_table.name],
        domain=left_table.domain,
    )
