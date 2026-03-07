"""
Query Optimizer for High-Performance Database Operations.

Day 47 Implementation - Week 10 Performance Optimization
Provides query analysis, optimization, and plan caching for HANA and Elasticsearch.
"""

import asyncio
import logging
import time
import hashlib
import re
from typing import Optional, Dict, Any, List, Set, Tuple
from dataclasses import dataclass, field
from enum import Enum
from collections import OrderedDict
from abc import ABC, abstractmethod

logger = logging.getLogger(__name__)


# =============================================================================
# Query Types and Analysis
# =============================================================================

class QueryType(str, Enum):
    """Types of database queries."""
    SELECT = "select"
    INSERT = "insert"
    UPDATE = "update"
    DELETE = "delete"
    AGGREGATE = "aggregate"
    JOIN = "join"
    SUBQUERY = "subquery"
    VECTOR_SEARCH = "vector_search"
    FULL_TEXT_SEARCH = "full_text_search"
    UNKNOWN = "unknown"


class OptimizationLevel(str, Enum):
    """Optimization aggressiveness levels."""
    NONE = "none"
    BASIC = "basic"
    STANDARD = "standard"
    AGGRESSIVE = "aggressive"
    EXPERIMENTAL = "experimental"


# =============================================================================
# Query Analysis Results
# =============================================================================

@dataclass
class QueryAnalysis:
    """Results of query analysis."""
    query_type: QueryType
    tables: List[str] = field(default_factory=list)
    columns: List[str] = field(default_factory=list)
    joins: List[Dict[str, str]] = field(default_factory=list)
    where_conditions: List[str] = field(default_factory=list)
    order_by: List[str] = field(default_factory=list)
    group_by: List[str] = field(default_factory=list)
    has_aggregations: bool = False
    has_subqueries: bool = False
    estimated_rows: int = 0
    complexity_score: float = 0.0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "query_type": self.query_type.value,
            "tables": self.tables,
            "columns": self.columns,
            "joins": self.joins,
            "where_conditions": self.where_conditions,
            "order_by": self.order_by,
            "group_by": self.group_by,
            "has_aggregations": self.has_aggregations,
            "has_subqueries": self.has_subqueries,
            "estimated_rows": self.estimated_rows,
            "complexity_score": round(self.complexity_score, 2),
        }


@dataclass
class IndexRecommendation:
    """Index recommendation based on query analysis."""
    table: str
    columns: List[str]
    index_type: str  # btree, hash, fulltext, vector
    reason: str
    estimated_improvement: float  # percentage
    priority: str  # high, medium, low
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "table": self.table,
            "columns": self.columns,
            "index_type": self.index_type,
            "reason": self.reason,
            "estimated_improvement": round(self.estimated_improvement, 1),
            "priority": self.priority,
        }


@dataclass
class QueryPlan:
    """Optimized query execution plan."""
    original_query: str
    optimized_query: str
    query_hash: str
    analysis: QueryAnalysis
    recommendations: List[IndexRecommendation] = field(default_factory=list)
    transformations: List[str] = field(default_factory=list)
    estimated_cost: float = 0.0
    created_at: float = field(default_factory=time.time)
    use_count: int = 0
    total_execution_time_ms: float = 0.0
    
    def average_execution_time_ms(self) -> float:
        """Get average execution time."""
        if self.use_count == 0:
            return 0.0
        return self.total_execution_time_ms / self.use_count


# =============================================================================
# Query Analyzer
# =============================================================================

