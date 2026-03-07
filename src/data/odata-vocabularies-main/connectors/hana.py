"""
SAP HANA Cloud Connector

Production-ready HANA Cloud integration with vocabulary context.
Supports connection pooling, retry logic, and circuit breaker pattern.
"""

import logging
from typing import Any, Dict, List, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime, timedelta
import time
import threading

logger = logging.getLogger(__name__)


@dataclass
class ConnectionStats:
    """Connection pool statistics"""
    total_connections: int = 0
    active_connections: int = 0
    idle_connections: int = 0
    failed_connections: int = 0
    total_queries: int = 0
    avg_query_time_ms: float = 0
    last_error: Optional[str] = None
    last_error_time: Optional[datetime] = None


class CircuitBreaker:
    """Circuit breaker for HANA connections"""
    
    def __init__(self, failure_threshold: int = 5, reset_timeout: int = 60):
        self.failure_threshold = failure_threshold
        self.reset_timeout = reset_timeout
        self.failure_count = 0
        self.last_failure_time: Optional[datetime] = None
        self.state = "closed"  # closed, open, half-open
        self._lock = threading.Lock()
    
    def record_failure(self):
        """Record a connection failure"""
        with self._lock:
            self.failure_count += 1
            self.last_failure_time = datetime.utcnow()
            if self.failure_count >= self.failure_threshold:
                self.state = "open"
                logger.warning(f"Circuit breaker opened after {self.failure_count} failures")
    
    def record_success(self):
        """Record a successful connection"""
        with self._lock:
            self.failure_count = 0
            self.state = "closed"
    
    def can_execute(self) -> bool:
        """Check if execution is allowed"""
        with self._lock:
            if self.state == "closed":
                return True
            elif self.state == "open":
                if self.last_failure_time:
                    elapsed = (datetime.utcnow() - self.last_failure_time).total_seconds()
                    if elapsed >= self.reset_timeout:
                        self.state = "half-open"
                        return True
                return False
            else:  # half-open
                return True


