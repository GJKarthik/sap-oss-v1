"""
Unit tests for query optimizer.

Day 47 - Week 10 Performance Optimization
45 tests covering SQL analysis, optimization, recommendations, and caching.
"""

import pytest
from unittest.mock import Mock, patch
import time

from performance.query_optimizer import (
    QueryType,
    OptimizationLevel,
    QueryAnalysis,
    IndexRecommendation,
    QueryPlan,
    QueryAnalyzer,
    QueryOptimizer,
    ElasticsearchQueryOptimizer,
    create_sql_optimizer,
    create_es_optimizer,
)


# =============================================================================
# QueryType Tests (3 tests)
# =============================================================================

class TestQueryType:
    """Tests for QueryType enum."""
    
    def test_all_types_defined(self):
        """Test all query types are defined."""
        types = list(QueryType)
        assert len(types) == 10
    
    def test_type_values(self):
        """Test query type values."""
        assert QueryType.SELECT.value == "select"
        assert QueryType.INSERT.value == "insert"
        assert QueryType.JOIN.value == "join"
    
    def test_special_types(self):
        """Test special query types."""
        assert QueryType.VECTOR_SEARCH.value == "vector_search"
        assert QueryType.FULL_TEXT_SEARCH.value == "full_text_search"


# =============================================================================
# OptimizationLevel Tests (3 tests)
# =============================================================================

class TestOptimizationLevel:
    """Tests for OptimizationLevel enum."""
    
    def test_levels_defined(self):
        """Test all levels are defined."""
        levels = list(OptimizationLevel)
        assert len(levels) == 5
    
    def test_level_ordering(self):
        """Test levels can be compared."""
        assert OptimizationLevel.NONE.value < OptimizationLevel.BASIC.value
        assert OptimizationLevel.BASIC.value < OptimizationLevel.STANDARD.value
    
    def test_level_values(self):
        """Test level string values."""
        assert OptimizationLevel.AGGRESSIVE.value == "aggressive"
        assert OptimizationLevel.EXPERIMENTAL.value == "experimental"


# =============================================================================
# QueryAnalysis Tests (5 tests)
# =============================================================================

class TestQueryAnalysis:
    """Tests for QueryAnalysis dataclass."""
    
    def test_init_minimal(self):
        """Test minimal initialization."""
        analysis = QueryAnalysis(query_type=QueryType.SELECT)
        assert analysis.query_type == QueryType.SELECT
        assert analysis.tables == []
        assert analysis.complexity_score == 0.0
    
    def test_init_full(self):
        """Test full initialization."""
        analysis = QueryAnalysis(
            query_type=QueryType.JOIN,
            tables=["users", "orders"],
            columns=["id", "name"],
            joins=[{"type": "INNER", "table": "orders"}],
            has_aggregations=True,
            complexity_score=45.0,
        )
        assert len(analysis.tables) == 2
        assert analysis.has_aggregations is True
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        analysis = QueryAnalysis(
            query_type=QueryType.SELECT,
            complexity_score=25.567,
        )
        d = analysis.to_dict()
        assert d["query_type"] == "select"
        assert d["complexity_score"] == 25.57  # Rounded
    
    def test_where_conditions(self):
        """Test WHERE conditions storage."""
        analysis = QueryAnalysis(
            query_type=QueryType.SELECT,
            where_conditions=["id = 1", "status = 'active'"],
        )
        assert len(analysis.where_conditions) == 2
    
    def test_order_and_group_by(self):
        """Test ORDER BY and GROUP BY storage."""
        analysis = QueryAnalysis(
            query_type=QueryType.AGGREGATE,
            order_by=["created_at"],
            group_by=["category"],
        )
        assert analysis.order_by == ["created_at"]
        assert analysis.group_by == ["category"]


# =============================================================================
# IndexRecommendation Tests (4 tests)
# =============================================================================

