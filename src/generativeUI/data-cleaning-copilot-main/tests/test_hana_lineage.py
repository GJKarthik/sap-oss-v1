# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for KùzuDB-HANA cross-database lineage.

Tests cover:
- LineageEdge and DataFlowStep dataclasses
- Lineage type enum
- Edge creation and queries
- PII propagation tracking
- Data flow operations
- Sync operations
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from graph.hana_lineage import (
    LineageType,
    NodeType,
    LineageEdge,
    DataFlowStep,
    KuzuHANALineage,
    get_lineage,
    add_lineage,
    get_upstream,
    get_downstream,
    track_pii,
    pii_exposure,
)


class TestLineageType:
    """Test LineageType enum."""
    
    def test_foreign_key_type(self):
        assert LineageType.FOREIGN_KEY.value == "foreign_key"
    
    def test_derived_from_type(self):
        assert LineageType.DERIVED_FROM.value == "derived_from"
    
    def test_copied_from_type(self):
        assert LineageType.COPIED_FROM.value == "copied_from"
    
    def test_transformed_from_type(self):
        assert LineageType.TRANSFORMED_FROM.value == "transformed_from"
    
    def test_aggregated_from_type(self):
        assert LineageType.AGGREGATED_FROM.value == "aggregated_from"
    
    def test_all_types_defined(self):
        expected = {"foreign_key", "derived_from", "copied_from", 
                    "transformed_from", "aggregated_from", "filtered_from", "joined_from"}
        actual = {t.value for t in LineageType}
        assert actual == expected


class TestNodeType:
    """Test NodeType enum."""
    
    def test_table_type(self):
        assert NodeType.TABLE.value == "Table"
    
    def test_column_type(self):
        assert NodeType.COLUMN.value == "Column"
    
    def test_check_type(self):
        assert NodeType.CHECK.value == "Check"
    
    def test_data_flow_type(self):
        assert NodeType.DATA_FLOW.value == "DataFlow"


class TestLineageEdge:
    """Test LineageEdge dataclass."""
    
    def test_table_level_edge(self):
        edge = LineageEdge(
            source_table="Orders",
            source_column=None,
            target_table="OrderArchive",
            target_column=None,
            lineage_type=LineageType.COPIED_FROM,
        )
        assert edge.source_table == "Orders"
        assert edge.source_column is None
        assert edge.target_table == "OrderArchive"
        assert edge.lineage_type == LineageType.COPIED_FROM
    
    def test_column_level_edge(self):
        edge = LineageEdge(
            source_table="Users",
            source_column="email",
            target_table="Customers",
            target_column="contact_email",
            lineage_type=LineageType.COPIED_FROM,
        )
        assert edge.source_column == "email"
        assert edge.target_column == "contact_email"
    
    def test_edge_with_metadata(self):
        edge = LineageEdge(
            source_table="A",
            source_column="x",
            target_table="B",
            target_column="y",
            lineage_type=LineageType.TRANSFORMED_FROM,
            metadata={"transform": "uppercase", "confidence": 0.95},
        )
        assert edge.metadata["transform"] == "uppercase"
        assert edge.metadata["confidence"] == 0.95
    
    def test_edge_default_timestamp(self):
        edge = LineageEdge(
            source_table="A",
            source_column=None,
            target_table="B",
            target_column=None,
            lineage_type=LineageType.FOREIGN_KEY,
        )
        assert isinstance(edge.created_at, datetime)
    
    def test_edge_default_metadata(self):
        edge = LineageEdge(
            source_table="A",
            source_column=None,
            target_table="B",
            target_column=None,
            lineage_type=LineageType.FOREIGN_KEY,
        )
        assert isinstance(edge.metadata, dict)
        assert len(edge.metadata) == 0


class TestDataFlowStep:
    """Test DataFlowStep dataclass."""
    
    def test_etl_step(self):
        step = DataFlowStep(
            step_id="step-001",
            step_name="Extract Orders",
            source_tables=["Orders"],
            target_tables=["OrdersStaging"],
            transform_type="ETL",
            transform_sql="SELECT * FROM Orders WHERE date > ?",
        )
        assert step.step_id == "step-001"
        assert step.transform_type == "ETL"
        assert "Orders" in step.source_tables
        assert "OrdersStaging" in step.target_tables
    
    def test_cdc_step(self):
        step = DataFlowStep(
            step_id="step-002",
            step_name="CDC Sync",
            source_tables=["Users"],
            target_tables=["UsersReplica"],
            transform_type="CDC",
        )
        assert step.transform_type == "CDC"
    
    def test_step_with_multiple_tables(self):
        step = DataFlowStep(
            step_id="step-003",
            step_name="Join Users Orders",
            source_tables=["Users", "Orders"],
            target_tables=["UserOrders"],
            transform_type="VIEW",
        )
        assert len(step.source_tables) == 2
        assert len(step.target_tables) == 1


