"""
Additional function for hana_client.py - discover_pal_tables
This function should be added to the main hana_client.py file.
"""

import re

_SAFE_IDENTIFIER_RE = re.compile(r'^[A-Za-z0-9_]+$')


def _validate_identifier(name: str) -> str:
    """Raise ValueError if name contains characters outside [A-Za-z0-9_]."""
    if not _SAFE_IDENTIFIER_RE.match(name):
        raise ValueError(f"Unsafe SQL identifier rejected: {name!r}")
    return name


def discover_pal_tables(
    schema: str = "BTP",
    include_columns: bool = True,
) -> dict:
    """
    Discover tables in a schema that have numeric columns suitable for PAL analysis.

    Args:
        schema: Schema to scan (default "BTP")
        include_columns: Include column metadata (default True)

    Returns:
        Dict with tables list including numeric/date columns and row counts
    """
    conn = _connect()
    try:
        cur = conn.cursor()

        # Get tables in schema
        cur.execute("""
            SELECT TABLE_NAME
            FROM SYS.TABLES
            WHERE SCHEMA_NAME = ?
            ORDER BY TABLE_NAME
        """, [schema])

        safe_schema = _validate_identifier(schema)
        tables = []
        for (table_name,) in cur.fetchall():
            safe_table = _validate_identifier(table_name)
            table_info = {"table_name": f"{safe_schema}.{safe_table}"}

            # Get row count
            try:
                cur.execute(f'SELECT COUNT(*) FROM "{safe_schema}"."{safe_table}"')
                table_info["row_count"] = cur.fetchone()[0]
            except:
                table_info["row_count"] = 0

            if include_columns:
                # Get numeric columns suitable for PAL
                cur.execute("""
                    SELECT COLUMN_NAME, DATA_TYPE_NAME
                    FROM SYS.TABLE_COLUMNS
                    WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?
                    AND DATA_TYPE_NAME IN ('INTEGER', 'BIGINT', 'DECIMAL', 'DOUBLE', 'REAL', 'FLOAT', 'SMALLINT', 'TINYINT')
                    ORDER BY POSITION
                """, [schema, table_name])
                numeric_cols = [{"name": row[0], "type": row[1]} for row in cur.fetchall()]
                table_info["numeric_columns"] = numeric_cols

                # Get date/time columns for ordering
                cur.execute("""
                    SELECT COLUMN_NAME, DATA_TYPE_NAME
                    FROM SYS.TABLE_COLUMNS
                    WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?
                    AND DATA_TYPE_NAME IN ('DATE', 'TIME', 'TIMESTAMP', 'SECONDDATE')
                    ORDER BY POSITION
                """, [schema, table_name])
                date_cols = [{"name": row[0], "type": row[1]} for row in cur.fetchall()]
                table_info["date_columns"] = date_cols

                # Mark as PAL-suitable if has numeric and optionally date columns
                table_info["pal_suitable"] = len(numeric_cols) > 0

            tables.append(table_info)

        return {
            "schema": schema,
            "tables": tables,
            "total_tables": len(tables),
            "pal_suitable_count": sum(1 for t in tables if t.get("pal_suitable", False)),
        }
    finally:
        conn.close()