"""
Unit Tests for HANA and Elasticsearch Connectors

Tests connection pooling, circuit breakers, and query execution.
"""

import pytest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from config.settings import HANAConfig, ElasticsearchConfig
from connectors.hana import HANAConnector, CircuitBreaker, ConnectionStats
from connectors.elasticsearch import ElasticsearchClient, ESStats


class TestCircuitBreaker:
    """Tests for circuit breaker pattern"""
    
    def test_starts_closed(self):
        """Test circuit breaker starts in closed state"""
        cb = CircuitBreaker(failure_threshold=3)
        assert cb.state == "closed"
        assert cb.can_execute() == True
    
    def test_opens_after_threshold(self):
        """Test circuit opens after failure threshold"""
        cb = CircuitBreaker(failure_threshold=3)
        
        cb.record_failure()
        cb.record_failure()
        assert cb.state == "closed"
        
        cb.record_failure()
        assert cb.state == "open"
    
    def test_blocks_when_open(self):
        """Test requests blocked when circuit is open"""
        cb = CircuitBreaker(failure_threshold=2, reset_timeout=60)
        
        cb.record_failure()
        cb.record_failure()
        
        assert cb.state == "open"
        assert cb.can_execute() == False
    
    def test_success_resets(self):
        """Test success resets the circuit"""
        cb = CircuitBreaker(failure_threshold=3)
        
        cb.record_failure()
        cb.record_failure()
        cb.record_success()
        
        assert cb.state == "closed"
        assert cb.failure_count == 0


class TestConnectionStats:
    """Tests for connection statistics"""
    
    def test_default_values(self):
        """Test default statistics values"""
        stats = ConnectionStats()
        
        assert stats.total_connections == 0
        assert stats.active_connections == 0
        assert stats.failed_connections == 0
        assert stats.total_queries == 0


class TestHANAConnector:
    """Tests for HANA connector"""
    
    def test_init_without_config(self):
        """Test initialization with unconfigured HANA"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        assert connector._connected == False
    
    def test_connect_without_credentials(self):
        """Test connect fails without credentials"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        result = connector.connect()
        
        assert result == False
    
    def test_simulation_mode(self):
        """Test simulation mode when hdbcli unavailable"""
        config = HANAConfig(
            host="test.hana.cloud.sap",
            user="admin",
            password="secret"
        )
        connector = HANAConnector(config)
        
        # Should enter simulation mode
        connector._connected = True
        result = connector.execute("SELECT * FROM TABLES")
        
        if not connector._hdbcli_available:
            assert "simulated" in result or "error" not in result
    
    def test_hana_to_odata_type_mapping(self):
        """Test HANA to OData type mapping"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        assert connector._map_hana_to_odata_type("NVARCHAR") == "Edm.String"
        assert connector._map_hana_to_odata_type("INTEGER") == "Edm.Int32"
        assert connector._map_hana_to_odata_type("DECIMAL") == "Edm.Decimal"
        assert connector._map_hana_to_odata_type("BOOLEAN") == "Edm.Boolean"
        assert connector._map_hana_to_odata_type("DATE") == "Edm.Date"
        assert connector._map_hana_to_odata_type("TIMESTAMP") == "Edm.DateTimeOffset"
    
    def test_column_annotation_detection(self):
        """Test automatic annotation detection from column names"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        # Test dimension detection
        annotations = connector._detect_column_annotations("ProductID", "NVARCHAR")
        assert annotations.get("@Analytics.Dimension") == True
        
        # Test measure detection
        annotations = connector._detect_column_annotations("TotalAmount", "DECIMAL")
        assert annotations.get("@Analytics.Measure") == True
        
        # Test personal data detection
        annotations = connector._detect_column_annotations("CustomerEmail", "NVARCHAR")
        assert annotations.get("@PersonalData.IsPotentiallyPersonal") == True
        
        # Test sensitive data detection
        annotations = connector._detect_column_annotations("HealthStatus", "NVARCHAR")
        assert annotations.get("@PersonalData.IsPotentiallySensitive") == True
    
    def test_label_generation(self):
        """Test human-readable label generation"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        assert connector._generate_label("CustomerID") == "Customer Id"
        assert connector._generate_label("total_amount") == "Total Amount"
        assert connector._generate_label("firstName") == "First Name"
    
    def test_get_stats(self):
        """Test getting connector statistics"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        stats = connector.get_stats()
        
        assert "total_connections" in stats
        assert "circuit_breaker_state" in stats
        assert "hdbcli_available" in stats
        assert "connected" in stats
    
    def test_execute_without_connection(self):
        """Test execute fails without connection"""
        config = HANAConfig()
        connector = HANAConnector(config)
        
        result = connector.execute("SELECT 1")
        
        assert "error" in result