class TestKuzuHANALineageUnavailable:
    """Test KuzuHANALineage when backends are unavailable."""
    
    @pytest.fixture
    def lineage(self):
        """Create lineage instance with unavailable backends."""
        lin = KuzuHANALineage()
        lin._kuzu = None
        lin._hana = None
        return lin
    
    def test_initialize_returns_false_when_unavailable(self, lineage):
        result = lineage.initialize()
        assert result is False
    
    def test_add_edge_returns_uuid_even_when_unavailable(self, lineage):
        edge = LineageEdge(
            source_table="A",
            source_column=None,
            target_table="B",
            target_column=None,
            lineage_type=LineageType.FOREIGN_KEY,
        )
        edge_id = lineage.add_lineage_edge(edge)
        assert edge_id is not None
        assert len(edge_id) == 36  # UUID format
    
    def test_get_upstream_returns_empty_when_unavailable(self, lineage):
        result = lineage.get_upstream_lineage("Users")
        assert result == []
    
    def test_get_downstream_returns_empty_when_unavailable(self, lineage):
        result = lineage.get_downstream_lineage("Orders")
        assert result == []
    
    def test_pii_exposure_returns_structure_when_unavailable(self, lineage):
        result = lineage.get_pii_exposure("Users", "email")
        assert "source" in result
        assert "upstream" in result
        assert "downstream" in result
        assert "pii_copies" in result
        assert result["source"]["table"] == "Users"
        assert result["source"]["column"] == "email"


class TestKuzuHANALineageMocked:
    """Test KuzuHANALineage with mocked backends."""
    
    @pytest.fixture
    def mock_kuzu(self):
        """Create mock KùzuDB store."""
        kuzu = MagicMock()
        kuzu.execute.return_value = MagicMock()
        return kuzu
    
    @pytest.fixture
    def mock_hana(self):
        """Create mock HANA client."""
        hana = MagicMock()
        hana.available.return_value = True
        hana.execute.return_value = True
        return hana
    
    @pytest.fixture
    def lineage(self, mock_kuzu, mock_hana):
        """Create lineage with mocked backends."""
        lin = KuzuHANALineage(kuzu_store=mock_kuzu, hana_client=mock_hana)
        return lin
    
    def test_add_column_edge_to_kuzu(self, lineage, mock_kuzu):
        edge = LineageEdge(
            source_table="Users",
            source_column="email",
            target_table="Customers",
            target_column="contact_email",
            lineage_type=LineageType.COPIED_FROM,
        )
        
        lineage.add_lineage_edge(edge)
        
        mock_kuzu.execute.assert_called()
        # Verify Cypher was called with column match
        call_args = str(mock_kuzu.execute.call_args)
        assert "Column" in call_args or "DERIVES_FROM" in call_args
    
    def test_add_table_edge_to_kuzu(self, lineage, mock_kuzu):
        edge = LineageEdge(
            source_table="Orders",
            source_column=None,
            target_table="Archive",
            target_column=None,
            lineage_type=LineageType.COPIED_FROM,
        )
        
        lineage.add_lineage_edge(edge)
        
        mock_kuzu.execute.assert_called()
    
    def test_add_edge_to_hana(self, lineage, mock_hana):
        edge = LineageEdge(
            source_table="Users",
            source_column="email",
            target_table="Customers",
            target_column="contact_email",
            lineage_type=LineageType.COPIED_FROM,
        )
        
        lineage.add_lineage_edge(edge)
        
        mock_hana.execute.assert_called()
    
    def test_track_pii_propagation(self, lineage, mock_hana):
        lineage_id = lineage.track_pii_propagation(
            source_table="Users",
            source_column="email",
            target_table="Customers",
            target_column="customer_email",
            pii_type="email",
            propagation_type="direct_copy",
        )
        
        assert lineage_id is not None
        mock_hana.execute.assert_called()


class TestKuzuHANALineageSchema:
    """Test schema definitions."""
    
    def test_lineage_schema_contains_node_types(self):
        schema = KuzuHANALineage.LINEAGE_SCHEMA
        assert "DataFlow" in schema
        assert "Transform" in schema
    
    def test_lineage_schema_contains_relationships(self):
        schema = KuzuHANALineage.LINEAGE_SCHEMA
        assert "DERIVES_FROM" in schema
        assert "FLOWS_TO" in schema
        assert "TRANSFORMED_BY" in schema
        assert "PART_OF_FLOW" in schema
    
    def test_hana_tables_defined(self):
        tables = KuzuHANALineage.HANA_LINEAGE_TABLES
        assert "LINEAGE_EDGES" in tables
        assert "DATA_FLOWS" in tables
        assert "FLOW_STEPS" in tables
        assert "PII_LINEAGE" in tables
    
    def test_lineage_edges_table_columns(self):
        ddl = KuzuHANALineage.HANA_LINEAGE_TABLES["LINEAGE_EDGES"]
        assert "SOURCE_TABLE" in ddl
        assert "SOURCE_COLUMN" in ddl
        assert "TARGET_TABLE" in ddl
        assert "TARGET_COLUMN" in ddl
        assert "LINEAGE_TYPE" in ddl
    
    def test_pii_lineage_table_columns(self):
        ddl = KuzuHANALineage.HANA_LINEAGE_TABLES["PII_LINEAGE"]
        assert "PII_TYPE" in ddl
        assert "PROPAGATION_TYPE" in ddl
        assert "REVIEWED_BY" in ddl