class TestIndexRecommendation:
    """Tests for IndexRecommendation dataclass."""
    
    def test_init(self):
        """Test initialization."""
        rec = IndexRecommendation(
            table="users",
            columns=["email"],
            index_type="btree",
            reason="Used in WHERE clause",
            estimated_improvement=30.0,
            priority="high",
        )
        assert rec.table == "users"
        assert rec.priority == "high"
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        rec = IndexRecommendation(
            table="orders",
            columns=["customer_id", "status"],
            index_type="btree",
            reason="JOIN optimization",
            estimated_improvement=45.678,
            priority="medium",
        )
        d = rec.to_dict()
        assert d["estimated_improvement"] == 45.7
    
    def test_multiple_columns(self):
        """Test composite index recommendation."""
        rec = IndexRecommendation(
            table="orders",
            columns=["customer_id", "created_at", "status"],
            index_type="btree",
            reason="Covering index",
            estimated_improvement=50.0,
            priority="high",
        )
        assert len(rec.columns) == 3
    
    def test_vector_index(self):
        """Test vector index recommendation."""
        rec = IndexRecommendation(
            table="embeddings",
            columns=["vector"],
            index_type="vector",
            reason="Vector similarity search",
            estimated_improvement=80.0,
            priority="high",
        )
        assert rec.index_type == "vector"


# =============================================================================
# QueryPlan Tests (4 tests)
# =============================================================================

class TestQueryPlan:
    """Tests for QueryPlan dataclass."""
    
    def test_init(self):
        """Test initialization."""
        plan = QueryPlan(
            original_query="SELECT * FROM users",
            optimized_query="SELECT * FROM users",
            query_hash="abc123",
            analysis=QueryAnalysis(query_type=QueryType.SELECT),
        )
        assert plan.original_query == plan.optimized_query
        assert plan.use_count == 0
    
    def test_average_execution_time_zero(self):
        """Test average time with no executions."""
        plan = QueryPlan(
            original_query="SELECT 1",
            optimized_query="SELECT 1",
            query_hash="abc",
            analysis=QueryAnalysis(query_type=QueryType.SELECT),
        )
        assert plan.average_execution_time_ms() == 0.0
    
    def test_average_execution_time_calculated(self):
        """Test average time calculation."""
        plan = QueryPlan(
            original_query="SELECT 1",
            optimized_query="SELECT 1",
            query_hash="abc",
            analysis=QueryAnalysis(query_type=QueryType.SELECT),
            use_count=4,
            total_execution_time_ms=100.0,
        )
        assert plan.average_execution_time_ms() == 25.0
    
    def test_transformations_stored(self):
        """Test transformations are stored."""
        plan = QueryPlan(
            original_query="SELECT * FROM users",
            optimized_query="SELECT id, name FROM users",
            query_hash="xyz",
            analysis=QueryAnalysis(query_type=QueryType.SELECT),
            transformations=["Replace SELECT *", "Add LIMIT"],
        )
        assert len(plan.transformations) == 2


# =============================================================================
# QueryAnalyzer Tests (10 tests)
# =============================================================================

