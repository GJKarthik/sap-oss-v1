"""
Unit Tests for HANA and HANA Vector Store Connectors

Tests connection pooling, circuit breakers, and query execution.
"""

import pytest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from config.settings import HANAConfig
from connectors.hana import HANAConnector, CircuitBreaker, ConnectionStats
from connectors.hana_vector import HANAVectorClient, VectorStoreStats


class TestCircuitBreaker:
    """Tests for the circuit-breaker pattern."""

    def test_starts_closed(self):
        cb = CircuitBreaker(failure_threshold=3)
        assert cb.state == "closed"
        assert cb.can_execute() is True

    def test_opens_after_threshold(self):
        cb = CircuitBreaker(failure_threshold=3)

        cb.record_failure()
        cb.record_failure()
        assert cb.state == "closed"

        cb.record_failure()
        assert cb.state == "open"

    def test_blocks_when_open(self):
        cb = CircuitBreaker(failure_threshold=2, reset_timeout=60)

        cb.record_failure()
        cb.record_failure()

        assert cb.state == "open"
        assert cb.can_execute() is False

    def test_success_resets(self):
        cb = CircuitBreaker(failure_threshold=3)

        cb.record_failure()
        cb.record_failure()
        cb.record_success()

        assert cb.state == "closed"
        assert cb.failure_count == 0


class TestConnectionStats:
    """Tests for HANA connection statistics."""

    def test_default_values(self):
        stats = ConnectionStats()

        assert stats.total_connections == 0
        assert stats.active_connections == 0
        assert stats.failed_connections == 0
        assert stats.total_queries == 0


class TestHANAConnector:
    """Tests for the HANA SQL connector."""

    def test_init_without_config(self):
        connector = HANAConnector(HANAConfig())
        assert connector._connected is False

    def test_connect_without_credentials(self):
        connector = HANAConnector(HANAConfig())
        assert connector.connect() is False

    def test_simulation_mode(self):
        connector = HANAConnector(
            HANAConfig(host="test.hana.cloud.sap", user="admin", password="secret")
        )

        connector._hdbcli_available = False
        connector._connected = True
        result = connector.execute("SELECT * FROM TABLES")

        assert "simulated" in result or "error" not in result

    def test_hana_to_odata_type_mapping(self):
        connector = HANAConnector(HANAConfig())

        assert connector._map_hana_to_odata_type("NVARCHAR") == "Edm.String"
        assert connector._map_hana_to_odata_type("INTEGER") == "Edm.Int32"
        assert connector._map_hana_to_odata_type("DECIMAL") == "Edm.Decimal"
        assert connector._map_hana_to_odata_type("BOOLEAN") == "Edm.Boolean"
        assert connector._map_hana_to_odata_type("DATE") == "Edm.Date"
        assert connector._map_hana_to_odata_type("TIMESTAMP") == "Edm.DateTimeOffset"

    def test_column_annotation_detection(self):
        connector = HANAConnector(HANAConfig())

        annotations = connector._detect_column_annotations("ProductID", "NVARCHAR")
        assert annotations.get("@Analytics.Dimension") is True

        annotations = connector._detect_column_annotations("TotalAmount", "DECIMAL")
        assert annotations.get("@Analytics.Measure") is True

        annotations = connector._detect_column_annotations("CustomerEmail", "NVARCHAR")
        assert annotations.get("@PersonalData.IsPotentiallyPersonal") is True

        annotations = connector._detect_column_annotations("HealthStatus", "NVARCHAR")
        assert annotations.get("@PersonalData.IsPotentiallySensitive") is True

    def test_label_generation(self):
        connector = HANAConnector(HANAConfig())

        assert connector._generate_label("CustomerID") == "Customer I D"
        assert connector._generate_label("total_amount") == "Total Amount"
        assert connector._generate_label("firstName") == "First Name"

    def test_get_stats(self):
        connector = HANAConnector(HANAConfig())

        stats = connector.get_stats()

        assert "total_connections" in stats
        assert "circuit_breaker_state" in stats
        assert "hdbcli_available" in stats
        assert "connected" in stats

    def test_execute_without_connection(self):
        connector = HANAConnector(HANAConfig())
        result = connector.execute("SELECT 1")
        assert "error" in result


