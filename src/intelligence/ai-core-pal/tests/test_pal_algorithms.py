# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Test PAL algorithms on sample tables.

Run: pytest tests/test_pal_algorithms.py -v
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent import hana_client


def skip_if_no_hana():
    """Skip test if HANA not available."""
    if not hana_client.is_available():
        pytest.skip("HANA not configured")


def skip_if_no_table(table_name: str):
    """Skip test if table doesn't exist."""
    schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
    result = hana_client.describe_table(table_name)
    if result.get("column_count", 0) == 0:
        pytest.skip(f"Table {schema}.{table_name} not found - run create_tables.sql")
    if result.get("row_count", 0) == 0:
        pytest.skip(f"Table {schema}.{table_name} is empty - run populate_data.sql")


class TestPalForecast:
    """Test PAL forecasting algorithms."""

    def test_forecast_from_table(self):
        """Test forecasting from PAL_TIMESERIES_DATA."""
        skip_if_no_hana()
        skip_if_no_table("PAL_TIMESERIES_DATA")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        result = hana_client.call_pal_forecast_from_table(
            table_name=f"{schema}.PAL_TIMESERIES_DATA",
            value_column="AMOUNT_USD",
            date_column="RECORD_DATE",
            horizon=6,
            alpha=0.3,
        )
        
        assert result["status"] == "success", f"Forecast failed: {result.get('error')}"
        assert "forecast" in result
        assert len(result["forecast"]) > 0
        print(f"Generated {len(result['forecast'])} forecast points")
        print(f"Algorithm: {result['algorithm']}")

    def test_forecast_with_inline_data(self):
        """Test forecasting with inline data."""
        skip_if_no_hana()
        
        data = [
            {"value": 100},
            {"value": 120},
            {"value": 115},
            {"value": 130},
            {"value": 125},
            {"value": 140},
            {"value": 135},
            {"value": 150},
        ]
        
        result = hana_client.call_pal_forecast(
            input_data=data,
            horizon=3,
            alpha=0.3,
        )
        
        assert result["status"] == "success", f"Forecast failed: {result.get('error')}"
        assert "forecast" in result
        print(f"Inline forecast: {result['forecast']}")


class TestPalAnomaly:
    """Test PAL anomaly detection algorithms."""

    def test_anomaly_from_table(self):
        """Test anomaly detection from PAL_ANOMALY_DATA."""
        skip_if_no_hana()
        skip_if_no_table("PAL_ANOMALY_DATA")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        result = hana_client.call_pal_anomaly_from_table(
            table_name=f"{schema}.PAL_ANOMALY_DATA",
            value_column="METRIC_VALUE",
            multiplier=1.5,
        )
        
        assert result["status"] == "success", f"Anomaly detection failed: {result.get('error')}"
        assert "anomalies" in result
        assert "iqr_stats" in result
        
        print(f"Found {result['anomaly_count']} anomalies out of {result['total']} records")
        print(f"IQR bounds: [{result['iqr_stats']['lower_bound']:.2f}, {result['iqr_stats']['upper_bound']:.2f}]")
        
        # We should find some anomalies (injected in populate_data.sql)
        if result["anomaly_count"] > 0:
            print(f"Sample anomaly: {result['anomalies'][0]}")

    def test_anomaly_with_inline_data(self):
        """Test anomaly detection with inline data."""
        skip_if_no_hana()
        
        # Normal values with one outlier
        data = [
            {"value": 50}, {"value": 52}, {"value": 48}, {"value": 51},
            {"value": 49}, {"value": 53}, {"value": 47}, {"value": 50},
            {"value": 100},  # Outlier
            {"value": 51}, {"value": 49},
        ]
        
        result = hana_client.call_pal_anomaly(
            input_data=data,
            multiplier=1.5,
        )
        
        assert result["status"] == "success", f"Anomaly detection failed: {result.get('error')}"
        assert result["anomaly_count"] >= 1, "Should detect at least one anomaly"
        print(f"Detected anomalies: {result['anomalies']}")


class TestPalClustering:
    """Test PAL clustering algorithms."""

    def test_clustering_from_table(self):
        """Test K-Means clustering from PAL_CLUSTERING_DATA."""
        skip_if_no_hana()
        skip_if_no_table("PAL_CLUSTERING_DATA")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        result = hana_client.call_pal_clustering(
            table_name=f"{schema}.PAL_CLUSTERING_DATA",
            feature_columns=["AGE", "INCOME", "SPEND_SCORE"],
            n_clusters=3,
        )
        
        assert result["status"] == "success", f"Clustering failed: {result.get('error')}"
        assert "cluster_sizes" in result
        assert len(result["cluster_sizes"]) == 3
        
        print(f"Cluster sizes: {result['cluster_sizes']}")
        print(f"Total rows: {result['total_rows']}")


class TestPalClassification:
    """Test PAL classification algorithms."""

    def test_classification_from_table(self):
        """Test Random Forest classification from PAL_CLASSIFICATION_DATA."""
        skip_if_no_hana()
        skip_if_no_table("PAL_CLASSIFICATION_DATA")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        result = hana_client.call_pal_classification(
            table_name=f"{schema}.PAL_CLASSIFICATION_DATA",
            feature_columns=["FEATURE_1", "FEATURE_2", "FEATURE_3"],
            label_column="LABEL",
            n_estimators=50,
        )
        
        assert result["status"] == "success", f"Classification failed: {result.get('error')}"
        assert "training_rows" in result
        
        print(f"Trained on {result['training_rows']} rows")
        print(f"Algorithm: {result['algorithm']}")


class TestPalRegression:
    """Test PAL regression algorithms."""

    def test_regression_from_table(self):
        """Test Linear Regression from PAL_REGRESSION_DATA."""
        skip_if_no_hana()
        skip_if_no_table("PAL_REGRESSION_DATA")
        
        schema = os.environ.get("HANA_SCHEMA", "AINUCLEUS")
        result = hana_client.call_pal_regression(
            table_name=f"{schema}.PAL_REGRESSION_DATA",
            feature_columns=["X1", "X2", "X3"],
            target_column="Y_TARGET",
        )
        
        assert result["status"] == "success", f"Regression failed: {result.get('error')}"
        assert "training_rows" in result
        
        print(f"Trained on {result['training_rows']} rows")
        print(f"Algorithm: {result['algorithm']}")
        if result.get("coefficients"):
            print(f"Coefficients: {result['coefficients']}")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])