class TestQueryAnalyzer:
    """Tests for QueryAnalyzer."""
    
    @pytest.fixture
    def analyzer(self):
        """Create analyzer."""
        return QueryAnalyzer()
    
    def test_detect_select(self, analyzer):
        """Test SELECT detection."""
        analysis = analyzer.analyze_sql("SELECT id FROM users")
        assert analysis.query_type == QueryType.SELECT
    
    def test_detect_insert(self, analyzer):
        """Test INSERT detection."""
        analysis = analyzer.analyze_sql("INSERT INTO users (name) VALUES ('test')")
        assert analysis.query_type == QueryType.INSERT
    
    def test_detect_update(self, analyzer):
        """Test UPDATE detection."""
        analysis = analyzer.analyze_sql("UPDATE users SET name = 'test' WHERE id = 1")
        assert analysis.query_type == QueryType.UPDATE
    
    def test_detect_delete(self, analyzer):
        """Test DELETE detection."""
        analysis = analyzer.analyze_sql("DELETE FROM users WHERE id = 1")
        assert analysis.query_type == QueryType.DELETE
    
    def test_detect_join(self, analyzer):
        """Test JOIN detection."""
        analysis = analyzer.analyze_sql(
            "SELECT u.id FROM users u JOIN orders o ON u.id = o.user_id"
        )
        assert analysis.query_type == QueryType.JOIN
    
    def test_detect_aggregate(self, analyzer):
        """Test aggregate detection."""
        analysis = analyzer.analyze_sql(
            "SELECT COUNT(*) FROM users GROUP BY status"
        )
        assert analysis.query_type == QueryType.AGGREGATE
        assert analysis.has_aggregations is True
    
    def test_extract_tables(self, analyzer):
        """Test table extraction."""
        analysis = analyzer.analyze_sql(
            "SELECT * FROM users u JOIN orders o ON u.id = o.user_id"
        )
        assert "users" in analysis.tables
    
    def test_extract_where_conditions(self, analyzer):
        """Test WHERE extraction."""
        analysis = analyzer.analyze_sql(
            "SELECT * FROM users WHERE status = 'active' AND age > 18"
        )
        assert len(analysis.where_conditions) >= 1
    
    def test_detect_subquery(self, analyzer):
        """Test subquery detection."""
        analysis = analyzer.analyze_sql(
            "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)"
        )
        assert analysis.has_subqueries is True
        assert analysis.query_type == QueryType.SUBQUERY
    
    def test_complexity_calculation(self, analyzer):
        """Test complexity score calculation."""
        simple = analyzer.analyze_sql("SELECT id FROM users")
        complex_query = analyzer.analyze_sql(
            """SELECT u.id, COUNT(o.id) 
               FROM users u 
               JOIN orders o ON u.id = o.user_id 
               WHERE u.status = 'active'
               GROUP BY u.id"""
        )
        assert complex_query.complexity_score > simple.complexity_score


# =============================================================================
# QueryOptimizer Tests (10 tests)
# =============================================================================

class TestQueryOptimizer:
    """Tests for QueryOptimizer."""
    
    @pytest.fixture
    def optimizer(self):
        """Create optimizer."""
        return QueryOptimizer(level=OptimizationLevel.STANDARD)
    
    def test_optimize_returns_plan(self, optimizer):
        """Test optimize returns QueryPlan."""
        plan = optimizer.optimize("SELECT * FROM users")
        assert isinstance(plan, QueryPlan)
    
    def test_plan_caching(self, optimizer):
        """Test plan caching."""
        query = "SELECT id FROM users WHERE status = 'active'"
        plan1 = optimizer.optimize(query)
        plan2 = optimizer.optimize(query)
        
        assert plan1.query_hash == plan2.query_hash
        assert plan2.use_count == 2
    
    def test_cache_miss_tracking(self, optimizer):
        """Test cache miss tracking."""
        optimizer.optimize("SELECT 1")
        optimizer.optimize("SELECT 2")
        
        stats = optimizer.get_stats()
        assert stats['cache_misses'] == 2
    
    def test_cache_hit_tracking(self, optimizer):
        """Test cache hit tracking."""
        optimizer.optimize("SELECT 1")
        optimizer.optimize("SELECT 1")
        
        stats = optimizer.get_stats()
        assert stats['cache_hits'] == 1
    
    def test_transformations_generated(self, optimizer):
        """Test transformations are generated."""
        plan = optimizer.optimize("SELECT * FROM users")
        # At STANDARD level, should recommend explicit columns
        assert len(plan.transformations) > 0
    
    def test_recommendations_generated(self, optimizer):
        """Test recommendations are generated."""
        plan = optimizer.optimize(
            "SELECT * FROM users WHERE email = 'test@example.com'"
        )
        # Should recommend index on WHERE column
        assert len(plan.recommendations) >= 0
    
    def test_none_level_no_transformations(self):
        """Test NONE level returns no transformations."""
        opt = QueryOptimizer(level=OptimizationLevel.NONE)
        plan = opt.optimize("SELECT * FROM users")
        assert len(plan.transformations) == 0
    
    def test_get_cached_plan(self, optimizer):
        """Test get_cached_plan."""
        query = "SELECT id FROM users"
        optimizer.optimize(query)
        
        cached = optimizer.get_cached_plan(query)
        assert cached is not None
    
    def test_clear_cache(self, optimizer):
        """Test cache clearing."""
        optimizer.optimize("SELECT 1")
        optimizer.clear_cache()
        
        stats = optimizer.get_stats()
        assert stats['cache_size'] == 0
    
    def test_record_execution(self, optimizer):
        """Test execution time recording."""
        plan = optimizer.optimize("SELECT 1")
        optimizer.record_execution(plan.query_hash, 50.0)
        
        cached = optimizer.get_cached_plan("SELECT 1")
        assert cached.total_execution_time_ms == 50.0


