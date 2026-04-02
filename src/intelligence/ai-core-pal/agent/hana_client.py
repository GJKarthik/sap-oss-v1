# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
SAP HANA Cloud Client for ai-core-pal MCP Server.

Provides connectivity to SAP HANA Cloud with PAL algorithm execution:
  - Time Series Forecasting (Single Exponential Smoothing)
  - Anomaly Detection (IQR method)
  - Clustering (K-Means)
  - Classification (Random Forest)
  - Regression (Linear/Lasso)

Environment variables:
  HANA_HOST, HANA_PORT (default 443), HANA_USER, HANA_PASSWORD
  HANA_ENCRYPT (default true), HANA_SSL_VALIDATE_CERTIFICATE (default false)
  HANA_SCHEMA (default AINUCLEUS)
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
    """Parse boolean from environment variable."""
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
        sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        currentSchema=os.environ.get("HANA_SCHEMA", "AINUCLEUS"),
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


def test_connection() -> Dict[str, Any]:
    """Test HANA connection and return status."""
    if not is_available():
        return {"status": "error", "error": "hdbcli not installed or credentials not configured"}
    
    try:
        conn = _connect()
        cursor = conn.cursor()
        cursor.execute("SELECT CURRENT_TIMESTAMP, CURRENT_USER, CURRENT_SCHEMA FROM DUMMY")
        row = cursor.fetchone()
        conn.close()
        return {
            "status": "success",
            "timestamp": str(row[0]),
            "user": row[1],
            "schema": row[2],
            "host": os.environ.get("HANA_HOST", ""),
        }
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# Table Discovery
# ---------------------------------------------------------------------------

def list_tables(schema: Optional[str] = None) -> List[Dict[str, Any]]:
    """List tables in a schema."""
    schema = schema or os.environ.get("HANA_SCHEMA", "AINUCLEUS")
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT TABLE_NAME, TABLE_TYPE 
            FROM SYS.TABLES 
            WHERE SCHEMA_NAME = '{schema.upper()}'
            ORDER BY TABLE_NAME
        """)
        return [{"table_name": row[0], "table_type": row[1]} for row in cur.fetchall()]
    finally:
        conn.close()


def describe_table(table_name: str, schema: Optional[str] = None) -> Dict[str, Any]:
    """Get table schema details."""
    schema = schema or os.environ.get("HANA_SCHEMA", "AINUCLEUS")
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT COLUMN_NAME, DATA_TYPE_NAME, LENGTH, IS_NULLABLE
            FROM SYS.TABLE_COLUMNS 
            WHERE SCHEMA_NAME = '{schema.upper()}'
            AND TABLE_NAME = '{table_name.upper()}'
            ORDER BY POSITION
        """)
        columns = [
            {
                "name": row[0],
                "type": row[1],
                "length": row[2],
                "nullable": row[3] == "TRUE"
            }
            for row in cur.fetchall()
        ]
        
        # Get row count
        try:
            cur.execute(f"SELECT COUNT(*) FROM {schema}.{table_name}")
            row_count = cur.fetchone()[0]
        except:
            row_count = -1
        
        return {
            "table_name": f"{schema}.{table_name}",
            "columns": columns,
            "column_count": len(columns),
            "row_count": row_count,
        }
    finally:
        conn.close()


def discover_pal_tables(schema: Optional[str] = None, include_columns: bool = True) -> Dict[str, Any]:
    """
    Discover HANA tables with numeric columns suitable for PAL analysis.
    
    Returns tables that have at least one numeric column suitable for:
    - Time series forecasting
    - Anomaly detection
    - Clustering
    - Regression
    """
    schema = schema or os.environ.get("HANA_SCHEMA", "AINUCLEUS")
    conn = _connect()
    try:
        cur = conn.cursor()
        
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
# PAL Time Series Forecasting
# ---------------------------------------------------------------------------

def call_pal_forecast(
    input_data: List[Dict[str, Any]],
    horizon: int = 12,
    alpha: float = 0.3,
) -> Dict[str, Any]:
    """
    Run PAL Single Exponential Smoothing on provided time-series data.

    Args:
        input_data: list of {"timestamp": str/int, "value": float}
        horizon: number of periods to forecast
        alpha: smoothing parameter (0-1)
    
    Returns: {"forecast": [...], "model": {...}, "status": "success"}
    """
    if not input_data:
        return {"status": "error", "error": "input_data is required"}

    if len(input_data) < 3:
        return {"status": "error", "error": "Need at least 3 data points for forecasting"}

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
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_TS_{session_id}"
        
        cursor = cc.connection.cursor()
        
        # Drop if exists and create temp table
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
        
        # Load as hana-ml dataframe
        df_ts = cc.table(input_tbl, schema=user)
        
        # Run PAL Single Exponential Smoothing
        ses = SingleExponentialSmoothing(alpha=alpha, forecast_num=horizon)
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
            "model": {"alpha": alpha, "horizon": horizon},
            "input_count": len(input_data),
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed. Install with: pip install hana-ml"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


