"""
SAP HANA Cloud Connector for Mangle Query Service.

Provides analytical query execution against HANA Cloud calculation views.
Supports:
- Analytical aggregations (SUM, COUNT, AVG, etc.)
- Hierarchy drill-down
- Time-series queries
- SQL generation from Mangle classification
"""

import os
import asyncio
from typing import Dict, List, Any, Optional, Tuple
from datetime import datetime
from contextlib import asynccontextmanager
import logging

logger = logging.getLogger(__name__)

# Configuration
HANA_HOST = os.getenv("HANA_HOST", "")
HANA_PORT = int(os.getenv("HANA_PORT", "443"))
HANA_USER = os.getenv("HANA_USER", "")
HANA_PASSWORD = os.getenv("HANA_PASSWORD", "")
HANA_ENCRYPT = os.getenv("HANA_ENCRYPT", "true").lower() == "true"


class HANAClient:
    """
    Async HANA Cloud client for analytical queries.
    
    Uses hdbcli (SAP HANA Client) for connection.
    """
    
    def __init__(
        self,
        host: str = HANA_HOST,
        port: int = HANA_PORT,
        user: str = HANA_USER,
        password: str = HANA_PASSWORD,
        encrypt: bool = HANA_ENCRYPT,
    ):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.encrypt = encrypt
        self._connection = None
        self._pool: List[Any] = []
        self._pool_size = 5
    
    def is_configured(self) -> bool:
        """Check if HANA connection is configured."""
        return bool(self.host and self.user and self.password)
    
    def _create_connection(self):
        """Create a new HANA connection."""
        try:
            from hdbcli import dbapi
            return dbapi.connect(
                address=self.host,
                port=self.port,
                user=self.user,
                password=self.password,
                encrypt=self.encrypt,
                sslValidateCertificate=False,  # For SAP HANA Cloud
            )
        except ImportError:
            logger.error("hdbcli not installed. Install with: pip install hdbcli")
            raise
        except Exception as e:
            logger.error(f"HANA connection failed: {e}")
            raise
    
    @asynccontextmanager
    async def get_connection(self):
        """Get connection from pool (async context manager)."""
        conn = None
        try:
            # Get from pool or create new
            if self._pool:
                conn = self._pool.pop()
            else:
                # Run sync connection in thread pool
                loop = asyncio.get_event_loop()
                conn = await loop.run_in_executor(None, self._create_connection)
            
            yield conn
            
        finally:
            # Return to pool
            if conn:
                if len(self._pool) < self._pool_size:
                    self._pool.append(conn)
                else:
                    conn.close()
    
    async def execute(
        self,
        sql: str,
        params: Optional[Tuple] = None,
    ) -> List[Dict[str, Any]]:
        """Execute SQL query and return results as dicts."""
        
        if not self.is_configured():
            raise RuntimeError("HANA connection not configured")
        
        async with self.get_connection() as conn:
            cursor = conn.cursor()
            try:
                loop = asyncio.get_event_loop()
                
                # Execute query
                if params:
                    await loop.run_in_executor(None, cursor.execute, sql, params)
                else:
                    await loop.run_in_executor(None, cursor.execute, sql)
                
                # Fetch results
                columns = [desc[0] for desc in cursor.description]
                rows = await loop.run_in_executor(None, cursor.fetchall)
                
                return [dict(zip(columns, row)) for row in rows]
                
            finally:
                cursor.close()
    
    async def execute_scalar(self, sql: str, params: Optional[Tuple] = None) -> Any:
        """Execute query returning single value."""
        results = await self.execute(sql, params)
        if results and results[0]:
            return list(results[0].values())[0]
        return None
    
    async def close(self):
        """Close all connections in pool."""
        for conn in self._pool:
            try:
                conn.close()
            except Exception:
                pass
        self._pool.clear()