class TestHANAVectorClient:
    """Tests for HANA vector store client"""
    
    def _make_config(self, **overrides):
        defaults = dict(
            host="test.hana.cloud.sap",
            user="admin",
            password="secret",
            schema="TEST_SCHEMA",
            vector_schema="TEST_SCHEMA",
            vector_table_prefix="TEST",
            vector_embedding_dimensions=1536,
        )
        defaults.update(overrides)
        return HANAConfig(**defaults)
    
    def test_init(self):
        """Test client initialization"""
        config = self._make_config()
        client = HANAVectorClient(config)
        
        assert client._connected == False
        assert client.stats.total_requests == 0
    
    def test_schema_and_prefix_helpers(self):
        """Test _schema() and _table_prefix() helpers"""
        config = self._make_config(vector_schema="VEC_SCHEMA", vector_table_prefix="VOCAB")
        client = HANAVectorClient(config)
        
        assert client._schema() == "VEC_SCHEMA"
        assert client._table_prefix() == "VOCAB"
    
    def test_schema_falls_back_to_hana_schema(self):
        """Test _schema() falls back to config.schema when vector_schema empty"""
        config = self._make_config(schema="MAIN_SCHEMA", vector_schema="")
        client = HANAVectorClient(config)
        
        assert client._schema() == "MAIN_SCHEMA"
    
    def test_simulation_mode(self):
        """Test simulation mode when not connected"""
        config = self._make_config()
        client = HANAVectorClient(config)
        
        # Not connected, should simulate search
        result = client.search("LineItem")
        
        assert "simulated" in result
        assert "hits" in result
    
    def test_create_vocabulary_table(self):
        """Test vocabulary table creation in simulation mode"""
        config = self._make_config(vector_table_prefix="TEST")
        client = HANAVectorClient(config)
        
        result = client.create_vocabulary_table()
        
        assert result.get("simulated") == True
        assert "TEST_VOCABULARY" in result.get("table", "")
    
    def test_create_entity_table(self):
        """Test entity table creation in simulation mode"""
        config = self._make_config(vector_table_prefix="TEST")
        client = HANAVectorClient(config)
        
        result = client.create_entity_table()
        
        assert result.get("simulated") == True
        assert "TEST_ENTITIES" in result.get("table", "")
    
    def test_create_audit_table(self):
        """Test audit table creation in simulation mode"""
        config = self._make_config(vector_table_prefix="TEST")
        client = HANAVectorClient(config)
        
        result = client.create_audit_table()
        
        assert result.get("simulated") == True
        assert "TEST_AUDIT" in result.get("table", "")
    
    def test_index_vocabulary_term(self):
        """Test upserting a vocabulary term in simulation mode"""
        config = self._make_config()
        client = HANAVectorClient(config)
        
        term = {
            "term_name": "LineItem",
            "vocabulary": "UI",
            "qualified_name": "UI.LineItem",
            "description": "Collection of line items"
        }
        
        result = client.index_vocabulary_term(term)
        
        assert result.get("simulated") == True
    
    def test_bulk_index(self):
        """Test bulk document upsert in simulation mode"""
        config = self._make_config()
        client = HANAVectorClient(config)
        
        documents = [
            {"id": "1", "name": "Test1"},
            {"id": "2", "name": "Test2"},
            {"id": "3", "name": "Test3"}
        ]
        
        result = client.bulk_index(documents, "VOCABULARY")
        
        assert result.get("simulated") == True
        assert result.get("indexed") == 3
    
    def test_simulated_search_results(self):
        """Test simulated search returns structured results"""
        config = self._make_config()
        client = HANAVectorClient(config)
        
        result = client._simulate_search("LineItem", 10)
        
        assert "total" in result
        assert "hits" in result
        assert "took_ms" in result
        assert len(result["hits"]) > 0
    
    def test_get_stats(self):
        """Test getting client statistics"""
        config = self._make_config()
        client = HANAVectorClient(config)
        
        stats = client.get_stats()
        
        assert "total_requests" in stats
        assert "failed_requests" in stats
        assert "connected" in stats
        assert "schema" in stats
        assert "table_prefix" in stats


class TestVectorStoreStats:
    """Tests for HANA vector store statistics"""
    

    def test_default_values(self):
        stats = VectorStoreStats()

        assert stats.total_requests == 0
        assert stats.failed_requests == 0
        assert stats.tables_created == 0
        assert stats.last_error is None
