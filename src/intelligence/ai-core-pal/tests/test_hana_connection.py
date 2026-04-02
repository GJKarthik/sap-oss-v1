# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Test HANA Cloud connectivity for ai-core-pal.

Run: pytest tests/test_hana_connection.py -v
"""
import os
import sys

import pytest

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent import hana_client


class TestHanaConnection:
    """Test HANA Cloud connection."""

    def test_hana_available(self):
        """Test that HANA is available when configured."""
        # This test passes if credentials are set
        is_avail = hana_client.is_available()
        if not os.environ.get("HANA_HOST"):
            pytest.skip("HANA_HOST not configured")
        assert is_avail, "HANA should be available when credentials are set"

    def test_connection(self):
        """Test HANA connection."""
        if not hana_client.is_available():
            pytest.skip("HANA not configured")
        
        result = hana_client.test_connection()
        assert result["status"] == "success", f"Connection failed: {result.get('error')}"
        assert "timestamp" in result
        assert "user" in result
        assert "schema" in result
        print(f"Connected as {result['user']} to schema {result['schema']}")

    def test_list_tables(self):
        """Test listing tables."""
        if not hana_client.is_available():
            pytest.skip("HANA not configured")
        
        tables = hana_client.list_tables()
        assert isinstance(tables, list)
        print(f"Found {len(tables)} tables")
        for t in tables[:5]:
            print(f"  - {t['table_name']}")

    def test_discover_pal_tables(self):
        """Test PAL table discovery."""
        if not hana_client.is_available():
            pytest.skip("HANA not configured")
        
        result = hana_client.discover_pal_tables()
        assert "tables" in result
        assert "count" in result
        
        pal_suitable = [t for t in result["tables"] if t.get("pal_suitable")]
        print(f"Found {len(pal_suitable)} PAL-suitable tables out of {result['count']}")


class TestPalTables:
    """Test PAL sample tables exist."""

    EXPECTED_TABLES = [
        "PAL_TIMESERIES_DATA",
        "PAL_ANOMALY_DATA",
        "PAL_CLUSTERING_DATA",
        "PAL_CLASSIFICATION_DATA",
        "PAL_REGRESSION_DATA",
    ]

    def test_pal_tables_exist(self):
        """Test that PAL sample tables exist."""
        if not hana_client.is_available():
            pytest.skip("HANA not configured")
        
        tables = hana_client.list_tables()
        table_names = [t["table_name"] for t in tables]
        
        missing = []
        for expected in self.EXPECTED_TABLES:
            if expected not in table_names:
                missing.append(expected)
        
        if missing:
            pytest.skip(f"Missing tables (run create_tables.sql first): {missing}")
        
        print(f"All {len(self.EXPECTED_TABLES)} PAL tables found")

    def test_timeseries_table_has_data(self):
        """Test that timeseries table has data."""
        if not hana_client.is_available():
            pytest.skip("HANA not configured")
        
        result = hana_client.describe_table("PAL_TIMESERIES_DATA")
        if result.get("column_count", 0) == 0:
            pytest.skip("PAL_TIMESERIES_DATA not found")
        
        assert result["row_count"] > 0, "Table should have data (run populate_data.sql)"
        print(f"PAL_TIMESERIES_DATA has {result['row_count']} rows")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])