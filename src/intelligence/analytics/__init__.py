"""
Analytics Module - TB-HITL Anomaly Detection Implementation

This module provides anomaly detection with normality testing
and robust fallback to MAD (Median Absolute Deviation).
"""

from .anomaly_detector import (
    AnomalyDetector,
    AnomalyResult,
    BatchAnomalyResult,
    DetectionMethod,
    VarianceAnalyzer,
    VarianceAnalysisResult,
)

__all__ = [
    "AnomalyDetector",
    "AnomalyResult",
    "BatchAnomalyResult",
    "DetectionMethod",
    "VarianceAnalyzer",
    "VarianceAnalysisResult",
]