def call_pal_forecast_from_table(
    table_name: str,
    value_column: str,
    date_column: Optional[str] = None,
    horizon: int = 12,
    alpha: float = 0.3,
    where_clause: Optional[str] = None,
    limit: int = 1000,
) -> Dict[str, Any]:
    """
    Run PAL forecasting directly on a HANA table.
    
    Args:
        table_name: Full table name e.g. "AINUCLEUS.PAL_TIMESERIES_DATA"
        value_column: Column for time series values e.g. "AMOUNT_USD"
        date_column: Date column for ordering
        horizon: Forecast periods
        alpha: Smoothing parameter
        where_clause: Optional filter
        limit: Max records
    """
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
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_TS_TBL_{session_id}"
        
        cursor = cc.connection.cursor()
        
        # Build source query
        order_clause = f'ORDER BY "{date_column}"' if date_column else ""
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        if date_column:
            source_sql = f"""
                SELECT ROW_NUMBER() OVER (ORDER BY "{date_column}") as ID, 
                       CAST("{value_column}" AS DOUBLE) as VALUE
                FROM {table_name}
                {where_sql}
                {order_clause}
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
        
        # Create temp table
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
        
        cursor.execute(f"INSERT INTO {user}.{input_tbl} (ID, VALUE) {source_sql}")
        cc.connection.commit()
        
        # Count rows
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < 3:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {
                "status": "error", 
                "error": f"Only {row_count} rows - need at least 3 for forecasting",
            }
        
        # Run PAL
        df_ts = cc.table(input_tbl, schema=user)
        ses = SingleExponentialSmoothing(alpha=alpha, forecast_num=horizon)
        result = ses.fit_predict(data=df_ts, key='ID')
        forecast_df = result.collect()
        
        # Cleanup
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        forecasts = []
        for _, row in forecast_df.iterrows():
            forecasts.append({
                "idx": int(row.get("ID", 0)),
                "forecast": float(row.get("VALUE", 0)) if row.get("VALUE") else None,
            })
        
        return {
            "status": "success",
            "algorithm": "PAL_SingleExponentialSmoothing",
            "forecast": forecasts,
            "model": {"alpha": alpha, "horizon": horizon},
            "source": {
                "table": table_name,
                "column": value_column,
                "rows_used": row_count,
            },
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# PAL Anomaly Detection
# ---------------------------------------------------------------------------

def call_pal_anomaly(
    input_data: List[Dict[str, Any]],
    multiplier: float = 1.5,
) -> Dict[str, Any]:
    """
    Detect anomalies using IQR method.

    Args:
        input_data: list of {"id": str/int, "value": float}
        multiplier: IQR multiplier for bounds (default 1.5)
    
    Returns: {"anomalies": [...], "total": int, "iqr_stats": {...}}
    """
    if not input_data:
        return {"status": "error", "error": "input_data is required"}
    
    if len(input_data) < 4:
        return {"status": "error", "error": "Need at least 4 data points for IQR analysis"}

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
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_ANOM_INPUT_{session_id}"
        
        cursor = cc.connection.cursor()
        
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
        
        for idx, row in enumerate(input_data):
            cursor.execute(f"INSERT INTO {user}.{input_tbl} VALUES (?, ?)", 
                         [idx, float(row.get("value", 0))])
        cc.connection.commit()
        
        df = cc.table(input_tbl, schema=user)
        
        # Run IQR analysis
        iqr_result = iqr(data=df, key='ID', col='VALUE', multiplier=multiplier)
        
        if isinstance(iqr_result, tuple) and len(iqr_result) >= 5:
            q1, q3, iqr_val, lower, upper = iqr_result[:5]
            q1 = float(q1) if q1 is not None else 0
            q3 = float(q3) if q3 is not None else 0
            iqr_val = float(iqr_val) if iqr_val is not None else 0
            lower = float(lower) if lower is not None else (q1 - multiplier * iqr_val)
            upper = float(upper) if upper is not None else (q3 + multiplier * iqr_val)
        else:
            # Compute manually
            cursor.execute(f"SELECT VALUE FROM {user}.{input_tbl} ORDER BY VALUE")
            values = [row[0] for row in cursor.fetchall()]
            n = len(values)
            q1 = values[n // 4]
            q3 = values[3 * n // 4]
            iqr_val = q3 - q1
            lower = q1 - multiplier * iqr_val
            upper = q3 + multiplier * iqr_val
        
        # Find anomalies
        anomalies = []
        for idx, row in enumerate(input_data):
            value = float(row.get("value", 0))
            if value < lower or value > upper:
                anomalies.append({
                    "id": idx,
                    "value": value,
                    "score": abs(value - (q1 + q3) / 2) / iqr_val if iqr_val > 0 else 0
                })
        
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        return {
            "status": "success",
            "algorithm": "PAL_IQR",
            "anomalies": anomalies,
            "total": len(input_data),
            "anomaly_count": len(anomalies),
            "iqr_stats": {
                "q1": q1,
                "q3": q3,
                "iqr": iqr_val,
                "lower_bound": lower,
                "upper_bound": upper,
                "multiplier": multiplier,
            }
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


def call_pal_anomaly_from_table(
    table_name: str,
    value_column: str,
    id_column: Optional[str] = None,
    multiplier: float = 1.5,
    where_clause: Optional[str] = None,
    limit: int = 1000,
) -> Dict[str, Any]:
    """
    Run PAL anomaly detection directly on a HANA table.
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
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_ANOM_TBL_{session_id}"
        
        cursor = cc.connection.cursor()
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        source_sql = f"""
            SELECT ROW_NUMBER() OVER () as ID,
                   CAST("{value_column}" AS DOUBLE) as VALUE
            FROM {table_name}
            {where_sql}
            LIMIT {limit}
        """
        
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
        
        cursor.execute(f"INSERT INTO {user}.{input_tbl} {source_sql}")
        cc.connection.commit()
        
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < 4:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {"status": "error", "error": f"Only {row_count} rows - need at least 4"}
        
        df = cc.table(input_tbl, schema=user)
        iqr_result = iqr(data=df, key='ID', col='VALUE', multiplier=multiplier)
        
        if isinstance(iqr_result, tuple) and len(iqr_result) >= 5:
            q1, q3, iqr_val, lower, upper = iqr_result[:5]
            q1 = float(q1) if q1 is not None else 0
            q3 = float(q3) if q3 is not None else 0
            iqr_val = float(iqr_val) if iqr_val is not None else 0
            lower = float(lower) if lower is not None else (q1 - multiplier * iqr_val)
            upper = float(upper) if upper is not None else (q3 + multiplier * iqr_val)
        else:
            cursor.execute(f"SELECT VALUE FROM {user}.{input_tbl} ORDER BY VALUE")
            values = [row[0] for row in cursor.fetchall()]
            n = len(values)
            q1 = values[n // 4]
            q3 = values[3 * n // 4]
            iqr_val = q3 - q1
            lower = q1 - multiplier * iqr_val
            upper = q3 + multiplier * iqr_val
        
        cursor.execute(f"""
            SELECT ID, VALUE FROM {user}.{input_tbl}
            WHERE VALUE < {lower} OR VALUE > {upper}
        """)
        
        anomalies = []
        for row in cursor.fetchall():
            anomalies.append({
                "id": row[0],
                "value": float(row[1]),
                "score": abs(row[1] - (q1 + q3) / 2) / iqr_val if iqr_val > 0 else 0
            })
        
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        return {
            "status": "success",
            "algorithm": "PAL_IQR",
            "anomalies": anomalies,
            "total": row_count,
            "anomaly_count": len(anomalies),
            "source": {"table": table_name, "column": value_column},
            "iqr_stats": {
                "q1": q1, "q3": q3, "iqr": iqr_val,
                "lower_bound": lower, "upper_bound": upper,
            }
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# PAL Clustering (K-Means)
# ---------------------------------------------------------------------------

def call_pal_clustering(
    table_name: str,
    feature_columns: List[str],
    n_clusters: int = 3,
    id_column: Optional[str] = None,
    where_clause: Optional[str] = None,
    limit: int = 1000,
) -> Dict[str, Any]:
    """
    Run PAL K-Means clustering on a HANA table.
    
    Args:
        table_name: Source table
        feature_columns: Numeric columns to cluster on
        n_clusters: Number of clusters
        id_column: ID column for results
        where_clause: Optional filter
        limit: Max rows
    """
    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.clustering import KMeans
        
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_CLUST_{session_id}"
        
        cursor = cc.connection.cursor()
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        # Build SELECT with ROW_NUMBER as ID
        feature_cols = ", ".join([f'CAST("{c}" AS DOUBLE) AS "{c}"' for c in feature_columns])
        source_sql = f"""
            SELECT ROW_NUMBER() OVER () as ID, {feature_cols}
            FROM {table_name}
            {where_sql}
            LIMIT {limit}
        """
        
        # Create temp table with ID + features
        col_defs = "ID INTEGER PRIMARY KEY, " + ", ".join([f'"{c}" DOUBLE' for c in feature_columns])
        
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        cursor.execute(f"CREATE COLUMN TABLE {user}.{input_tbl} ({col_defs})")
        cursor.execute(f"INSERT INTO {user}.{input_tbl} {source_sql}")
        cc.connection.commit()
        
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < n_clusters:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {"status": "error", "error": f"Only {row_count} rows - need at least {n_clusters}"}
        
        df = cc.table(input_tbl, schema=user)
        
        kmeans = KMeans(n_clusters=n_clusters, init='first_k', max_iter=100)
        kmeans.fit(data=df, key='ID')
        
        labels_df = kmeans.labels_.collect()
        
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        cluster_counts = {}
        for _, row in labels_df.iterrows():
            cluster = int(row.get("CLUSTER_ID", 0))
            cluster_counts[cluster] = cluster_counts.get(cluster, 0) + 1
        
        return {
            "status": "success",
            "algorithm": "PAL_KMeans",
            "n_clusters": n_clusters,
            "cluster_sizes": cluster_counts,
            "total_rows": row_count,
            "source": {
                "table": table_name,
                "features": feature_columns,
            },
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# PAL Classification (Random Forest)
# ---------------------------------------------------------------------------

def call_pal_classification(
    table_name: str,
    feature_columns: List[str],
    label_column: str,
    test_ratio: float = 0.2,
    n_estimators: int = 100,
    where_clause: Optional[str] = None,
    limit: int = 1000,
) -> Dict[str, Any]:
    """
    Run PAL Random Forest classification.
    """
    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.trees import RandomForestClassifier
        
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_CLASSIF_{session_id}"
        
        cursor = cc.connection.cursor()
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        feature_cols = ", ".join([f'CAST("{c}" AS DOUBLE) AS "{c}"' for c in feature_columns])
        source_sql = f"""
            SELECT ROW_NUMBER() OVER () as ID, {feature_cols}, "{label_column}" as LABEL
            FROM {table_name}
            {where_sql}
            LIMIT {limit}
        """
        
        col_defs = "ID INTEGER PRIMARY KEY, " + ", ".join([f'"{c}" DOUBLE' for c in feature_columns]) + ", LABEL NVARCHAR(100)"
        
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        cursor.execute(f"CREATE COLUMN TABLE {user}.{input_tbl} ({col_defs})")
        cursor.execute(f"INSERT INTO {user}.{input_tbl} {source_sql}")
        cc.connection.commit()
        
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < 10:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {"status": "error", "error": f"Only {row_count} rows - need at least 10"}
        
        df = cc.table(input_tbl, schema=user)
        
        rf = RandomForestClassifier(n_estimators=n_estimators, random_state=42)
        rf.fit(data=df, key='ID', label='LABEL')
        
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        return {
            "status": "success",
            "algorithm": "PAL_RandomForestClassifier",
            "n_estimators": n_estimators,
            "training_rows": row_count,
            "source": {
                "table": table_name,
                "features": feature_columns,
                "label": label_column,
            },
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# PAL Regression
# ---------------------------------------------------------------------------

def call_pal_regression(
    table_name: str,
    feature_columns: List[str],
    target_column: str,
    where_clause: Optional[str] = None,
    limit: int = 1000,
) -> Dict[str, Any]:
    """
    Run PAL Linear Regression.
    """
    try:
        from hana_ml.dataframe import ConnectionContext
        from hana_ml.algorithms.pal.regression import LinearRegression
        
        cc = ConnectionContext(
            address=os.environ.get("HANA_HOST", ""),
            port=int(os.environ.get("HANA_PORT", "443")),
            user=os.environ.get("HANA_USER", ""),
            password=os.environ.get("HANA_PASSWORD", ""),
            encrypt=_env_bool("HANA_ENCRYPT", True),
            sslValidateCertificate=_env_bool("HANA_SSL_VALIDATE_CERTIFICATE", False),
        )
        
        user = os.environ.get("HANA_USER", "AINUCLEUS")
        session_id = uuid.uuid4().hex[:8].upper()
        input_tbl = f"PAL_REG_{session_id}"
        
        cursor = cc.connection.cursor()
        where_sql = f"WHERE {where_clause}" if where_clause else ""
        
        feature_cols = ", ".join([f'CAST("{c}" AS DOUBLE) AS "{c}"' for c in feature_columns])
        source_sql = f"""
            SELECT ROW_NUMBER() OVER () as ID, {feature_cols}, CAST("{target_column}" AS DOUBLE) as TARGET
            FROM {table_name}
            {where_sql}
            LIMIT {limit}
        """
        
        col_defs = "ID INTEGER PRIMARY KEY, " + ", ".join([f'"{c}" DOUBLE' for c in feature_columns]) + ", TARGET DOUBLE"
        
        try:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        except:
            pass
        
        cursor.execute(f"CREATE COLUMN TABLE {user}.{input_tbl} ({col_defs})")
        cursor.execute(f"INSERT INTO {user}.{input_tbl} {source_sql}")
        cc.connection.commit()
        
        cursor.execute(f"SELECT COUNT(*) FROM {user}.{input_tbl}")
        row_count = cursor.fetchone()[0]
        
        if row_count < 5:
            cursor.execute(f"DROP TABLE {user}.{input_tbl}")
            cc.close()
            return {"status": "error", "error": f"Only {row_count} rows - need at least 5"}
        
        df = cc.table(input_tbl, schema=user)
        
        lr = LinearRegression()
        lr.fit(data=df, key='ID', label='TARGET')
        
        coefficients = lr.coefficients_.collect().to_dict('records') if hasattr(lr, 'coefficients_') else []
        
        cursor.execute(f"DROP TABLE {user}.{input_tbl}")
        cc.close()
        
        return {
            "status": "success",
            "algorithm": "PAL_LinearRegression",
            "training_rows": row_count,
            "coefficients": coefficients,
            "source": {
                "table": table_name,
                "features": feature_columns,
                "target": target_column,
            },
        }
    except ImportError:
        return {"status": "error", "error": "hana-ml not installed"}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


# ---------------------------------------------------------------------------
# SQL Execution (for table creation/population)
# ---------------------------------------------------------------------------

# Destructive SQL operations that require explicit allow_destructive=True
_DESTRUCTIVE_KEYWORDS = frozenset([
    "DROP", "TRUNCATE", "ALTER", "GRANT", "REVOKE", "CREATE USER", "DROP USER",
])

# Pattern to detect DROP TABLE, DROP SCHEMA, etc.
_DANGEROUS_PATTERNS = [
    r"\bDROP\s+(TABLE|SCHEMA|VIEW|INDEX|PROCEDURE|FUNCTION)\b",
    r"\bTRUNCATE\s+TABLE\b",
    r"\bALTER\s+(TABLE|SCHEMA)\b",
    r"\bGRANT\b",
    r"\bREVOKE\b",
]


def execute_sql(
    sql: str,
    allow_destructive: bool = False,
    allow_delete: bool = True,
) -> Dict[str, Any]:
    """
    Execute SQL statement with safety checks.
    
    Args:
        sql: SQL statement to execute
        allow_destructive: If False (default), blocks DROP/TRUNCATE/ALTER operations
        allow_delete: If True (default), allows DELETE statements
    
    Returns:
        Dict with status, rows/affected_rows, or error
    """
    if not is_available():
        return {"status": "error", "error": "HANA not configured"}
    
    sql_upper = sql.strip().upper()
    
    # Check for destructive operations
    if not allow_destructive:
        import re
        for pattern in _DANGEROUS_PATTERNS:
            if re.search(pattern, sql_upper):
                return {
                    "status": "error",
                    "error": f"Destructive operation blocked. Pattern '{pattern}' detected. "
                             f"Set allow_destructive=True to override.",
                    "blocked": True,
                }
    
    # Check DELETE without WHERE clause (dangerous bulk delete)
    if "DELETE" in sql_upper and "WHERE" not in sql_upper:
        if not allow_destructive:
            return {
                "status": "error",
                "error": "DELETE without WHERE clause blocked. This would delete all rows. "
                         "Set allow_destructive=True to override.",
                "blocked": True,
            }
    
    try:
        conn = _connect()
        cursor = conn.cursor()
        cursor.execute(sql)
        
        if sql_upper.startswith("SELECT"):
            rows = _rows_to_dicts(cursor)
            conn.close()
            return {"status": "success", "rows": rows, "count": len(rows)}
        else:
            conn.commit()
            affected = cursor.rowcount
            conn.close()
            return {"status": "success", "affected_rows": affected}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}