class AnalyticalQueryBuilder:
    """
    Builds SQL for analytical queries from Mangle classification.
    
    Maps dimensions, measures, filters to HANA SQL.
    """
    
    def __init__(self):
        # Aggregation type mapping
        self.agg_functions = {
            "SUM": "SUM",
            "COUNT": "COUNT",
            "AVG": "AVG",
            "MIN": "MIN",
            "MAX": "MAX",
            "COUNT_DISTINCT": "COUNT(DISTINCT {})",
        }
    
    def build_aggregate_query(
        self,
        view_name: str,
        schema: str,
        dimensions: List[str],
        measures: Dict[str, str],  # measure_name -> aggregation_type
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 1000,
    ) -> Tuple[str, Tuple]:
        """
        Build analytical aggregation query.
        
        Example output:
        SELECT Region, Customer, SUM(NetAmount), COUNT(OrderId)
        FROM "ANALYTICS"."CV_SALES_ORDER"
        WHERE OrderDate BETWEEN ? AND ?
        GROUP BY Region, Customer
        ORDER BY SUM(NetAmount) DESC
        LIMIT 1000
        """
        
        # SELECT clause
        select_parts = []
        for dim in dimensions:
            select_parts.append(f'"{dim}"')
        
        for measure, agg_type in measures.items():
            agg_func = self.agg_functions.get(agg_type, "SUM")
            if "{}" in agg_func:
                measure_ref = f'"{measure}"'
                select_parts.append(f'{agg_func.format(measure_ref)} AS "{measure}"')
            else:
                select_parts.append(f'{agg_func}("{measure}") AS "{measure}"')
        
        select_clause = ", ".join(select_parts)
        
        # FROM clause
        from_clause = f'"{schema}"."{view_name}"'
        
        # WHERE clause
        where_parts = []
        params = []
        
        if filters:
            if "date_range" in filters:
                date_range = filters["date_range"]
                # Assume date column is standard
                where_parts.append("\"OrderDate\" BETWEEN ? AND ?")
                params.extend([date_range["start"], date_range["end"]])
            
            if "company_code" in filters:
                where_parts.append("\"CompanyCode\" = ?")
                params.append(filters["company_code"])
            
            if "fiscal_year" in filters:
                where_parts.append("\"FiscalYear\" = ?")
                params.append(filters["fiscal_year"])
        
        where_clause = " AND ".join(where_parts) if where_parts else "1=1"
        
        # GROUP BY clause
        group_by = ", ".join([f'"{dim}"' for dim in dimensions]) if dimensions else ""
        
        # ORDER BY (by first measure descending)
        order_by = ""
        if measures:
            first_measure = list(measures.keys())[0]
            first_agg = self.agg_functions.get(measures[first_measure], "SUM")
            if "{}" in first_agg:
                measure_ref = f'"{first_measure}"'
                order_by = f'{first_agg.format(measure_ref)} DESC'
            else:
                order_by = f'{first_agg}("{first_measure}") DESC'
        
        # Build final SQL
        sql_parts = [f"SELECT {select_clause}", f"FROM {from_clause}", f"WHERE {where_clause}"]
        
        if group_by:
            sql_parts.append(f"GROUP BY {group_by}")
        if order_by:
            sql_parts.append(f"ORDER BY {order_by}")
        
        sql_parts.append(f"LIMIT {limit}")
        
        sql = "\n".join(sql_parts)
        
        return sql, tuple(params)
    
    def build_hierarchy_query(
        self,
        view_name: str,
        schema: str,
        hierarchy_name: str,
        node_column: str,
        parent_column: str,
        level: int = 1,
        parent_value: Optional[str] = None,
    ) -> Tuple[str, Tuple]:
        """
        Build hierarchy drill-down query.
        
        Uses HANA hierarchy functions or recursive CTE.
        """
        
        params = []
        
        if parent_value:
            # Drill down to children
            sql = f'''
            SELECT "{node_column}", "{parent_column}", 
                   HIERARCHY_LEVEL("{node_column}") AS level
            FROM "{schema}"."{view_name}"
            WHERE "{parent_column}" = ?
            ORDER BY "{node_column}"
            '''
            params.append(parent_value)
        else:
            # Get top level
            sql = f'''
            SELECT "{node_column}", "{parent_column}",
                   HIERARCHY_LEVEL("{node_column}") AS level
            FROM "{schema}"."{view_name}"  
            WHERE "{parent_column}" IS NULL
               OR HIERARCHY_LEVEL("{node_column}") = 1
            ORDER BY "{node_column}"
            '''
        
        return sql, tuple(params)
    
    def build_timeseries_query(
        self,
        view_name: str,
        schema: str,
        time_dimension: str,
        granularity: str,  # YEAR, MONTH, WEEK, DAY
        measures: Dict[str, str],
        filters: Optional[Dict[str, Any]] = None,
    ) -> Tuple[str, Tuple]:
        """
        Build time-series aggregation query.
        """
        
        # Time truncation based on granularity
        time_trunc = {
            "YEAR": f'YEAR("{time_dimension}")',
            "MONTH": f'TO_CHAR("{time_dimension}", \'YYYY-MM\')',
            "WEEK": f'WEEK("{time_dimension}")',
            "DAY": f'TO_DATE("{time_dimension}")',
        }.get(granularity.upper(), f'"{time_dimension}"')
        
        # SELECT clause
        select_parts = [f'{time_trunc} AS "Period"']
        
        for measure, agg_type in measures.items():
            agg_func = self.agg_functions.get(agg_type, "SUM")
            select_parts.append(f'{agg_func}("{measure}") AS "{measure}"')
        
        select_clause = ", ".join(select_parts)
        
        # FROM clause
        from_clause = f'"{schema}"."{view_name}"'
        
        # WHERE clause
        where_parts = []
        params = []
        
        if filters and "date_range" in filters:
            date_range = filters["date_range"]
            where_parts.append(f'"{time_dimension}" BETWEEN ? AND ?')
            params.extend([date_range["start"], date_range["end"]])
        
        where_clause = " AND ".join(where_parts) if where_parts else "1=1"
        
        # GROUP BY and ORDER BY
        sql = f'''
        SELECT {select_clause}
        FROM {from_clause}
        WHERE {where_clause}
        GROUP BY {time_trunc}
        ORDER BY {time_trunc}
        '''
        
        return sql, tuple(params)