class TestElasticsearchClient:
    """Tests for Elasticsearch client"""
    
    def test_init(self):
        """Test client initialization"""
        config = ElasticsearchConfig()
        client = ElasticsearchClient(config)
        
        assert client._connected == False
        assert client.stats.total_requests == 0
    
    def test_simulation_mode(self):
        """Test simulation mode when ES unavailable"""
        config = ElasticsearchConfig()
        client = ElasticsearchClient(config)
        
        # Connect in simulation mode
        client.connect()
        
        # Should simulate search
        result = client.search("LineItem")
        
        if not client._es_available:
            assert "simulated" in result
            assert "hits" in result
    
    def test_create_vocabulary_index_mapping(self):
        """Test vocabulary index creation"""
        config = ElasticsearchConfig(index_prefix="test")
        client = ElasticsearchClient(config)
        client.connect()
        
        result = client.create_vocabulary_index()
        
        if not client._es_available:
            assert result.get("simulated") == True
            assert "test_vocabulary" in result.get("index", "")
    
    def test_create_entity_index_mapping(self):
        """Test entity index creation"""
        config = ElasticsearchConfig(index_prefix="test")
        client = ElasticsearchClient(config)
        client.connect()
        
        result = client.create_entity_index()
        
        if not client._es_available:
            assert result.get("simulated") == True
            assert "test_entities" in result.get("index", "")
    
    def test_create_audit_index_mapping(self):
        """Test audit index creation"""
        config = ElasticsearchConfig(index_prefix="test")
        client = ElasticsearchClient(config)
        client.connect()
        
        result = client.create_audit_index()
        
        if not client._es_available:
            assert result.get("simulated") == True
            assert "test_audit" in result.get("index", "")
    
    def test_index_vocabulary_term(self):
        """Test indexing a vocabulary term"""
        config = ElasticsearchConfig()
        client = ElasticsearchClient(config)
        client.connect()
        
        term = {
            "term_name": "LineItem",
            "vocabulary": "UI",
            "qualified_name": "UI.LineItem",
            "description": "Collection of line items"
        }
        
        result = client.index_vocabulary_term(term)
        
        if not client._es_available:
            assert result.get("simulated") == True
    
    def test_bulk_index(self):
        """Test bulk document indexing"""
        config = ElasticsearchConfig()
        client = ElasticsearchClient(config)
        client.connect()
        
        documents = [
            {"id": "1", "name": "Test1"},
            {"id": "2", "name": "Test2"},
            {"id": "3", "name": "Test3"}
        ]
        
        result = client.bulk_index(documents, "test_index")
        
        if not client._es_available:
            assert result.get("simulated") == True
            assert result.get("indexed") == 3
    
    def test_simulated_search_results(self):
        """Test simulated search returns structured results"""
        config = ElasticsearchConfig()
        client = ElasticsearchClient(config)
        client.connect()
        
        result = client._simulate_search("LineItem", 10)
        
        assert "total" in result
        assert "hits" in result
        assert "took_ms" in result
        assert len(result["hits"]) > 0
    
    def test_get_stats(self):
        """Test getting client statistics"""
        config = ElasticsearchConfig()
        client = ElasticsearchClient(config)
        
        stats = client.get_stats()
        
        assert "total_requests" in stats
        assert "failed_requests" in stats
        assert "es_available" in stats
        assert "connected" in stats


class TestESStats:
    """Tests for Elasticsearch statistics"""
    
    def test_default_values(self):
        """Test default statistics values"""
        stats = ESStats()
        
        assert stats.total_requests == 0
        assert stats.failed_requests == 0
        assert stats.indices_created == 0
        assert stats.last_error is None