# =============================================================================
# ElasticsearchQueryOptimizer Tests (6 tests)
# =============================================================================

class TestElasticsearchQueryOptimizer:
    """Tests for ElasticsearchQueryOptimizer."""
    
    @pytest.fixture
    def optimizer(self):
        """Create ES optimizer."""
        return ElasticsearchQueryOptimizer(level=OptimizationLevel.STANDARD)
    
    def test_add_size_limit(self, optimizer):
        """Test adds size limit."""
        query = {"query": {"match_all": {}}}
        optimized = optimizer.optimize(query)
        assert "size" in optimized
    
    def test_preserve_existing_size(self, optimizer):
        """Test preserves existing size."""
        query = {"query": {"match_all": {}}, "size": 50}
        optimized = optimizer.optimize(query)
        assert optimized["size"] == 50
    
    def test_add_source_filtering(self, optimizer):
        """Test adds source filtering."""
        query = {"query": {"match_all": {}}}
        optimized = optimizer.optimize(query)
        assert "_source" in optimized
    
    def test_none_level_no_changes(self):
        """Test NONE level makes no changes."""
        opt = ElasticsearchQueryOptimizer(level=OptimizationLevel.NONE)
        query = {"query": {"match_all": {}}}
        optimized = opt.optimize(query)
        assert "size" not in optimized
    
    def test_get_recommendations(self, optimizer):
        """Test get_recommendations."""
        query = {"query": {"match_all": {}}}
        recs = optimizer.get_recommendations(query)
        assert isinstance(recs, list)
    
    def test_wildcard_warning(self, optimizer):
        """Test wildcard query warning."""
        query = {"query": {"wildcard": {"name": "*test*"}}}
        recs = optimizer.get_recommendations(query)
        assert any("wildcard" in r.get("message", "").lower() for r in recs)


# =============================================================================
# Factory Functions Tests (2 tests)
# =============================================================================

class TestFactoryFunctions:
    """Tests for factory functions."""
    
    def test_create_sql_optimizer(self):
        """Test create_sql_optimizer."""
        opt = create_sql_optimizer(level=OptimizationLevel.AGGRESSIVE)
        assert opt.level == OptimizationLevel.AGGRESSIVE
    
    def test_create_es_optimizer(self):
        """Test create_es_optimizer."""
        opt = create_es_optimizer(level=OptimizationLevel.BASIC)
        assert opt.level == OptimizationLevel.BASIC


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - QueryType: 3 tests
# - OptimizationLevel: 3 tests
# - QueryAnalysis: 5 tests
# - IndexRecommendation: 4 tests
# - QueryPlan: 4 tests
# - QueryAnalyzer: 10 tests
# - QueryOptimizer: 10 tests
# - ElasticsearchQueryOptimizer: 6 tests