class HANAResolver:
    """
    Resolves analytical queries via HANA.
    
    Called by MangleRouter for HANA_ANALYTICAL and HANA_HIERARCHY paths.
    """
    
    def __init__(self):
        self.client = HANAClient()
        self.query_builder = AnalyticalQueryBuilder()
    
    async def resolve_analytical(
        self,
        classification: Dict[str, Any],
        metadata: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Execute analytical query against HANA.
        
        Args:
            classification: Query classification with dimensions, measures, filters
            metadata: Entity metadata with view names
        
        Returns:
            Dict with results and SQL
        """
        
        if not self.client.is_configured():
            return {
                "results": [],
                "sql": None,
                "error": "HANA not configured",
                "source": "hana_analytical",
            }
        
        entities = classification.get("entities", [])
        if not entities:
            return {"results": [], "error": "No entities identified"}
        
        # Get view info from metadata
        primary_entity = entities[0]
        entity_meta = metadata.get("analytical_entities", {}).get(primary_entity, {})
        
        view_name = entity_meta.get("view", primary_entity)
        schema = entity_meta.get("schema", "ANALYTICS")
        
        # Get measures with aggregation types
        measures = {}
        entity_measures = metadata.get("measures", {}).get(primary_entity, {})
        for m in classification.get("measures", []):
            measures[m] = entity_measures.get(m, "SUM")
        
        # Build and execute query
        try:
            sql, params = self.query_builder.build_aggregate_query(
                view_name=view_name,
                schema=schema,
                dimensions=classification.get("dimensions", []),
                measures=measures,
                filters=classification.get("filters", {}),
            )
            
            results = await self.client.execute(sql, params)
            
            return {
                "results": results,
                "sql": sql,
                "params": params,
                "row_count": len(results),
                "source": "hana_analytical",
            }
            
        except Exception as e:
            logger.error(f"HANA query failed: {e}")
            return {
                "results": [],
                "sql": None,
                "error": str(e),
                "source": "hana_analytical",
            }
    
    async def resolve_hierarchy(
        self,
        classification: Dict[str, Any],
        metadata: Dict[str, Any],
        parent_value: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Execute hierarchy drill-down query against HANA.
        """
        
        if not self.client.is_configured():
            return {"results": [], "error": "HANA not configured"}
        
        entities = classification.get("entities", [])
        if not entities:
            return {"results": [], "error": "No entities identified"}
        
        primary_entity = entities[0]
        entity_meta = metadata.get("analytical_entities", {}).get(primary_entity, {})
        hierarchy_meta = metadata.get("hierarchies", {}).get(primary_entity, {})
        
        if not hierarchy_meta:
            return {"results": [], "error": f"No hierarchy defined for {primary_entity}"}
        
        # Get first hierarchy
        hierarchy_name = list(hierarchy_meta.keys())[0]
        node_col, parent_col = hierarchy_meta[hierarchy_name]
        
        view_name = entity_meta.get("view", primary_entity)
        schema = entity_meta.get("schema", "ANALYTICS")
        
        try:
            sql, params = self.query_builder.build_hierarchy_query(
                view_name=view_name,
                schema=schema,
                hierarchy_name=hierarchy_name,
                node_column=node_col,
                parent_column=parent_col,
                parent_value=parent_value,
            )
            
            results = await self.client.execute(sql, params)
            
            return {
                "results": results,
                "sql": sql,
                "hierarchy": hierarchy_name,
                "source": "hana_hierarchy",
            }
            
        except Exception as e:
            logger.error(f"HANA hierarchy query failed: {e}")
            return {"results": [], "error": str(e)}
    
    async def resolve_timeseries(
        self,
        classification: Dict[str, Any],
        metadata: Dict[str, Any],
        granularity: str = "MONTH",
    ) -> Dict[str, Any]:
        """
        Execute time-series aggregation query against HANA.
        """
        
        if not self.client.is_configured():
            return {"results": [], "error": "HANA not configured"}
        
        entities = classification.get("entities", [])
        if not entities:
            return {"results": [], "error": "No entities identified"}
        
        primary_entity = entities[0]
        entity_meta = metadata.get("analytical_entities", {}).get(primary_entity, {})
        
        view_name = entity_meta.get("view", primary_entity)
        schema = entity_meta.get("schema", "ANALYTICS")
        
        # Get time dimension (default to OrderDate)
        time_dim = "OrderDate"  # Could be extracted from metadata
        
        # Get measures with aggregation types
        measures = {}
        entity_measures = metadata.get("measures", {}).get(primary_entity, {})
        for m in classification.get("measures", []):
            measures[m] = entity_measures.get(m, "SUM")
        
        try:
            sql, params = self.query_builder.build_timeseries_query(
                view_name=view_name,
                schema=schema,
                time_dimension=time_dim,
                granularity=granularity,
                measures=measures,
                filters=classification.get("filters", {}),
            )
            
            results = await self.client.execute(sql, params)
            
            return {
                "results": results,
                "sql": sql,
                "granularity": granularity,
                "source": "hana_timeseries",
            }
            
        except Exception as e:
            logger.error(f"HANA timeseries query failed: {e}")
            return {"results": [], "error": str(e)}
    
    async def health_check(self) -> Dict[str, Any]:
        """Check HANA connectivity."""
        
        if not self.client.is_configured():
            return {"status": "not_configured", "host": ""}
        
        try:
            result = await self.client.execute_scalar("SELECT 1 FROM DUMMY")
            return {
                "status": "healthy" if result == 1 else "unhealthy",
                "host": self.client.host,
                "port": self.client.port,
            }
        except Exception as e:
            return {
                "status": "error",
                "host": self.client.host,
                "error": str(e),
            }


# Singleton instance
hana_resolver = HANAResolver()