class QueryAnalyzer:
    """
    Analyzes SQL and Elasticsearch queries for optimization opportunities.
    """
    
    # SQL keywords for detection
    AGGREGATE_FUNCTIONS = {'COUNT', 'SUM', 'AVG', 'MIN', 'MAX', 'GROUP_CONCAT'}
    JOIN_KEYWORDS = {'JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'INNER JOIN', 'OUTER JOIN', 'CROSS JOIN'}
    
    def __init__(self):
        self._patterns = self._compile_patterns()
    
    def _compile_patterns(self) -> Dict[str, re.Pattern]:
        """Compile regex patterns for query analysis."""
        return {
            'select': re.compile(r'\bSELECT\b', re.IGNORECASE),
            'insert': re.compile(r'\bINSERT\b', re.IGNORECASE),
            'update': re.compile(r'\bUPDATE\b', re.IGNORECASE),
            'delete': re.compile(r'\bDELETE\b', re.IGNORECASE),
            'from': re.compile(r'\bFROM\s+(\w+)', re.IGNORECASE),
            'join': re.compile(r'\b(\w+\s+)?JOIN\s+(\w+)', re.IGNORECASE),
            'where': re.compile(r'\bWHERE\s+(.+?)(?=\bORDER BY\b|\bGROUP BY\b|\bLIMIT\b|$)', re.IGNORECASE | re.DOTALL),
            'order_by': re.compile(r'\bORDER BY\s+(.+?)(?=\bLIMIT\b|$)', re.IGNORECASE),
            'group_by': re.compile(r'\bGROUP BY\s+(.+?)(?=\bHAVING\b|\bORDER BY\b|\bLIMIT\b|$)', re.IGNORECASE),
            'subquery': re.compile(r'\(\s*SELECT\b', re.IGNORECASE),
            'columns': re.compile(r'\bSELECT\s+(.+?)\s+FROM\b', re.IGNORECASE | re.DOTALL),
            'aggregate': re.compile(r'\b(COUNT|SUM|AVG|MIN|MAX)\s*\(', re.IGNORECASE),
        }
    
    def analyze_sql(self, query: str) -> QueryAnalysis:
        """Analyze SQL query."""
        query = query.strip()
        
        # Determine query type
        query_type = self._detect_query_type(query)
        
        # Extract components
        tables = self._extract_tables(query)
        columns = self._extract_columns(query)
        joins = self._extract_joins(query)
        where_conditions = self._extract_where_conditions(query)
        order_by = self._extract_order_by(query)
        group_by = self._extract_group_by(query)
        
        # Detect features
        has_aggregations = bool(self._patterns['aggregate'].search(query))
        has_subqueries = bool(self._patterns['subquery'].search(query))
        
        # Calculate complexity
        complexity_score = self._calculate_complexity(
            len(tables), len(joins), has_subqueries, has_aggregations
        )
        
        return QueryAnalysis(
            query_type=query_type,
            tables=tables,
            columns=columns,
            joins=joins,
            where_conditions=where_conditions,
            order_by=order_by,
            group_by=group_by,
            has_aggregations=has_aggregations,
            has_subqueries=has_subqueries,
            complexity_score=complexity_score,
        )
    
    def _detect_query_type(self, query: str) -> QueryType:
        """Detect the type of SQL query."""
        if self._patterns['select'].search(query):
            if self._patterns['aggregate'].search(query):
                return QueryType.AGGREGATE
            if self._patterns['join'].search(query):
                return QueryType.JOIN
            if self._patterns['subquery'].search(query):
                return QueryType.SUBQUERY
            return QueryType.SELECT
        elif self._patterns['insert'].search(query):
            return QueryType.INSERT
        elif self._patterns['update'].search(query):
            return QueryType.UPDATE
        elif self._patterns['delete'].search(query):
            return QueryType.DELETE
        return QueryType.UNKNOWN
    
    def _extract_tables(self, query: str) -> List[str]:
        """Extract table names from query."""
        tables = []
        
        # FROM clause
        from_matches = self._patterns['from'].findall(query)
        tables.extend(from_matches)
        
        # JOIN clauses
        join_matches = self._patterns['join'].findall(query)
        for match in join_matches:
            if isinstance(match, tuple):
                tables.append(match[1])  # table name is second group
            else:
                tables.append(match)
        
        return list(set(tables))
    
    def _extract_columns(self, query: str) -> List[str]:
        """Extract column names from SELECT clause."""
        columns = []
        match = self._patterns['columns'].search(query)
        if match:
            cols_str = match.group(1)
            if cols_str.strip() != '*':
                # Split by comma, clean up
                for col in cols_str.split(','):
                    col = col.strip()
                    # Remove aliases
                    if ' AS ' in col.upper():
                        col = col.split()[0]
                    columns.append(col)
        return columns
    
    def _extract_joins(self, query: str) -> List[Dict[str, str]]:
        """Extract JOIN information."""
        joins = []
        join_matches = self._patterns['join'].findall(query)
        for match in join_matches:
            if isinstance(match, tuple):
                join_type = match[0].strip() if match[0] else 'INNER'
                table = match[1]
            else:
                join_type = 'INNER'
                table = match
            joins.append({'type': join_type, 'table': table})
        return joins
    
    def _extract_where_conditions(self, query: str) -> List[str]:
        """Extract WHERE conditions."""
        conditions = []
        match = self._patterns['where'].search(query)
        if match:
            where_str = match.group(1)
            # Split by AND/OR
            parts = re.split(r'\bAND\b|\bOR\b', where_str, flags=re.IGNORECASE)
            conditions = [p.strip() for p in parts if p.strip()]
        return conditions
    
    def _extract_order_by(self, query: str) -> List[str]:
        """Extract ORDER BY columns."""
        columns = []
        match = self._patterns['order_by'].search(query)
        if match:
            order_str = match.group(1)
            for col in order_str.split(','):
                col = col.strip().split()[0]  # Remove ASC/DESC
                columns.append(col)
        return columns
    
    def _extract_group_by(self, query: str) -> List[str]:
        """Extract GROUP BY columns."""
        columns = []
        match = self._patterns['group_by'].search(query)
        if match:
            group_str = match.group(1)
            for col in group_str.split(','):
                columns.append(col.strip())
        return columns
    
    def _calculate_complexity(
        self,
        table_count: int,
        join_count: int,
        has_subqueries: bool,
        has_aggregations: bool,
    ) -> float:
        """Calculate query complexity score (0-100)."""
        score = 0.0
        
        # Base complexity from tables
        score += min(table_count * 10, 30)
        
        # Joins add complexity
        score += min(join_count * 15, 40)
        
        # Subqueries are expensive
        if has_subqueries:
            score += 20
        
        # Aggregations add overhead
        if has_aggregations:
            score += 10
        
        return min(score, 100)
    
    def analyze_elasticsearch(self, query: Dict[str, Any]) -> QueryAnalysis:
        """Analyze Elasticsearch query."""
        query_type = QueryType.FULL_TEXT_SEARCH
        
        # Check for vector search
        if 'script_score' in str(query) or 'knn' in query:
            query_type = QueryType.VECTOR_SEARCH
        
        # Check for aggregations
        has_aggregations = 'aggs' in query or 'aggregations' in query
        if has_aggregations:
            query_type = QueryType.AGGREGATE
        
        # Calculate complexity
        complexity = 10.0  # Base
        if has_aggregations:
            complexity += 20
        if 'nested' in str(query):
            complexity += 15
        if 'bool' in str(query):
            complexity += 5
        
        return QueryAnalysis(
            query_type=query_type,
            tables=[query.get('index', 'unknown')],
            has_aggregations=has_aggregations,
            complexity_score=complexity,
        )


# =============================================================================
# Query Optimizer
# =============================================================================

class QueryOptimizer:
    """
    Optimizes queries for better performance.
    
    Features:
    - Query rewriting
    - Index recommendations
    - Plan caching
    - Performance tracking
    """
    
    def __init__(
        self,
        level: OptimizationLevel = OptimizationLevel.STANDARD,
        cache_size: int = 1000,
    ):
        self.level = level
        self.analyzer = QueryAnalyzer()
        self._plan_cache: OrderedDict[str, QueryPlan] = OrderedDict()
        self._cache_size = cache_size
        self._stats = {
            'queries_analyzed': 0,
            'queries_optimized': 0,
            'cache_hits': 0,
            'cache_misses': 0,
        }
    
    def _get_query_hash(self, query: str) -> str:
        """Generate hash for query."""
        # Normalize whitespace
        normalized = ' '.join(query.split())
        return hashlib.md5(normalized.encode()).hexdigest()
    
    def optimize(self, query: str) -> QueryPlan:
        """
        Optimize a SQL query.
        
        Args:
            query: SQL query string
            
        Returns:
            QueryPlan with optimizations
        """
        self._stats['queries_analyzed'] += 1
        query_hash = self._get_query_hash(query)
        
        # Check cache
        if query_hash in self._plan_cache:
            self._stats['cache_hits'] += 1
            plan = self._plan_cache[query_hash]
            plan.use_count += 1
            # Move to end (LRU)
            self._plan_cache.move_to_end(query_hash)
            return plan
        
        self._stats['cache_misses'] += 1
        
        # Analyze query
        analysis = self.analyzer.analyze_sql(query)
        
        # Generate optimizations
        optimized_query, transformations = self._apply_optimizations(query, analysis)
        
        # Generate recommendations
        recommendations = self._generate_recommendations(analysis)
        
        # Estimate cost
        estimated_cost = self._estimate_cost(analysis)
        
        # Create plan
        plan = QueryPlan(
            original_query=query,
            optimized_query=optimized_query,
            query_hash=query_hash,
            analysis=analysis,
            recommendations=recommendations,
            transformations=transformations,
            estimated_cost=estimated_cost,
            use_count=1,
        )
        
        # Cache plan
        self._cache_plan(query_hash, plan)
        
        if optimized_query != query:
            self._stats['queries_optimized'] += 1
        
        return plan
    
    def _apply_optimizations(
        self,
        query: str,
        analysis: QueryAnalysis,
    ) -> Tuple[str, List[str]]:
        """Apply optimization transformations to query."""
        optimized = query
        transformations = []
        
        if self.level == OptimizationLevel.NONE:
            return optimized, transformations
        
        # Basic: SELECT * to explicit columns
        if self.level.value >= OptimizationLevel.BASIC.value:
            if 'SELECT *' in query.upper():
                transformations.append("Recommend: Replace SELECT * with explicit columns")
        
        # Standard: Add LIMIT if missing
        if self.level.value >= OptimizationLevel.STANDARD.value:
            if analysis.query_type == QueryType.SELECT and 'LIMIT' not in query.upper():
                transformations.append("Recommend: Add LIMIT clause to prevent full table scans")
        
        # Standard: Optimize ORDER BY with LIMIT
        if self.level.value >= OptimizationLevel.STANDARD.value:
            if analysis.order_by and 'LIMIT' not in query.upper():
                transformations.append("Recommend: Add LIMIT when using ORDER BY")
        
        # Aggressive: Suggest covering indexes
        if self.level.value >= OptimizationLevel.AGGRESSIVE.value:
            if len(analysis.columns) <= 5 and analysis.where_conditions:
                transformations.append("Consider: Covering index for frequently accessed columns")
        
        # Aggressive: Subquery to JOIN transformation
        if self.level.value >= OptimizationLevel.AGGRESSIVE.value:
            if analysis.has_subqueries:
                transformations.append("Consider: Rewrite subquery as JOIN for better performance")
        
        return optimized, transformations
    
    def _generate_recommendations(
        self,
        analysis: QueryAnalysis,
    ) -> List[IndexRecommendation]:
        """Generate index recommendations based on query analysis."""
        recommendations = []
        
        # Recommend indexes for WHERE conditions
        for table in analysis.tables:
            if analysis.where_conditions:
                # Extract column names from conditions
                columns = []
                for cond in analysis.where_conditions:
                    # Simple extraction - find column names
                    parts = re.split(r'[=<>!]+|\bLIKE\b|\bIN\b|\bBETWEEN\b', cond, flags=re.IGNORECASE)
                    if parts:
                        col = parts[0].strip()
                        if col and not col.replace('.', '').isdigit():
                            columns.append(col)
                
                if columns:
                    recommendations.append(IndexRecommendation(
                        table=table,
                        columns=columns[:3],  # Max 3 columns
                        index_type="btree",
                        reason="Frequently used in WHERE clause",
                        estimated_improvement=30.0,
                        priority="high",
                    ))
        
        # Recommend indexes for JOIN columns
        for join in analysis.joins:
            recommendations.append(IndexRecommendation(
                table=join['table'],
                columns=["<join_column>"],  # Would need deeper analysis
                index_type="btree",
                reason="Used in JOIN operation",
                estimated_improvement=40.0,
                priority="high",
            ))
        
        # Recommend indexes for ORDER BY
        if analysis.order_by:
            for table in analysis.tables[:1]:  # Primary table
                recommendations.append(IndexRecommendation(
                    table=table,
                    columns=analysis.order_by,
                    index_type="btree",
                    reason="Used in ORDER BY clause",
                    estimated_improvement=25.0,
                    priority="medium",
                ))
        
        # Recommend indexes for GROUP BY
        if analysis.group_by:
            for table in analysis.tables[:1]:
                recommendations.append(IndexRecommendation(
                    table=table,
                    columns=analysis.group_by,
                    index_type="btree",
                    reason="Used in GROUP BY clause",
                    estimated_improvement=20.0,
                    priority="medium",
                ))
        
        return recommendations
    
    def _estimate_cost(self, analysis: QueryAnalysis) -> float:
        """Estimate query execution cost."""
        cost = 1.0
        
        # Table scans
        cost += len(analysis.tables) * 10
        
        # Joins are expensive
        cost += len(analysis.joins) * 25
        
        # Subqueries
        if analysis.has_subqueries:
            cost *= 2
        
        # Aggregations
        if analysis.has_aggregations:
            cost += 15
        
        # ORDER BY without index
        if analysis.order_by:
            cost += 10
        
        return cost
    
    def _cache_plan(self, query_hash: str, plan: QueryPlan):
        """Cache query plan with LRU eviction."""
        if len(self._plan_cache) >= self._cache_size:
            # Remove oldest
            self._plan_cache.popitem(last=False)
        
        self._plan_cache[query_hash] = plan
    
    def record_execution(self, query_hash: str, execution_time_ms: float):
        """Record execution time for a cached plan."""
        if query_hash in self._plan_cache:
            plan = self._plan_cache[query_hash]
            plan.total_execution_time_ms += execution_time_ms
    
    def get_cached_plan(self, query: str) -> Optional[QueryPlan]:
        """Get cached plan for a query."""
        query_hash = self._get_query_hash(query)
        return self._plan_cache.get(query_hash)
    
    def get_stats(self) -> Dict[str, Any]:
        """Get optimizer statistics."""
        hit_rate = 0.0
        total = self._stats['cache_hits'] + self._stats['cache_misses']
        if total > 0:
            hit_rate = self._stats['cache_hits'] / total * 100
        
        return {
            **self._stats,
            'cache_size': len(self._plan_cache),
            'cache_hit_rate': round(hit_rate, 2),
        }
    
    def clear_cache(self):
        """Clear the plan cache."""
        self._plan_cache.clear()


# =============================================================================
# Elasticsearch Query Optimizer
# =============================================================================

class ElasticsearchQueryOptimizer:
    """
    Optimizes Elasticsearch queries.
    """
    
    def __init__(self, level: OptimizationLevel = OptimizationLevel.STANDARD):
        self.level = level
        self.analyzer = QueryAnalyzer()
    
    def optimize(self, query: Dict[str, Any]) -> Dict[str, Any]:
        """
        Optimize an Elasticsearch query.
        
        Args:
            query: Elasticsearch query DSL
            
        Returns:
            Optimized query
        """
        optimized = query.copy()
        
        if self.level == OptimizationLevel.NONE:
            return optimized
        
        # Basic: Add size limit if missing
        if self.level.value >= OptimizationLevel.BASIC.value:
            if 'size' not in optimized:
                optimized['size'] = 100
        
        # Standard: Optimize bool queries
        if self.level.value >= OptimizationLevel.STANDARD.value:
            optimized = self._optimize_bool_query(optimized)
        
        # Standard: Add source filtering
        if self.level.value >= OptimizationLevel.STANDARD.value:
            if '_source' not in optimized:
                optimized['_source'] = True  # Default to include
        
        # Aggressive: Optimize aggregations
        if self.level.value >= OptimizationLevel.AGGRESSIVE.value:
            optimized = self._optimize_aggregations(optimized)
        
        return optimized
    
    def _optimize_bool_query(self, query: Dict[str, Any]) -> Dict[str, Any]:
        """Optimize bool query structure."""
        if 'query' not in query:
            return query
        
        q = query['query']
        if 'bool' not in q:
            return query
        
        bool_query = q['bool']
        
        # Move filter-able must clauses to filter
        if 'must' in bool_query and 'filter' not in bool_query:
            must = bool_query['must']
            filterable = []
            remaining = []
            
            for clause in (must if isinstance(must, list) else [must]):
                # Term and range queries are good for filter context
                if isinstance(clause, dict):
                    if any(k in clause for k in ['term', 'terms', 'range', 'exists']):
                        filterable.append(clause)
                    else:
                        remaining.append(clause)
            
            if filterable:
                bool_query['filter'] = filterable
                bool_query['must'] = remaining if remaining else []
                if not bool_query['must']:
                    del bool_query['must']
        
        return query
    
    def _optimize_aggregations(self, query: Dict[str, Any]) -> Dict[str, Any]:
        """Optimize aggregation queries."""
        if 'aggs' not in query and 'aggregations' not in query:
            return query
        
        aggs_key = 'aggs' if 'aggs' in query else 'aggregations'
        
        # If only aggregations needed, set size to 0
        if aggs_key in query and 'query' not in query:
            query['size'] = 0
        
        return query
    
    def get_recommendations(self, query: Dict[str, Any]) -> List[Dict[str, str]]:
        """Get optimization recommendations for query."""
        recommendations = []
        
        # Check for missing size
        if 'size' not in query:
            recommendations.append({
                'type': 'performance',
                'message': 'Add explicit size to limit result set',
                'priority': 'high',
            })
        
        # Check for SELECT * equivalent
        if '_source' not in query:
            recommendations.append({
                'type': 'performance',
                'message': 'Use _source filtering to reduce data transfer',
                'priority': 'medium',
            })
        
        # Check for expensive operations
        if 'script' in str(query):
            recommendations.append({
                'type': 'warning',
                'message': 'Scripts are expensive - consider using stored scripts',
                'priority': 'medium',
            })
        
        # Check for wildcards
        if '*' in str(query.get('query', {})):
            recommendations.append({
                'type': 'warning',
                'message': 'Wildcard queries can be slow - consider ngram analysis',
                'priority': 'low',
            })
        
        return recommendations


# =============================================================================
# Factory Functions
# =============================================================================

def create_sql_optimizer(
    level: OptimizationLevel = OptimizationLevel.STANDARD,
    cache_size: int = 1000,
) -> QueryOptimizer:
    """Create SQL query optimizer."""
    return QueryOptimizer(level=level, cache_size=cache_size)


def create_es_optimizer(
    level: OptimizationLevel = OptimizationLevel.STANDARD,
) -> ElasticsearchQueryOptimizer:
    """Create Elasticsearch query optimizer."""
    return ElasticsearchQueryOptimizer(level=level)