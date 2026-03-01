# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2023 SAP SE
"""
Analytical Query Support for SAP HANA Cloud.

Addresses langchain-hana Weakness #2: Limited analytical query support.

This module extends langchain-hana with analytical capabilities:
- Aggregation queries (SUM, COUNT, AVG, etc.)
- Hierarchy drill-down
- Time-series queries
- Calculation view support

Usage:
    from langchain_hana.analytical import HanaAnalytical
    
    analytical = HanaAnalytical(connection=conn)
    results = analytical.aggregate(
        view_name="CV_SALES_ORDER",
        dimensions=["Region", "Customer"],
        measures={"NetAmount": "SUM", "Quantity": "COUNT"},
        filters={"FiscalYear": "2024"}
    )
"""

from __future__ import annotations

import json
import logging
from typing import Any, Dict, List, Optional, Tuple, Union
from dataclasses import dataclass, field
from enum import Enum

from hdbcli import dbapi

logger = logging.getLogger(__name__)


class AggregationType(Enum):
    """Supported aggregation functions."""
    SUM = "SUM"
    COUNT = "COUNT"
    COUNT_DISTINCT = "COUNT_DISTINCT"
    AVG = "AVG"
    MIN = "MIN"
    MAX = "MAX"
    STDDEV = "STDDEV"
    VARIANCE = "VAR"


class TimeGranularity(Enum):
    """Time series granularity options."""
    YEAR = "YEAR"
    QUARTER = "QUARTER"
    MONTH = "MONTH"
    WEEK = "WEEK"
    DAY = "DAY"
    HOUR = "HOUR"


@dataclass
class AnalyticalResult:
    """Result from an analytical query."""
    data: List[Dict[str, Any]]
    sql: str
    row_count: int
    dimensions: List[str] = field(default_factory=list)
    measures: List[str] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class HierarchyNode:
    """Node in a hierarchy tree."""
    id: str
    name: str
    parent_id: Optional[str]
    level: int
    children: List["HierarchyNode"] = field(default_factory=list)
    attributes: Dict[str, Any] = field(default_factory=dict)