class TestDataFlowCreation:
    """Test data flow creation."""
    
    @pytest.fixture
    def mock_hana(self):
        hana = MagicMock()
        hana.available.return_value = True
        return hana
    
    @pytest.fixture
    def mock_kuzu(self):
        kuzu = MagicMock()
        return kuzu
    
    @pytest.fixture
    def lineage(self, mock_kuzu, mock_hana):
        return KuzuHANALineage(kuzu_store=mock_kuzu, hana_client=mock_hana)
    
    def test_create_data_flow(self, lineage):
        steps = [
            DataFlowStep(
                step_id="s1",
                step_name="Extract",
                source_tables=["Source"],
                target_tables=["Staging"],
                transform_type="ETL",
            ),
            DataFlowStep(
                step_id="s2",
                step_name="Transform",
                source_tables=["Staging"],
                target_tables=["Target"],
                transform_type="ETL",
            ),
        ]
        
        flow_id = lineage.create_data_flow(
            flow_name="Test Flow",
            description="Test ETL pipeline",
            steps=steps,
            created_by="test@example.com",
        )
        
        assert flow_id is not None
        assert len(flow_id) == 36


class TestConvenienceFunctions:
    """Test module-level convenience functions."""
    
    def test_get_lineage_singleton(self):
        import graph.hana_lineage as lineage_module
        lineage_module._lineage = None
        
        lin1 = get_lineage()
        lin2 = get_lineage()
        
        assert lin1 is lin2
    
    def test_add_lineage_function(self):
        with patch('graph.hana_lineage.get_lineage') as mock_get:
            mock_lineage = MagicMock()
            mock_lineage.add_lineage_edge.return_value = "edge-123"
            mock_get.return_value = mock_lineage
            
            result = add_lineage(
                source_table="A",
                target_table="B",
                lineage_type="foreign_key",
            )
            
            mock_lineage.add_lineage_edge.assert_called_once()
            assert result == "edge-123"
    
    def test_get_upstream_function(self):
        with patch('graph.hana_lineage.get_lineage') as mock_get:
            mock_lineage = MagicMock()
            mock_lineage.get_upstream_lineage.return_value = [{"table": "Source"}]
            mock_get.return_value = mock_lineage
            
            result = get_upstream("Target")
            
            mock_lineage.get_upstream_lineage.assert_called_once()
            assert len(result) == 1
    
    def test_get_downstream_function(self):
        with patch('graph.hana_lineage.get_lineage') as mock_get:
            mock_lineage = MagicMock()
            mock_lineage.get_downstream_lineage.return_value = [{"table": "Target"}]
            mock_get.return_value = mock_lineage
            
            result = get_downstream("Source")
            
            mock_lineage.get_downstream_lineage.assert_called_once()
    
    def test_track_pii_function(self):
        with patch('graph.hana_lineage.get_lineage') as mock_get:
            mock_lineage = MagicMock()
            mock_lineage.track_pii_propagation.return_value = "pii-123"
            mock_get.return_value = mock_lineage
            
            result = track_pii(
                source_table="Users",
                source_column="email",
                target_table="Customers",
                target_column="contact_email",
                pii_type="email",
            )
            
            mock_lineage.track_pii_propagation.assert_called_once()
            assert result == "pii-123"
    
    def test_pii_exposure_function(self):
        with patch('graph.hana_lineage.get_lineage') as mock_get:
            mock_lineage = MagicMock()
            mock_lineage.get_pii_exposure.return_value = {
                "source": {"table": "Users", "column": "email"},
                "upstream": [],
                "downstream": [{"table": "Customers"}],
                "pii_copies": [],
            }
            mock_get.return_value = mock_lineage
            
            result = pii_exposure("Users", "email")
            
            mock_lineage.get_pii_exposure.assert_called_once()
            assert result["source"]["column"] == "email"


class TestSyncOperations:
    """Test sync operations between KùzuDB and HANA."""
    
    @pytest.fixture
    def lineage(self):
        return KuzuHANALineage()
    
    def test_sync_kuzu_to_hana_skips_when_unavailable(self, lineage):
        lineage._kuzu = None
        lineage._hana = None
        
        result = lineage.sync_kuzu_to_hana()
        
        assert result["status"] == "skipped"
        assert "backends not available" in result["reason"]
    
    def test_sync_hana_to_kuzu_skips_when_unavailable(self, lineage):
        lineage._kuzu = None
        lineage._hana = None
        
        result = lineage.sync_hana_to_kuzu()
        
        assert result["status"] == "skipped"