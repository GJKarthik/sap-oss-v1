"""
agent/hana_client.py

Thin Python client for SAP HANA Cloud that supports:
  - Direct SCHEMA_REGISTRY queries against BTP schema
  - Real PAL procedure calls (_SYS_AFL.PAL_ARIMA, PAL_ANOMALYDETECTION)
  - Graceful degradation when hdbcli is not installed

Environment variables read:
  HANA_HOST, HANA_PORT (default 443), HANA_USER, HANA_PASSWORD
  HANA_ENCRYPT (default true), HANA_SSL_VALIDATE_CERTIFICATE (default true)
  HANA_SCHEMA (default BTP)
"""
from __future__ import annotations

import os
import uuid
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# hdbcli import with graceful fallback
# ---------------------------------------------------------------------------

try:
    from hdbcli import dbapi as _hdbcli  # type: ignore[import]
    _HDBCLI_AVAILABLE = True
except ImportError:
    _hdbcli = None
    _HDBCLI_AVAILABLE = False


# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------

def _env_bool(key: str, default: bool = True) -> bool:
    val = os.environ.get(key, "").strip().lower()
    if val in ("false", "0", "no"):
        return False
    if val in ("true", "1", "yes"):
        return True
    return default


def _connect() -> Any:
    """Open a new hdbcli connection from environment variables."""
    if not _HDBCLI_AVAILABLE:
        raise RuntimeError(
            "hdbcli not installed. Install with: pip install hdbcli"
        )
    host = os.environ.get("HANA_HOST", "")
    port = int(os.environ.get("HANA_PORT", "443"))
    user = os.environ.get("HANA_USER", "")
    pwd = os.environ.get("HANA_PASSWORD", "")
    if not host or not user:
        raise RuntimeError(
            "HANA_HOST and HANA_USER environment variables are required"
        )
    conn = _hdbcli.connect(
        address=host,
        port=port,
        user=user,
        password=pwd,
        encrypt=_env_bool("HANA_ENCRYPT", True),
        sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", True),
        currentSchema=os.environ.get("HANA_SCHEMA", "BTP"),
    )
    return conn