class HanaAnalytical:
    """
    Analytical query support for SAP HANA Cloud.
    
    Extends langchain-hana with capabilities for:
    - Aggregation queries on calculation views
    - Hierarchy navigation and drill-down
    - Time-series analysis
    - Multi-dimensional analysis
    """
    
    # SQL aggregation function mapping
    AGG_FUNCTIONS = {
        AggregationType.SUM: "SUM({})",
        AggregationType.COUNT: "COUNT({})",
        AggregationType.COUNT_DISTINCT: "COUNT(DISTINCT {})",
        AggregationType.AVG: "AVG({})",
        AggregationType.MIN: "MIN({})",
        AggregationType.MAX: "MAX({})",
        AggregationType.STDDEV: "STDDEV({})",
        AggregationType.VARIANCE: "VAR({})",
    }
    
    # Time truncation SQL for each granularity
    TIME_TRUNCATION = {
        TimeGranularity.YEAR: 'YEAR("{}")',
        TimeGranularity.QUARTER: 'QUARTER("{}")',
        TimeGranularity.MONTH: 'TO_CHAR("{}", \'YYYY-MM\')',
        TimeGranularity.WEEK: 'WEEK("{}")',
        TimeGranularity.DAY: 'TO_DATE("{}")',
        TimeGranularity.HOUR: 'TO_CHAR("{}", \'YYYY-MM-DD HH24\')',
    }
    
    def __init__(
        self,
        connection: dbapi.Connection,
        default_schema: str = "ANALYTICS",
    ):
        """
        Initialize analytical query support.
        
        Args:
            connection: HANA DB connection
            default_schema: Default schema for queries
        """
        self.connection = connection
        self.default_schema = self._sanitize_name(default_schema)
    
    @staticmethod
    def _sanitize_name(name: str) -> str:
        """Sanitize identifier name to prevent SQL injection."""
        import re
        return re.sub(r"[^a-zA-Z0-9_]", "", name)
    
    @staticmethod
    def _sanitize_value(value: Any) -> Any:
        """Sanitize value for SQL parameters."""
        if isinstance(value, str):
            return value
        elif isinstance(value, (int, float)):
            return value
        elif isinstance(value, (list, tuple)):
            return [HanaAnalytical._sanitize_value(v) for v in value]
        elif value is None:
            return None
        else:
            return str(value)
    
    def aggregate(
        self,
        view_name: str,
        dimensions: List[str],
        measures: Dict[str, Union[str, AggregationType]],
        schema: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        having: Optional[Dict[str, Any]] = None,
        order_by: Optional[List[Tuple[str, str]]] = None,
        limit: int = 1000,
    ) -> AnalyticalResult:
        """
        Execute aggregation query on a calculation view.
        
        Args:
            view_name: Name of the calculation view or table
            dimensions: List of dimension columns to group by
            measures: Dict of measure columns to aggregation types
                     e.g., {"NetAmount": "SUM", "Quantity": "COUNT"}
            schema: Schema name (uses default if not provided)
            filters: WHERE clause filters as dict
            having: HAVING clause filters for aggregated values
            order_by: List of (column, direction) tuples
            limit: Maximum rows to return
        
        Returns:
            AnalyticalResult with data and metadata
        
        Example:
            result = analytical.aggregate(
                view_name="CV_SALES_ORDER",
                dimensions=["Region", "ProductCategory"],
                measures={"NetAmount": "SUM", "OrderCount": "COUNT"},
                filters={"FiscalYear": "2024", "CompanyCode": "1000"},
                order_by=[("NetAmount", "DESC")],
                limit=100
            )
        """
        schema = schema or self.default_schema
        view_name = self._sanitize_name(view_name)
        schema = self._sanitize_name(schema)
        
        # Build SELECT clause
        select_parts = []
        
        # Dimensions
        sanitized_dimensions = [self._sanitize_name(d) for d in dimensions]
        for dim in sanitized_dimensions:
            select_parts.append(f'"{dim}"')
        
        # Measures with aggregation
        sanitized_measures = []
        for measure, agg_type in measures.items():
            measure = self._sanitize_name(measure)
            sanitized_measures.append(measure)
            
            if isinstance(agg_type, str):
                agg_type = AggregationType[agg_type.upper()]
            
            agg_sql = self.AGG_FUNCTIONS.get(agg_type, "SUM({})")
            select_parts.append(f'{agg_sql.format(f"{measure}")} AS "{measure}"')
        
        select_clause = ", ".join(select_parts)
        
        # Build FROM clause
        from_clause = f'"{schema}"."{view_name}"'
        
        # Build WHERE clause
        where_clause, params = self._build_where_clause(filters)
        
        # Build GROUP BY clause
        group_by_clause = ", ".join([f'"{d}"' for d in sanitized_dimensions])
        
        # Build HAVING clause
        having_clause = ""
        having_params = []
        if having:
            having_parts = []
            for col, condition in having.items():
                col = self._sanitize_name(col)
                if isinstance(condition, dict):
                    for op, val in condition.items():
                        sql_op = {"gt": ">", "gte": ">=", "lt": "<", "lte": "<=", "eq": "="}.get(op, "=")
                        having_parts.append(f'"{col}" {sql_op} ?')
                        having_params.append(self._sanitize_value(val))
                else:
                    having_parts.append(f'"{col}" = ?')
                    having_params.append(self._sanitize_value(condition))
            if having_parts:
                having_clause = "HAVING " + " AND ".join(having_parts)
        
        # Build ORDER BY clause
        order_clause = ""
        if order_by:
            order_parts = []
            for col, direction in order_by:
                col = self._sanitize_name(col)
                direction = "DESC" if direction.upper() == "DESC" else "ASC"
                order_parts.append(f'"{col}" {direction}')
            order_clause = "ORDER BY " + ", ".join(order_parts)
        elif sanitized_measures:
            # Default: order by first measure descending
            order_clause = f'ORDER BY "{sanitized_measures[0]}" DESC'
        
        # Build full SQL
        sql = f"""
            SELECT {select_clause}
            FROM {from_clause}
            {where_clause}
            GROUP BY {group_by_clause}
            {having_clause}
            {order_clause}
            LIMIT {int(limit)}
        """.strip()
        
        all_params = params + having_params
        
        # Execute query
        try:
            cursor = self.connection.cursor()
            if all_params:
                cursor.execute(sql, all_params)
            else:
                cursor.execute(sql)
            
            columns = [desc[0] for desc in cursor.description]
            rows = cursor.fetchall()
            cursor.close()
            
            data = [dict(zip(columns, row)) for row in rows]
            
            return AnalyticalResult(
                data=data,
                sql=sql,
                row_count=len(data),
                dimensions=sanitized_dimensions,
                measures=sanitized_measures,
                metadata={"schema": schema, "view": view_name}
            )
            
        except Exception as e:
            logger.error(f"Aggregation query failed: {e}")
            logger.error(f"SQL: {sql}")
            raise
    
    def timeseries(
        self,
        view_name: str,
        time_column: str,
        granularity: Union[str, TimeGranularity],
        measures: Dict[str, Union[str, AggregationType]],
        schema: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        additional_dimensions: Optional[List[str]] = None,
        limit: int = 1000,
    ) -> AnalyticalResult:
        """
        Execute time-series aggregation query.
        
        Args:
            view_name: Name of the calculation view or table
            time_column: Date/time column for grouping
            granularity: Time granularity (YEAR, MONTH, DAY, etc.)
            measures: Dict of measure columns to aggregation types
            schema: Schema name
            filters: WHERE clause filters
            additional_dimensions: Extra dimensions to include
            limit: Maximum rows
        
        Returns:
            AnalyticalResult with time-series data
        
        Example:
            result = analytical.timeseries(
                view_name="CV_SALES_ORDER",
                time_column="OrderDate",
                granularity="MONTH",
                measures={"NetAmount": "SUM", "OrderCount": "COUNT"},
                filters={"CompanyCode": "1000"},
                limit=24  # Last 24 months
            )
        """
        schema = schema or self.default_schema
        view_name = self._sanitize_name(view_name)
        schema = self._sanitize_name(schema)
        time_column = self._sanitize_name(time_column)
        
        if isinstance(granularity, str):
            granularity = TimeGranularity[granularity.upper()]
        
        # Build time truncation SQL
        time_trunc = self.TIME_TRUNCATION.get(granularity, '"{}"').format(time_column)
        
        # Build SELECT clause
        select_parts = [f'{time_trunc} AS "Period"']
        
        # Additional dimensions
        additional_dims = []
        if additional_dimensions:
            for dim in additional_dimensions:
                dim = self._sanitize_name(dim)
                additional_dims.append(dim)
                select_parts.append(f'"{dim}"')
        
        # Measures
        sanitized_measures = []
        for measure, agg_type in measures.items():
            measure = self._sanitize_name(measure)
            sanitized_measures.append(measure)
            
            if isinstance(agg_type, str):
                agg_type = AggregationType[agg_type.upper()]
            
            agg_sql = self.AGG_FUNCTIONS.get(agg_type, "SUM({})")
            select_parts.append(f'{agg_sql.format(f"{measure}")} AS "{measure}"')
        
        select_clause = ", ".join(select_parts)
        
        # Build FROM clause
        from_clause = f'"{schema}"."{view_name}"'
        
        # Build WHERE clause
        where_clause, params = self._build_where_clause(filters)
        
        # Build GROUP BY clause
        group_parts = [time_trunc] + [f'"{d}"' for d in additional_dims]
        group_by_clause = ", ".join(group_parts)
        
        # Build SQL
        sql = f"""
            SELECT {select_clause}
            FROM {from_clause}
            {where_clause}
            GROUP BY {group_by_clause}
            ORDER BY {time_trunc}
            LIMIT {int(limit)}
        """.strip()
        
        # Execute query
        try:
            cursor = self.connection.cursor()
            if params:
                cursor.execute(sql, params)
            else:
                cursor.execute(sql)
            
            columns = [desc[0] for desc in cursor.description]
            rows = cursor.fetchall()
            cursor.close()
            
            data = [dict(zip(columns, row)) for row in rows]
            
            return AnalyticalResult(
                data=data,
                sql=sql,
                row_count=len(data),
                dimensions=["Period"] + additional_dims,
                measures=sanitized_measures,
                metadata={
                    "schema": schema,
                    "view": view_name,
                    "granularity": granularity.value,
                    "time_column": time_column
                }
            )
            
        except Exception as e:
            logger.error(f"Timeseries query failed: {e}")
            raise
    
    def hierarchy_drill(
        self,
        view_name: str,
        hierarchy_column: str,
        parent_column: str,
        schema: Optional[str] = None,
        parent_value: Optional[str] = None,
        level: Optional[int] = None,
        measures: Optional[Dict[str, Union[str, AggregationType]]] = None,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 1000,
    ) -> List[HierarchyNode]:
        """
        Navigate hierarchy with optional measure aggregation.
        
        Args:
            view_name: Name of the hierarchy view or table
            hierarchy_column: Column containing hierarchy node IDs
            parent_column: Column containing parent node IDs
            schema: Schema name
            parent_value: Parent node to drill into (None for root)
            level: Hierarchy level to retrieve
            measures: Optional measures to aggregate at each node
            filters: WHERE clause filters
            limit: Maximum nodes
        
        Returns:
            List of HierarchyNode objects
        
        Example:
            nodes = analytical.hierarchy_drill(
                view_name="CV_COST_CENTER_HIERARCHY",
                hierarchy_column="CostCenter",
                parent_column="ParentCostCenter",
                parent_value="1000",  # Drill into cost center 1000
                measures={"ActualCost": "SUM"}
            )
        """
        schema = schema or self.default_schema
        view_name = self._sanitize_name(view_name)
        schema = self._sanitize_name(schema)
        hierarchy_column = self._sanitize_name(hierarchy_column)
        parent_column = self._sanitize_name(parent_column)
        
        # Build SELECT clause
        select_parts = [
            f'"{hierarchy_column}" AS node_id',
            f'"{parent_column}" AS parent_id',
        ]
        
        # Add measures if provided
        sanitized_measures = []
        if measures:
            for measure, agg_type in measures.items():
                measure = self._sanitize_name(measure)
                sanitized_measures.append(measure)
                
                if isinstance(agg_type, str):
                    agg_type = AggregationType[agg_type.upper()]
                
                agg_sql = self.AGG_FUNCTIONS.get(agg_type, "SUM({})")
                select_parts.append(f'{agg_sql.format(f"{measure}")} AS "{measure}"')
        
        select_clause = ", ".join(select_parts)
        
        # Build WHERE clause for hierarchy navigation
        where_parts = []
        params = []
        
        if parent_value is not None:
            where_parts.append(f'"{parent_column}" = ?')
            params.append(parent_value)
        else:
            # Root level - parent is NULL or empty
            where_parts.append(f'("{parent_column}" IS NULL OR "{parent_column}" = \'\')')
        
        if level is not None:
            # Assumes HIERARCHY_LEVEL function is available
            where_parts.append(f'HIERARCHY_LEVEL("{hierarchy_column}") = ?')
            params.append(level)
        
        # Add custom filters
        if filters:
            filter_clause, filter_params = self._build_where_clause(filters, prefix="")
            if filter_clause:
                where_parts.append(filter_clause.replace("WHERE ", ""))
                params.extend(filter_params)
        
        where_clause = "WHERE " + " AND ".join(where_parts) if where_parts else ""
        
        # Build GROUP BY for measures
        group_clause = ""
        if measures:
            group_clause = f'GROUP BY "{hierarchy_column}", "{parent_column}"'
        
        # Build SQL
        sql = f"""
            SELECT {select_clause}
            FROM "{schema}"."{view_name}"
            {where_clause}
            {group_clause}
            ORDER BY "{hierarchy_column}"
            LIMIT {int(limit)}
        """.strip()
        
        # Execute query
        try:
            cursor = self.connection.cursor()
            if params:
                cursor.execute(sql, params)
            else:
                cursor.execute(sql)
            
            columns = [desc[0] for desc in cursor.description]
            rows = cursor.fetchall()
            cursor.close()
            
            # Convert to HierarchyNode objects
            nodes = []
            for row in rows:
                row_dict = dict(zip(columns, row))
                
                # Extract measure values as attributes
                attributes = {}
                for measure in sanitized_measures:
                    if measure in row_dict:
                        attributes[measure] = row_dict[measure]
                
                node = HierarchyNode(
                    id=str(row_dict.get("node_id", "")),
                    name=str(row_dict.get("node_id", "")),  # Could join with name table
                    parent_id=row_dict.get("parent_id"),
                    level=level or 0,
                    attributes=attributes
                )
                nodes.append(node)
            
            return nodes
            
        except Exception as e:
            logger.error(f"Hierarchy drill query failed: {e}")
            raise
    
    def _build_where_clause(
        self,
        filters: Optional[Dict[str, Any]],
        prefix: str = "WHERE ",
    ) -> Tuple[str, List]:
        """Build WHERE clause from filter dictionary."""
        if not filters:
            return "", []
        
        where_parts = []
        params = []
        
        for column, value in filters.items():
            column = self._sanitize_name(column)
            
            if isinstance(value, dict):
                # Range or comparison operators
                for op, val in value.items():
                    if op == "range":
                        where_parts.append(f'"{column}" BETWEEN ? AND ?')
                        params.extend([val.get("start"), val.get("end")])
                    elif op == "in":
                        placeholders = ", ".join(["?"] * len(val))
                        where_parts.append(f'"{column}" IN ({placeholders})')
                        params.extend([self._sanitize_value(v) for v in val])
                    elif op == "gt":
                        where_parts.append(f'"{column}" > ?')
                        params.append(self._sanitize_value(val))
                    elif op == "gte":
                        where_parts.append(f'"{column}" >= ?')
                        params.append(self._sanitize_value(val))
                    elif op == "lt":
                        where_parts.append(f'"{column}" < ?')
                        params.append(self._sanitize_value(val))
                    elif op == "lte":
                        where_parts.append(f'"{column}" <= ?')
                        params.append(self._sanitize_value(val))
                    elif op == "ne":
                        where_parts.append(f'"{column}" != ?')
                        params.append(self._sanitize_value(val))
                    elif op == "like":
                        where_parts.append(f'"{column}" LIKE ?')
                        params.append(self._sanitize_value(val))
            elif isinstance(value, (list, tuple)):
                # IN clause
                placeholders = ", ".join(["?"] * len(value))
                where_parts.append(f'"{column}" IN ({placeholders})')
                params.extend([self._sanitize_value(v) for v in value])
            elif value is None:
                where_parts.append(f'"{column}" IS NULL')
            else:
                # Simple equality
                where_parts.append(f'"{column}" = ?')
                params.append(self._sanitize_value(value))
        
        if where_parts:
            return prefix + " AND ".join(where_parts), params
        return "", []
    
    def get_view_metadata(
        self,
        view_name: str,
        schema: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Get metadata about a calculation view or table.
        
        Returns column information, types, and semantic hints.
        """
        schema = schema or self.default_schema
        view_name = self._sanitize_name(view_name)
        schema = self._sanitize_name(schema)
        
        sql = """
            SELECT 
                COLUMN_NAME,
                DATA_TYPE_NAME,
                LENGTH,
                SCALE,
                IS_NULLABLE,
                COMMENTS
            FROM SYS.TABLE_COLUMNS
            WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?
            ORDER BY POSITION
        """
        
        try:
            cursor = self.connection.cursor()
            cursor.execute(sql, (schema, view_name))
            
            columns = {}
            for row in cursor.fetchall():
                col_name = row[0]
                columns[col_name] = {
                    "data_type": row[1],
                    "length": row[2],
                    "scale": row[3],
                    "nullable": row[4] == "TRUE",
                    "comments": row[5],
                    "is_dimension": self._infer_dimension(col_name, row[1]),
                    "is_measure": self._infer_measure(col_name, row[1]),
                }
            cursor.close()
            
            return {
                "schema": schema,
                "view_name": view_name,
                "columns": columns,
                "dimensions": [c for c, m in columns.items() if m["is_dimension"]],
                "measures": [c for c, m in columns.items() if m["is_measure"]],
            }
            
        except Exception as e:
            logger.error(f"Failed to get view metadata: {e}")
            return {}
    
    @staticmethod
    def _infer_dimension(column_name: str, data_type: str) -> bool:
        """Infer if column is a dimension based on name/type patterns."""
        dimension_patterns = ["_ID", "_CODE", "_KEY", "_TYPE", "_NAME", "_TEXT"]
        dimension_types = ["NVARCHAR", "VARCHAR", "DATE", "TIMESTAMP"]
        
        col_upper = column_name.upper()
        return (
            any(col_upper.endswith(p) for p in dimension_patterns) or
            data_type in dimension_types
        )
    
    @staticmethod
    def _infer_measure(column_name: str, data_type: str) -> bool:
        """Infer if column is a measure based on name/type patterns."""
        measure_patterns = ["_AMOUNT", "_QUANTITY", "_VALUE", "_SUM", "_COUNT", "_TOTAL"]
        measure_types = ["DECIMAL", "INTEGER", "BIGINT", "DOUBLE", "FLOAT"]
        
        col_upper = column_name.upper()
        return (
            any(col_upper.endswith(p) for p in measure_patterns) or
            data_type in measure_types
        )