class HANAConnector:
    """
    SAP HANA Cloud Connector with vocabulary support.
    
    Features:
    - Connection pooling
    - Retry logic with exponential backoff
    - Circuit breaker pattern
    - Vocabulary-aware query execution
    """
    
    def __init__(self, config: "HANAConfig"):
        """
        Initialize HANA connector.
        
        Args:
            config: HANAConfig from settings
        """
        from config.settings import HANAConfig
        self.config = config
        self.stats = ConnectionStats()
        self.circuit_breaker = CircuitBreaker()
        self._connection_pool: List[Any] = []
        self._pool_lock = threading.Lock()
        self._max_pool_size = 10
        self._min_pool_size = 2
        self._connected = False
        
        # Try to import hdbcli
        self._hdbcli_available = False
        try:
            from hdbcli import dbapi
            self._dbapi = dbapi
            self._hdbcli_available = True
        except ImportError:
            logger.warning("hdbcli not installed - HANA features will be simulated")
    
    def connect(self) -> bool:
        """
        Establish connection to HANA Cloud.
        
        Returns:
            True if connection successful
        """
        if not self.config.is_configured():
            logger.warning("HANA not configured")
            return False
        
        if not self._hdbcli_available:
            logger.warning("hdbcli not available - using simulation mode")
            self._connected = True
            return True
        
        if not self.circuit_breaker.can_execute():
            logger.warning("Circuit breaker is open - skipping connection attempt")
            return False
        
        try:
            conn = self._create_connection()
            if conn:
                with self._pool_lock:
                    self._connection_pool.append(conn)
                    self.stats.total_connections += 1
                    self.stats.idle_connections += 1
                self._connected = True
                self.circuit_breaker.record_success()
                logger.info(f"Connected to HANA Cloud: {self.config.host}")
                return True
        except Exception as e:
            self.circuit_breaker.record_failure()
            self.stats.failed_connections += 1
            self.stats.last_error = str(e)
            self.stats.last_error_time = datetime.utcnow()
            logger.error(f"Failed to connect to HANA: {e}")
            return False
        
        return False
    
    def _create_connection(self) -> Any:
        """Create a new HANA connection"""
        if not self._hdbcli_available:
            return None
        
        return self._dbapi.connect(
            address=self.config.host,
            port=self.config.port,
            user=self.config.user,
            password=self.config.password,
            encrypt=self.config.encrypt,
            sslValidateCertificate=self.config.ssl_validate_certificate,
            connectTimeout=self.config.connection_timeout * 1000
        )
    
    def _get_connection(self) -> Optional[Any]:
        """Get connection from pool or create new"""
        with self._pool_lock:
            if self._connection_pool:
                conn = self._connection_pool.pop()
                self.stats.idle_connections -= 1
                self.stats.active_connections += 1
                return conn
        
        # Create new connection if pool empty
        if self.stats.total_connections < self._max_pool_size:
            conn = self._create_connection()
            if conn:
                with self._pool_lock:
                    self.stats.total_connections += 1
                    self.stats.active_connections += 1
                return conn
        
        return None
    
    def _return_connection(self, conn: Any):
        """Return connection to pool"""
        with self._pool_lock:
            if len(self._connection_pool) < self._max_pool_size:
                self._connection_pool.append(conn)
                self.stats.active_connections -= 1
                self.stats.idle_connections += 1
            else:
                conn.close()
                self.stats.total_connections -= 1
                self.stats.active_connections -= 1
    
    def execute(self, sql: str, params: Tuple = None, retry: int = 3) -> Dict:
        """
        Execute SQL query with retry logic.
        
        Args:
            sql: SQL query string
            params: Query parameters
            retry: Number of retries on failure
            
        Returns:
            Dict with columns and rows
        """
        if not self._connected:
            return {"error": "Not connected to HANA", "columns": [], "rows": []}
        
        if not self.circuit_breaker.can_execute():
            return {"error": "Circuit breaker open", "columns": [], "rows": []}
        
        # Simulation mode
        if not self._hdbcli_available:
            return self._simulate_query(sql, params)
        
        start_time = time.time()
        last_error = None
        
        for attempt in range(retry):
            conn = self._get_connection()
            if not conn:
                last_error = "No available connections"
                time.sleep(0.5 * (attempt + 1))  # Exponential backoff
                continue
            
            try:
                cursor = conn.cursor()
                if params:
                    cursor.execute(sql, params)
                else:
                    cursor.execute(sql)
                
                # Get column names
                columns = [desc[0] for desc in cursor.description] if cursor.description else []
                rows = cursor.fetchall()
                
                cursor.close()
                self._return_connection(conn)
                
                # Update stats
                duration = (time.time() - start_time) * 1000
                self.stats.total_queries += 1
                self.stats.avg_query_time_ms = (
                    (self.stats.avg_query_time_ms * (self.stats.total_queries - 1) + duration)
                    / self.stats.total_queries
                )
                
                self.circuit_breaker.record_success()
                
                return {
                    "columns": columns,
                    "rows": [list(row) for row in rows],
                    "row_count": len(rows),
                    "duration_ms": duration
                }
                
            except Exception as e:
                last_error = str(e)
                self.circuit_breaker.record_failure()
                self.stats.last_error = last_error
                self.stats.last_error_time = datetime.utcnow()
                logger.warning(f"Query failed (attempt {attempt + 1}/{retry}): {e}")
                
                # Try to close bad connection
                try:
                    conn.close()
                except:
                    pass
                
                time.sleep(0.5 * (attempt + 1))
        
        return {"error": last_error, "columns": [], "rows": []}
    
    def _simulate_query(self, sql: str, params: Tuple) -> Dict:
        """Simulate query for testing without HANA"""
        sql_lower = sql.lower()
        
        # Simulate vocabulary queries
        if "calculation_view" in sql_lower:
            return {
                "columns": ["VIEW_NAME", "SCHEMA_NAME", "TYPE"],
                "rows": [
                    ["CV_SALES_ORDERS", "SCHEMA1", "CALCULATION"],
                    ["CV_INVENTORY", "SCHEMA1", "CALCULATION"],
                    ["CV_CUSTOMERS", "SCHEMA1", "CALCULATION"]
                ],
                "row_count": 3,
                "duration_ms": 15.5,
                "simulated": True
            }
        elif "tables" in sql_lower or "columns" in sql_lower:
            return {
                "columns": ["TABLE_NAME", "COLUMN_NAME", "DATA_TYPE", "LENGTH"],
                "rows": [
                    ["SALES_ORDER", "ORDER_ID", "NVARCHAR", 36],
                    ["SALES_ORDER", "CUSTOMER_ID", "NVARCHAR", 36],
                    ["SALES_ORDER", "TOTAL_AMOUNT", "DECIMAL", 15]
                ],
                "row_count": 3,
                "duration_ms": 12.3,
                "simulated": True
            }
        else:
            return {
                "columns": ["RESULT"],
                "rows": [["Simulated result"]],
                "row_count": 1,
                "duration_ms": 5.0,
                "simulated": True
            }
    
    def get_calculation_views(self, schema: str = None) -> List[Dict]:
        """
        Get list of calculation views with vocabulary annotations.
        
        Args:
            schema: Filter by schema name
            
        Returns:
            List of calculation view metadata
        """
        schema = schema or self.config.schema
        
        sql = """
        SELECT 
            VIEW_NAME,
            SCHEMA_NAME,
            VIEW_TYPE,
            COMMENTS
        FROM SYS.VIEWS
        WHERE VIEW_TYPE LIKE '%CALC%'
        """
        
        if schema:
            sql += f" AND SCHEMA_NAME = '{schema}'"
        
        result = self.execute(sql)
        
        views = []
        for row in result.get("rows", []):
            views.append({
                "name": row[0],
                "schema": row[1],
                "type": row[2],
                "description": row[3] if len(row) > 3 else "",
                "vocabulary_annotations": {
                    "@HANACloud.CalculationView": True,
                    "@Analytics.DataCategory": "#CUBE"
                }
            })
        
        return views
    
    def get_table_metadata(self, table_name: str, schema: str = None) -> Dict:
        """
        Get table metadata with OData vocabulary mapping.
        
        Args:
            table_name: Table name
            schema: Schema name
            
        Returns:
            Table metadata with vocabulary annotations
        """
        schema = schema or self.config.schema
        
        sql = f"""
        SELECT 
            COLUMN_NAME,
            DATA_TYPE_NAME,
            LENGTH,
            IS_NULLABLE,
            COMMENTS
        FROM SYS.TABLE_COLUMNS
        WHERE TABLE_NAME = '{table_name}'
        """
        
        if schema:
            sql += f" AND SCHEMA_NAME = '{schema}'"
        
        result = self.execute(sql)
        
        columns = []
        for row in result.get("rows", []):
            col_name = row[0]
            data_type = row[1]
            
            # Map HANA types to OData types
            odata_type = self._map_hana_to_odata_type(data_type)
            
            # Detect vocabulary annotations
            annotations = self._detect_column_annotations(col_name, data_type)
            
            columns.append({
                "name": col_name,
                "hana_type": data_type,
                "odata_type": odata_type,
                "length": row[2],
                "nullable": row[3] == "TRUE",
                "description": row[4] if len(row) > 4 else "",
                "annotations": annotations
            })
        
        return {
            "table_name": table_name,
            "schema": schema,
            "columns": columns,
            "column_count": len(columns)
        }
    
    def _map_hana_to_odata_type(self, hana_type: str) -> str:
        """Map HANA data type to OData type"""
        mapping = {
            "NVARCHAR": "Edm.String",
            "VARCHAR": "Edm.String",
            "NCLOB": "Edm.String",
            "INTEGER": "Edm.Int32",
            "BIGINT": "Edm.Int64",
            "SMALLINT": "Edm.Int16",
            "TINYINT": "Edm.Byte",
            "DECIMAL": "Edm.Decimal",
            "DOUBLE": "Edm.Double",
            "REAL": "Edm.Single",
            "BOOLEAN": "Edm.Boolean",
            "DATE": "Edm.Date",
            "TIME": "Edm.TimeOfDay",
            "TIMESTAMP": "Edm.DateTimeOffset",
            "SECONDDATE": "Edm.DateTimeOffset",
            "BLOB": "Edm.Binary",
            "VARBINARY": "Edm.Binary"
        }
        return mapping.get(hana_type.upper(), "Edm.String")
    
    def _detect_column_annotations(self, col_name: str, data_type: str) -> Dict:
        """Detect OData vocabulary annotations from column metadata"""
        annotations = {}
        col_lower = col_name.lower()
        
        # Common.Label
        annotations["@Common.Label"] = self._generate_label(col_name)
        
        # Analytics annotations
        if any(kw in col_lower for kw in ["id", "code", "key", "type", "category"]):
            annotations["@Analytics.Dimension"] = True
        elif data_type in ["DECIMAL", "DOUBLE", "INTEGER", "BIGINT"]:
            if any(kw in col_lower for kw in ["amount", "quantity", "value", "price", "count"]):
                annotations["@Analytics.Measure"] = True
        
        # PersonalData annotations
        if any(kw in col_lower for kw in ["name", "email", "phone", "address"]):
            annotations["@PersonalData.IsPotentiallyPersonal"] = True
        
        if any(kw in col_lower for kw in ["health", "medical", "ethnic", "religion"]):
            annotations["@PersonalData.IsPotentiallySensitive"] = True
        
        return annotations
    
    def _generate_label(self, name: str) -> str:
        """Generate human-readable label"""
        import re
        result = re.sub(r'([A-Z])', r' \1', name).strip()
        result = result.replace('_', ' ')
        return ' '.join(word.capitalize() for word in result.split())
    
    def get_stats(self) -> Dict:
        """Get connection statistics"""
        return {
            "total_connections": self.stats.total_connections,
            "active_connections": self.stats.active_connections,
            "idle_connections": self.stats.idle_connections,
            "failed_connections": self.stats.failed_connections,
            "total_queries": self.stats.total_queries,
            "avg_query_time_ms": round(self.stats.avg_query_time_ms, 2),
            "last_error": self.stats.last_error,
            "last_error_time": self.stats.last_error_time.isoformat() if self.stats.last_error_time else None,
            "circuit_breaker_state": self.circuit_breaker.state,
            "hdbcli_available": self._hdbcli_available,
            "connected": self._connected
        }
    
    def close(self):
        """Close all connections"""
        with self._pool_lock:
            for conn in self._connection_pool:
                try:
                    conn.close()
                except:
                    pass
            self._connection_pool = []
            self.stats.total_connections = 0
            self.stats.active_connections = 0
            self.stats.idle_connections = 0
        self._connected = False
        logger.info("HANA connections closed")


# Singleton instance
_connector: Optional[HANAConnector] = None


def get_hana_connector(config: "HANAConfig" = None) -> HANAConnector:
    """Get or create the HANAConnector singleton"""
    global _connector
    if _connector is None:
        if config is None:
            from config.settings import get_settings
            config = get_settings().hana
        _connector = HANAConnector(config)
    return _connector