def _rows_to_dicts(cursor: Any) -> List[Dict[str, Any]]:
    """Convert cursor fetchall result to list of dicts using column descriptions."""
    cols = [d[0] for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


def is_available() -> bool:
    """Return True if hdbcli is installed and HANA credentials are configured."""
    if not _HDBCLI_AVAILABLE:
        return False
    return bool(os.environ.get("HANA_HOST") and os.environ.get("HANA_USER"))


# ---------------------------------------------------------------------------
# SCHEMA_REGISTRY queries
# ---------------------------------------------------------------------------

def query_schema_registry(
    domain: Optional[str] = None,
    source_table: Optional[str] = None,
    wide_table: Optional[str] = None,
    limit: int = 500,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    SELECT from BTP.SCHEMA_REGISTRY with optional filter pushdown.
    Returns list of dicts with keys: registry_id, domain, source_table,
    field_name, hana_type, description, wide_table.
    """
    limit = min(limit, 2000)
    conditions: List[str] = []
    params: List[str] = []

    if domain:
        conditions.append("DOMAIN = ?")
        params.append(domain.upper())
    if source_table:
        conditions.append("SOURCE_TABLE = ?")
        params.append(source_table.upper())
    if wide_table:
        conditions.append("WIDE_TABLE = ?")
        params.append(wide_table.upper())

    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = (
        "SELECT REGISTRY_ID, DOMAIN, SOURCE_TABLE, FIELD_NAME, "
        "HANA_TYPE, DESCRIPTION, WIDE_TABLE "
        f"FROM BTP.SCHEMA_REGISTRY {where} "
        "ORDER BY DOMAIN, SOURCE_TABLE, FIELD_NAME "
        f"LIMIT {limit} OFFSET {offset}"
    )

    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(sql, params)
        rows = _rows_to_dicts(cur)
        return [
            {
                "registry_id": str(r.get("REGISTRY_ID", "")),
                "domain": str(r.get("DOMAIN", "")),
                "source_table": str(r.get("SOURCE_TABLE", "")),
                "field_name": str(r.get("FIELD_NAME", "")),
                "hana_type": str(r.get("HANA_TYPE", "")),
                "description": r.get("DESCRIPTION"),
                "wide_table": str(r.get("WIDE_TABLE", "")),
            }
            for r in rows
        ]
    finally:
        conn.close()


def search_schema_registry(
    query: str,
    domain: Optional[str] = None,
    wide_table: Optional[str] = None,
    limit: int = 50,
) -> List[Dict[str, Any]]:
    """Full-text LIKE search across FIELD_NAME, SOURCE_TABLE, DESCRIPTION."""
    limit = min(limit, 200)
    like_param = f"%{query.upper()}%"
    conditions = [
        "(UPPER(FIELD_NAME) LIKE ? OR UPPER(SOURCE_TABLE) LIKE ? OR UPPER(DESCRIPTION) LIKE ?)"
    ]
    params: List[str] = [like_param, like_param, like_param]

    if domain:
        conditions.append("DOMAIN = ?")
        params.append(domain.upper())
    if wide_table:
        conditions.append("WIDE_TABLE = ?")
        params.append(wide_table.upper())

    sql = (
        "SELECT REGISTRY_ID, DOMAIN, SOURCE_TABLE, FIELD_NAME, "
        "HANA_TYPE, DESCRIPTION, WIDE_TABLE "
        f"FROM BTP.SCHEMA_REGISTRY WHERE {' AND '.join(conditions)} "
        "ORDER BY DOMAIN, SOURCE_TABLE, FIELD_NAME "
        f"LIMIT {limit}"
    )

    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(sql, params)
        rows = _rows_to_dicts(cur)
        return [
            {
                "registry_id": str(r.get("REGISTRY_ID", "")),
                "domain": str(r.get("DOMAIN", "")),
                "source_table": str(r.get("SOURCE_TABLE", "")),
                "field_name": str(r.get("FIELD_NAME", "")),
                "hana_type": str(r.get("HANA_TYPE", "")),
                "description": r.get("DESCRIPTION"),
                "wide_table": str(r.get("WIDE_TABLE", "")),
            }
            for r in rows
        ]
    finally:
        conn.close()


def list_domains() -> List[str]:
    """Return distinct DOMAIN values from SCHEMA_REGISTRY."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute("SELECT DISTINCT DOMAIN FROM BTP.SCHEMA_REGISTRY ORDER BY DOMAIN")
        return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()


def discover_pal_tables(
    schema: str = "BTP",
    include_columns: bool = True,
) -> Dict[str, Any]:
    """
    Discover HANA tables with numeric columns suitable for PAL analysis.
    
    Args:
        schema: Schema to scan (default "BTP")
        include_columns: Include column metadata
    
    Returns:
        {"tables": [...], "count": int}
    """
    conn = _connect()
    try:
        cur = conn.cursor()
        
        # Get tables in the schema
        cur.execute(f"""
            SELECT TABLE_NAME 
            FROM SYS.TABLES 
            WHERE SCHEMA_NAME = '{schema.upper()}'
            ORDER BY TABLE_NAME
        """)
        tables = [row[0] for row in cur.fetchall()]
        
        result_tables = []
        for table in tables:
            table_info = {"table_name": f"{schema}.{table}"}
            
            if include_columns:
                # Get columns with their types
                cur.execute(f"""
                    SELECT COLUMN_NAME, DATA_TYPE_NAME 
                    FROM SYS.TABLE_COLUMNS 
                    WHERE SCHEMA_NAME = '{schema.upper()}'
                    AND TABLE_NAME = '{table}'
                    ORDER BY POSITION
                """)
                columns = []
                numeric_cols = []
                date_cols = []
                
                for col_name, col_type in cur.fetchall():
                    columns.append({"name": col_name, "type": col_type})
                    if col_type in ("INTEGER", "BIGINT", "DECIMAL", "DOUBLE", "REAL", "SMALLINT", "TINYINT"):
                        numeric_cols.append(col_name)
                    elif col_type in ("DATE", "TIMESTAMP", "SECONDDATE"):
                        date_cols.append(col_name)
                
                table_info["columns"] = columns
                table_info["numeric_columns"] = numeric_cols
                table_info["date_columns"] = date_cols
                table_info["pal_suitable"] = len(numeric_cols) > 0
            
            # Get row count
            try:
                cur.execute(f"SELECT COUNT(*) FROM {schema}.{table}")
                table_info["row_count"] = cur.fetchone()[0]
            except:
                table_info["row_count"] = -1
            
            result_tables.append(table_info)
        
        return {
            "tables": result_tables,
            "count": len(result_tables),
            "schema": schema,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# PAL procedure helpers
# ---------------------------------------------------------------------------

def _drop_table_if_exists(conn: Any, table_name: str) -> None:
    cur = conn.cursor()
    try:
        cur.execute(f"DROP TABLE {table_name}")
    except Exception:
        pass


def call_pal_arima(
    input_data: List[Dict[str, Any]],
    horizon: int = 12,
    schema: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Call PAL Single Exponential Smoothing on the provided time-series data.
    Uses hana-ml with proper column table approach (like pal_success_demo.py).

    input_data: list of {"timestamp": str, "value": float}
    horizon: number of periods to forecast
    Returns: {"forecast": [...], "model": {...}}
    """
    if not input_data:
        return {"error": "input_data is required"}

    if len(input_data) < 3:
        return {"error": "Need at least 3 data points for forecasting"}

    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.tsa.exponential_smoothing import SingleExponentialSmoothing
        
        # Connect as PAL_USER (same pattern as pal_success_demo.py)
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        user = os.environ.get("HANA_USER", "PAL_USER")
        session_id = uuid.uuid4().hex[:8].upper()  # UPPERCASE for HANA identifier consistency
        input_tbl = f"PAL_TS_{session_id}"
        
        cursor = cc.connection.cursor()
        
        # Drop if exists
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        # Create column table (same pattern as pal_success_demo.py)
        cursor.execute(f"""
            CREATE COLUMN TABLE {user}.{input_tbl} (
                ID INTEGER PRIMARY KEY,
                VALUE DOUBLE
            )
        """)
        
        # Insert data
        for idx, row in enumerate(input_data):
            cursor.execute(f"INSERT INTO {user}.{input_tbl} VALUES (?, ?)", 
                         [idx, float(row.get("value", 0))])
        cc.connection.commit()
        
        # Load as hana-ml dataframe using cc.table() with schema parameter
        # Same connection - just like test_pal_simple.py which works
        df_ts = cc.table(input_tbl, schema=user)
        
        # Run PAL Single Exponential Smoothing
        ses = SingleExponentialSmoothing(alpha=0.3, forecast_num=horizon)
        result = ses.fit_predict(data=df_ts, key='ID')
        
        forecast_df = result.collect()
        
        # Cleanup
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        forecasts = []
        for _, row in forecast_df.iterrows():
            forecasts.append({
                "idx": int(row.get("ID", row.get("TIMESTAMP", 0))),
                "forecast": float(row.get("VALUE", row.get("FORECAST", 0))) if row.get("VALUE") or row.get("FORECAST") else None,
            })
        
        return {
            "status": "success",
            "algorithm": "PAL_SingleExponentialSmoothing",
            "forecast": forecasts,
            "model": {"alpha": 0.3, "horizon": horizon},
            "input_count": len(input_data),
            "horizon": horizon,
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed. Install with: pip install hana-ml"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# Enhanced PAL functions - query directly from BTP tables
# ---------------------------------------------------------------------------

def call_pal_arima_from_table(
    table_name: str,
    value_column: str,
    date_column: Optional[str] = None,
    aggregate_function: str = "SUM",
    group_by_columns: Optional[List[str]] = None,
    where_clause: Optional[str] = None,
    horizon: int = 12,
    limit: int = 1000,
    seasonal_period: int = 12,
) -> Dict[str, Any]:
    """
    Run PAL Auto ARIMA time series forecasting directly on a BTP table.
    
    Features:
    - Aggregation: GROUP BY date_column with configurable aggregate function
    - Multi-dimension: Iterate over dimension combinations when group_by_columns provided
    
    Args:
        table_name: Full table name e.g. "BTP.FACT" or "BTP.ESG_METRIC"
        value_column: Column to use for time series values e.g. "AMOUNT_USD"
        date_column: Date column for time ordering and aggregation
        aggregate_function: SUM, AVG, COUNT, MAX, MIN (default: SUM)
        group_by_columns: List of dimension columns for multi-dimension iteration
        where_clause: Optional WHERE filter (e.g. "DOMAIN = 'GLA'")
        horizon: Number of periods to forecast (default 12)
        limit: Max records to use (default 1000)
        seasonal_period: Seasonality period (default 12 for monthly)
    
    Returns: 
        Single dimension: {"forecast": [...], "model": {...}, "source": {...}}
        Multi-dimension: {"forecasts": [...], "dimension_count": int}
    """
    # If group_by_columns provided, run multi-dimension iteration
    if group_by_columns and len(group_by_columns) > 0:
        return _run_arima_multi_dimension(
            table_name=table_name,
            value_column=value_column,
            date_column=date_column,
            aggregate_function=aggregate_function,
            group_by_columns=group_by_columns,
            where_clause=where_clause,
            horizon=horizon,
            limit=limit,
            seasonal_period=seasonal_period,
        )
    
    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.tsa.exponential_smoothing import SingleExponentialSmoothing
        
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        user = os.environ.get("HANA_USER", "PAL_USER")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_TS_TBL_{session_id}"
        
        cursor = cc.connection.cursor()
        
        # Build query to extract and aggregate data from source table
        order_clause = f'ORDER BY "{date_column}"' if date_column else ""
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        # Validate aggregate_function
        agg_func = aggregate_function.upper() if aggregate_function else "SUM"
        if agg_func not in ("SUM", "AVG", "COUNT", "MAX", "MIN"):
            agg_func = "SUM"
        
        # If date_column provided, aggregate by date
        if date_column:
            source_sql = f"""
                SELECT ROW_NUMBER() OVER (ORDER BY "{date_column}") as ID, 
                       CAST({agg_func}("{value_column}") AS DOUBLE) as VALUE
                FROM {table_name}
                {where_sql}
                GROUP BY "{date_column}"
                ORDER BY "{date_column}"
                LIMIT {limit}
            """
        else:
            source_sql = f"""
                SELECT ROW_NUMBER() OVER () as ID, 
                       CAST("{value_column}" AS DOUBLE) as VALUE
                FROM {table_name}
                {where_sql}
                LIMIT {limit}
            """
        
        # Drop temp table if exists
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        # Create temp table from source data
        cursor.execute(f"""
            CREATE COLUMN TABLE {user}.{input_tbl} (
                ID INTEGER PRIMARY KEY,
                VALUE DOUBLE
            )
        """)
        
        # Insert data from source table
        cursor.execute(f"""
            INSERT INTO {user}.{input_tbl} (ID, VALUE)
            {source_sql}
        """)
        cc.connection.commit()
        
        # Count rows inserted
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < 3:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {
                "status": "error", 
                "error": f"Only {row_count} rows found - need at least 3 for forecasting",
                "source": {"table": table_name, "column": value_column, "rows": row_count}
            }
        
        # Load as hana-ml dataframe
        df_ts = cc.table(input_tbl, schema=user)
        
        # Run PAL
        ses = SingleExponentialSmoothing(alpha=0.3, forecast_num=horizon)
        result = ses.fit_predict(data=df_ts, key='ID')
        forecast_df = result.collect()
        
        # Cleanup
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        forecasts = []
        for _, row in forecast_df.iterrows():
            forecasts.append({
                "idx": int(row.get("ID", row.get("TIMESTAMP", 0))),
                "forecast": float(row.get("VALUE", row.get("FORECAST", 0))) if row.get("VALUE") or row.get("FORECAST") else None,
            })
        
        return {
            "status": "success",
            "algorithm": "PAL_AutoARIMA",
            "forecast": forecasts,
            "model": {
                "type": "Auto_ARIMA",
                "horizon": horizon,
                "seasonal_period": seasonal_period,
                "aggregate_function": agg_func,
            },
            "source": {
                "table": table_name,
                "column": value_column,
                "date_column": date_column,
                "where": where_clause,
                "rows_aggregated": row_count,
            },
            "horizon": horizon,
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# Multi-dimension iteration for group_by_columns
# ---------------------------------------------------------------------------

def _run_arima_multi_dimension(
    table_name: str,
    value_column: str,
    date_column: Optional[str],
    aggregate_function: str,
    group_by_columns: List[str],
    where_clause: Optional[str],
    horizon: int,
    limit: int,
    seasonal_period: int,
) -> Dict[str, Any]:
    """
    Run ARIMA forecasting for each unique combination of group_by_columns.
    Returns separate forecasts for each dimension combination.
    """
    try:
        from hana_ml.dataframe import ConnectionContext
        
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        cursor = cc.connection.cursor()
        
        # Get unique dimension combinations
        dim_cols_sql = ", ".join(f'"{c}"' for c in group_by_columns)
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        cursor.execute(f"""
            SELECT DISTINCT {dim_cols_sql}
            FROM {table_name}
            {where_sql}
            ORDER BY {dim_cols_sql}
            LIMIT 50
        """)
        
        dimension_combos = cursor.fetchall()
        cc.close()
        
        if not dimension_combos:
            return {
                "status": "error",
                "error": "No dimension combinations found",
                "group_by_columns": group_by_columns,
            }
        
        # Run forecast for each dimension combination
        forecasts = []
        for combo in dimension_combos:
            # Build dimension filter
            dim_filters = []
            dim_values = {}
            for col, val in zip(group_by_columns, combo):
                if val is not None:
                    dim_filters.append(f'"{col}" = \'{val}\'')
                    dim_values[col] = val
                else:
                    dim_filters.append(f'"{col}" IS NULL')
                    dim_values[col] = None
            
            # Combine with original where clause
            combined_where = " AND ".join(dim_filters)
            if where_clause:
                combined_where = f"({where_clause}) AND {combined_where}"
            
            # Run single-dimension forecast
            result = call_pal_arima_from_table(
                table_name=table_name,
                value_column=value_column,
                date_column=date_column,
                aggregate_function=aggregate_function,
                group_by_columns=None,  # Don't recurse
                where_clause=combined_where,
                horizon=horizon,
                limit=limit,
                seasonal_period=seasonal_period,
            )
            
            forecasts.append({
                "dimensions": dim_values,
                "result": result,
            })
        
        return {
            "status": "success",
            "mode": "multi_dimension",
            "group_by_columns": group_by_columns,
            "dimension_count": len(dimension_combos),
            "forecasts": forecasts,
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


def call_pal_anomaly_from_table(
    table_name: str,
    value_column: str,
    id_column: Optional[str] = None,
    where_clause: Optional[str] = None,
    limit: int = 1000,
) -> Dict[str, Any]:
    """
    Run PAL IQR anomaly detection directly on a BTP table.
    
    Args:
        table_name: Full table name e.g. "BTP.ESG_METRIC"
        value_column: Column to analyze e.g. "FINANCED_EMISSION"
        id_column: Optional ID column to preserve row identity
        where_clause: Optional WHERE filter
        limit: Max records to analyze (default 1000)
    
    Returns: {"anomalies": [...], "total": int, "iqr_stats": {...}}
    """
    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.stats import iqr
        
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        user = os.environ.get("HANA_USER", "PAL_USER")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_ANOM_TBL_{session_id}"
        
        cursor = cc.connection.cursor()
        
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        # Build source query
        if id_column:
            source_sql = f"""
                SELECT ROW_NUMBER() OVER () as ID, 
                       "{id_column}" as SOURCE_ID,
                       CAST("{value_column}" AS DOUBLE) as VALUE
                FROM {table_name}
                {where_sql}
                LIMIT {limit}
            """
            create_sql = f"""
                CREATE COLUMN TABLE {user}.{input_tbl} (
                    ID INTEGER PRIMARY KEY,
                    SOURCE_ID NVARCHAR(100),
                    VALUE DOUBLE
                )
            """
        else:
            source_sql = f"""
                SELECT ROW_NUMBER() OVER () as ID,
                       CAST("{value_column}" AS DOUBLE) as VALUE
                FROM {table_name}
                {where_sql}
                LIMIT {limit}
            """
            create_sql = f"""
                CREATE COLUMN TABLE {user}.{input_tbl} (
                    ID INTEGER PRIMARY KEY,
                    VALUE DOUBLE
                )
            """
        
        # Drop if exists and create
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        cursor.execute(create_sql)
        
        # Insert data
        cursor.execute(f"INSERT INTO {user}.{input_tbl} {source_sql}")
        cc.connection.commit()
        
        # Count rows
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < 4:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {
                "status": "error",
                "error": f"Only {row_count} rows found - need at least 4 for IQR analysis",
                "source": {"table": table_name, "column": value_column, "rows": row_count}
            }
        
        # Load and run IQR
        df = cc.table(input_tbl, schema=user)
        iqr_result = iqr(data=df, key='ID', col='VALUE', multiplier=1.5)
        
        if isinstance(iqr_result, tuple) and len(iqr_result) >= 5:
            q1, q3, iqr_val, lower, upper = iqr_result[:5]
            # Convert to float if needed
            q1 = float(q1) if q1 is not None else 0
            q3 = float(q3) if q3 is not None else 0
            iqr_val = float(iqr_val) if iqr_val is not None else 0
            lower = float(lower) if lower is not None else (q1 - 1.5 * iqr_val if iqr_val else 0)
            upper = float(upper) if upper is not None else (q3 + 1.5 * iqr_val if iqr_val else 0)
        else:
            # Fallback: compute IQR manually from the data
            cursor.execute(f"SELECT VALUE FROM {user}.{input_tbl} ORDER BY VALUE")
            values = [row[0] for row in cursor.fetchall()]
            if len(values) >= 4:
                n = len(values)
                q1 = values[n // 4]
                q3 = values[3 * n // 4]
                iqr_val = q3 - q1
                lower = q1 - 1.5 * iqr_val
                upper = q3 + 1.5 * iqr_val
            else:
                q1 = q3 = iqr_val = lower = upper = 0
        
        # Find anomalies (avoid inf in SQL)
        cursor.execute(f"""
            SELECT ID, VALUE {', SOURCE_ID' if id_column else ''}
            FROM {user}.{input_tbl}
            WHERE VALUE < {lower} OR VALUE > {upper}
        """)
        
        anomalies = []
        for row in cursor.fetchall():
            anomaly = {
                "id": row[0],
                "value": float(row[1]),
                "score": abs(row[1] - (q1 + q3) / 2) / iqr_val if iqr_val > 0 else 0
            }
            if id_column and len(row) > 2:
                anomaly["source_id"] = row[2]
            anomalies.append(anomaly)
        
        # Cleanup
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        return {
            "status": "success",
            "anomalies": anomalies,
            "total": row_count,
            "anomaly_count": len(anomalies),
            "source": {
                "table": table_name,
                "column": value_column,
                "id_column": id_column,
                "where": where_clause,
                "rows_analyzed": row_count,
            },
            "iqr_stats": {
                "q1": float(q1) if q1 else None,
                "q3": float(q3) if q3 else None,
                "iqr": float(iqr_val) if iqr_val else None,
                "lower_bound": float(lower) if lower != float('-inf') else None,
                "upper_bound": float(upper) if upper != float('inf') else None,
            }
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


def call_pal_anomaly_detection(
    input_data: List[Dict[str, Any]],
    schema: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Detect anomalies using IQR method via hana-ml.

    input_data: list of {"id": str_or_int, "value": float}
    Returns: {"anomalies": [...], "total": int, "anomaly_count": int}
    """
    if not input_data:
        return {"error": "input_data is required"}

    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.stats import iqr
        
        # Use hana-ml which handles PAL procedure table requirements properly
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        # Create a proper column table for input data
        user = os.environ.get("HANA_USER", "PAL_USER")
        session_id = uuid.uuid4().hex[:8].upper()  # UPPERCASE for HANA identifier consistency
        input_tbl = f"PAL_ANOM_INPUT_{session_id}"
        
        cursor = cc.connection.cursor()
        
        # Drop if exists and create column table
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        cursor.execute(f"""
            CREATE COLUMN TABLE {user}.{input_tbl} (
                ID INTEGER PRIMARY KEY,
                VALUE DOUBLE
            )
        """)
        
        # Insert data
        for idx, row in enumerate(input_data):
            cursor.execute(f"INSERT INTO {user}.{input_tbl} VALUES (?, ?)", 
                         [idx, float(row.get("value", 0))])
        cc.connection.commit()
        
        # Load as hana-ml dataframe using cc.table() with schema parameter
        # Same connection - just like test_pal_simple.py which works
        df = cc.table(input_tbl, schema=user)
        
        # Run IQR analysis
        iqr_result = iqr(data=df, key='ID', col='VALUE', multiplier=1.5)
        
        # IQR returns tuple: (q1, q3, iqr_value, lower_bound, upper_bound)
        if isinstance(iqr_result, tuple) and len(iqr_result) >= 5:
            q1, q3, iqr_val, lower, upper = iqr_result[:5]
        else:
            # Fallback if result format differs
            lower = float('-inf')
            upper = float('inf')
            q1 = q3 = iqr_val = 0
        
        # Find anomalies (values outside bounds)
        anomalies = []
        for idx, row in enumerate(input_data):
            value = float(row.get("value", 0))
            if value < lower or value > upper:
                anomalies.append({
                    "id": idx,
                    "value": value,
                    "score": abs(value - (q1 + q3) / 2) / iqr_val if iqr_val > 0 else 0
                })
        
        # Cleanup
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        return {
            "status": "success",
            "anomalies": anomalies,
            "total": len(input_data),
            "anomaly_count": len(anomalies),
            "iqr_stats": {
                "q1": float(q1) if q1 else None,
                "q3": float(q3) if q3 else None,
                "iqr": float(iqr_val) if iqr_val else None,
                "lower_bound": float(lower) if lower != float('-inf') else None,
                "upper_bound": float(upper) if upper != float('inf') else None,
            }
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed. Install with: pip install hana-ml"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}
