"""
Anomaly Detection Module
TB-HITL Specification P1-2 Implementation

This module provides anomaly detection with normality testing
and robust fallback to MAD (Median Absolute Deviation).
"""

import logging
from dataclasses import dataclass
from typing import List, Optional, Tuple, Dict, Any
from enum import Enum
import numpy as np
from scipy import stats

# Configure logging
logger = logging.getLogger(__name__)


class DetectionMethod(Enum):
    """Detection method used for anomaly identification."""
    ZSCORE = "zscore"
    MAD = "mad"  # Median Absolute Deviation (robust)


@dataclass
class AnomalyResult:
    """Result of anomaly detection for a single value."""
    value: float
    is_anomaly: bool
    score: float
    threshold: float
    method: DetectionMethod
    percentile: Optional[float] = None


@dataclass
class BatchAnomalyResult:
    """Result of batch anomaly detection."""
    values: np.ndarray
    anomaly_mask: np.ndarray
    scores: np.ndarray
    method: DetectionMethod
    normality_test_pvalue: Optional[float]
    statistics: Dict[str, float]


class AnomalyDetector:
    """
    Anomaly detection with normality testing and MAD fallback.
    
    Implementation follows P1-2 resolution from Chapter 14:
    1. Run Shapiro-Wilk normality test per account category
    2. If p-value > 0.05: Use Z-score (normal distribution confirmed)
    3. If p-value <= 0.05: Use MAD (robust for fat tails)
    
    Thresholds from .clinerules:
    - Z-score threshold: 3.0
    - MAD threshold: 3.5
    - Spike/drop threshold: 25% period-over-period
    """
    
    # Thresholds from .clinerules
    ZSCORE_THRESHOLD = 3.0
    MAD_THRESHOLD = 3.5
    SHAPIRO_P_THRESHOLD = 0.05
    SPIKE_DROP_THRESHOLD = 0.25  # 25% period-over-period
    
    # Minimum sample size for Shapiro-Wilk test
    MIN_SAMPLE_SIZE_SHAPIRO = 20
    MAX_SAMPLE_SIZE_SHAPIRO = 5000  # scipy limitation
    
    # MAD consistency constant for normal distribution approximation
    MAD_CONSISTENCY_CONSTANT = 1.4826
    
    def __init__(
        self,
        zscore_threshold: float = ZSCORE_THRESHOLD,
        mad_threshold: float = MAD_THRESHOLD,
        shapiro_p_threshold: float = SHAPIRO_P_THRESHOLD,
        force_method: Optional[DetectionMethod] = None,
    ):
        """
        Initialize anomaly detector.
        
        Args:
            zscore_threshold: Threshold for Z-score based detection
            mad_threshold: Threshold for MAD-based detection
            shapiro_p_threshold: P-value threshold for Shapiro-Wilk test
            force_method: Force a specific detection method (skip normality test)
        """
        self.zscore_threshold = zscore_threshold
        self.mad_threshold = mad_threshold
        self.shapiro_p_threshold = shapiro_p_threshold
        self.force_method = force_method
    
    def detect_anomalies(self, values: np.ndarray) -> BatchAnomalyResult:
        """
        Detect anomalies in a batch of values.
        
        Args:
            values: Array of numeric values to analyze
            
        Returns:
            BatchAnomalyResult with anomaly mask and scores
        """
        values = np.asarray(values, dtype=np.float64)
        
        if len(values) < 3:
            # Not enough data for meaningful detection
            return BatchAnomalyResult(
                values=values,
                anomaly_mask=np.zeros(len(values), dtype=bool),
                scores=np.zeros(len(values)),
                method=DetectionMethod.ZSCORE,
                normality_test_pvalue=None,
                statistics={"n": len(values), "error": "insufficient_data"},
            )
        
        # Determine detection method
        method, p_value = self._determine_method(values)
        
        # Apply detection
        if method == DetectionMethod.ZSCORE:
            anomaly_mask, scores = self._zscore_detection(values)
            threshold = self.zscore_threshold
        else:
            anomaly_mask, scores = self._mad_detection(values)
            threshold = self.mad_threshold
        
        # Calculate statistics
        statistics = {
            "n": len(values),
            "mean": float(np.mean(values)),
            "median": float(np.median(values)),
            "std": float(np.std(values)),
            "min": float(np.min(values)),
            "max": float(np.max(values)),
            "threshold": threshold,
            "anomaly_count": int(np.sum(anomaly_mask)),
            "anomaly_rate": float(np.mean(anomaly_mask)),
        }
        
        if p_value is not None:
            statistics["shapiro_p_value"] = p_value
            statistics["is_normal"] = p_value > self.shapiro_p_threshold
        
        logger.info(
            f"Anomaly detection: method={method.value}, "
            f"n={len(values)}, anomalies={np.sum(anomaly_mask)}"
        )
        
        return BatchAnomalyResult(
            values=values,
            anomaly_mask=anomaly_mask,
            scores=scores,
            method=method,
            normality_test_pvalue=p_value,
            statistics=statistics,
        )
    
    def detect_single(
        self,
        value: float,
        reference_values: np.ndarray,
    ) -> AnomalyResult:
        """
        Detect if a single value is anomalous compared to reference distribution.
        
        Args:
            value: Single value to test
            reference_values: Reference distribution values
            
        Returns:
            AnomalyResult for the single value
        """
        reference_values = np.asarray(reference_values, dtype=np.float64)
        
        if len(reference_values) < 3:
            return AnomalyResult(
                value=value,
                is_anomaly=False,
                score=0.0,
                threshold=self.zscore_threshold,
                method=DetectionMethod.ZSCORE,
            )
        
        # Determine method
        method, _ = self._determine_method(reference_values)
        
        # Calculate score
        if method == DetectionMethod.ZSCORE:
            mean = np.mean(reference_values)
            std = np.std(reference_values)
            if std == 0:
                score = 0.0
            else:
                score = abs(value - mean) / std
            threshold = self.zscore_threshold
        else:
            median = np.median(reference_values)
            mad = np.median(np.abs(reference_values - median))
            mad_adjusted = mad * self.MAD_CONSISTENCY_CONSTANT
            if mad_adjusted == 0:
                score = 0.0
            else:
                score = abs(value - median) / mad_adjusted
            threshold = self.mad_threshold
        
        is_anomaly = score > threshold
        
        # Calculate percentile
        percentile = float(stats.percentileofscore(reference_values, value))
        
        return AnomalyResult(
            value=value,
            is_anomaly=is_anomaly,
            score=score,
            threshold=threshold,
            method=method,
            percentile=percentile,
        )
    
    def detect_spike_drop(
        self,
        current_value: float,
        prior_value: float,
    ) -> Tuple[bool, float, str]:
        """
        Detect spike or drop (25% period-over-period change).
        
        Args:
            current_value: Current period value
            prior_value: Prior period value
            
        Returns:
            Tuple of (is_anomaly, pct_change, direction)
        """
        if prior_value == 0:
            if current_value == 0:
                return False, 0.0, "none"
            else:
                return True, float('inf'), "new_value"
        
        pct_change = (current_value - prior_value) / abs(prior_value)
        
        is_anomaly = abs(pct_change) >= self.SPIKE_DROP_THRESHOLD
        
        if pct_change >= self.SPIKE_DROP_THRESHOLD:
            direction = "spike"
        elif pct_change <= -self.SPIKE_DROP_THRESHOLD:
            direction = "drop"
        else:
            direction = "normal"
        
        return is_anomaly, pct_change, direction
    
    def _determine_method(
        self,
        values: np.ndarray,
    ) -> Tuple[DetectionMethod, Optional[float]]:
        """
        Determine detection method using Shapiro-Wilk normality test.
        
        Returns:
            Tuple of (method, p_value)
        """
        if self.force_method is not None:
            return self.force_method, None
        
        n = len(values)
        
        # Check sample size constraints for Shapiro-Wilk
        if n < self.MIN_SAMPLE_SIZE_SHAPIRO:
            # Too small for reliable normality test - use robust method
            logger.debug(
                f"Sample size {n} < {self.MIN_SAMPLE_SIZE_SHAPIRO}, "
                f"using MAD (robust) method"
            )
            return DetectionMethod.MAD, None
        
        # Sample if too large for Shapiro-Wilk
        test_values = values
        if n > self.MAX_SAMPLE_SIZE_SHAPIRO:
            test_values = np.random.choice(
                values, 
                size=self.MAX_SAMPLE_SIZE_SHAPIRO, 
                replace=False,
            )
        
        # Run Shapiro-Wilk test
        try:
            _, p_value = stats.shapiro(test_values)
        except Exception as e:
            logger.warning(f"Shapiro-Wilk test failed: {e}, using MAD method")
            return DetectionMethod.MAD, None
        
        # Choose method based on p-value
        if p_value > self.shapiro_p_threshold:
            logger.debug(
                f"Shapiro-Wilk p={p_value:.4f} > {self.shapiro_p_threshold}, "
                f"using Z-score method"
            )
            return DetectionMethod.ZSCORE, p_value
        else:
            logger.debug(
                f"Shapiro-Wilk p={p_value:.4f} <= {self.shapiro_p_threshold}, "
                f"using MAD method (non-normal distribution)"
            )
            return DetectionMethod.MAD, p_value
    
    def _zscore_detection(
        self,
        values: np.ndarray,
    ) -> Tuple[np.ndarray, np.ndarray]:
        """
        Z-score based anomaly detection.
        
        Returns:
            Tuple of (anomaly_mask, z_scores)
        """
        mean = np.mean(values)
        std = np.std(values)
        
        if std == 0:
            # All values are identical
            return np.zeros(len(values), dtype=bool), np.zeros(len(values))
        
        z_scores = np.abs((values - mean) / std)
        anomaly_mask = z_scores > self.zscore_threshold
        
        return anomaly_mask, z_scores
    
    def _mad_detection(
        self,
        values: np.ndarray,
    ) -> Tuple[np.ndarray, np.ndarray]:
        """
        MAD (Median Absolute Deviation) based anomaly detection.
        
        Robust to outliers and fat-tailed distributions.
        
        Returns:
            Tuple of (anomaly_mask, modified_z_scores)
        """
        median = np.median(values)
        mad = np.median(np.abs(values - median))
        
        # Apply consistency constant for normal distribution approximation
        mad_adjusted = mad * self.MAD_CONSISTENCY_CONSTANT
        
        if mad_adjusted == 0:
            # All values are at median - no anomalies
            return np.zeros(len(values), dtype=bool), np.zeros(len(values))
        
        modified_z_scores = np.abs(values - median) / mad_adjusted
        anomaly_mask = modified_z_scores > self.mad_threshold
        
        return anomaly_mask, modified_z_scores


# =============================================================================
# Variance Analysis with Anomaly Detection
# =============================================================================

@dataclass
class VarianceAnalysisResult:
    """Result of variance analysis for an account."""
    account_code: str
    account_name: str
    current_value: float
    prior_value: float
    variance_amount: float
    variance_percentage: float
    is_anomaly: bool
    anomaly_type: str  # spike, drop, statistical, material, new_account, none
    anomaly_score: Optional[float]
    detection_method: Optional[str]
    details: Dict[str, Any]


class VarianceAnalyzer:
    """
    Combined variance and anomaly analysis.
    
    Implements AI augmentation requirements:
    - TB-REQ-AI01: Anomaly detection
    - TB-REQ-AI02: Trend analysis
    - TB-REQ-AI03: New account detection
    - TB-REQ-AI04: Spike/drop detection
    - TB-REQ-AI05: Material balance identification
    """
    
    def __init__(
        self,
        materiality_threshold_bs: float = 100_000_000,  # $100M for BS
        materiality_threshold_pl: float = 3_000_000,    # $3M for PL
        materiality_threshold_pct: float = 0.10,        # 10%
    ):
        """
        Initialize variance analyzer.
        
        Args:
            materiality_threshold_bs: Balance sheet materiality threshold
            materiality_threshold_pl: P&L materiality threshold
            materiality_threshold_pct: Percentage materiality threshold
        """
        self.materiality_threshold_bs = materiality_threshold_bs
        self.materiality_threshold_pl = materiality_threshold_pl
        self.materiality_threshold_pct = materiality_threshold_pct
        self.anomaly_detector = AnomalyDetector()
    
    def analyze_variance(
        self,
        account_code: str,
        account_name: str,
        current_value: float,
        prior_value: Optional[float],
        historical_values: Optional[List[float]] = None,
        account_type: str = "pl",  # "bs" or "pl"
    ) -> VarianceAnalysisResult:
        """
        Analyze a single account variance.
        
        Args:
            account_code: Account code
            account_name: Account name
            current_value: Current period value
            prior_value: Prior period value (None for new accounts)
            historical_values: Historical values for trend analysis
            account_type: "bs" for balance sheet, "pl" for profit/loss
            
        Returns:
            VarianceAnalysisResult
        """
        details: Dict[str, Any] = {}
        
        # Handle new account
        if prior_value is None:
            return VarianceAnalysisResult(
                account_code=account_code,
                account_name=account_name,
                current_value=current_value,
                prior_value=0.0,
                variance_amount=current_value,
                variance_percentage=float('inf') if current_value != 0 else 0,
                is_anomaly=True,
                anomaly_type="new_account",
                anomaly_score=None,
                detection_method=None,
                details={"new_account": True},
            )
        
        # Calculate variance
        variance_amount = current_value - prior_value
        if prior_value != 0:
            variance_percentage = variance_amount / abs(prior_value)
        else:
            variance_percentage = float('inf') if variance_amount != 0 else 0
        
        # Check for spike/drop (25% threshold)
        is_spike_drop, _, spike_drop_type = self.anomaly_detector.detect_spike_drop(
            current_value, prior_value
        )
        
        # Check materiality
        materiality_threshold = (
            self.materiality_threshold_bs 
            if account_type == "bs" 
            else self.materiality_threshold_pl
        )
        is_material = abs(current_value) > materiality_threshold
        is_material_variance = abs(variance_percentage) > self.materiality_threshold_pct
        
        # Statistical anomaly detection on historical data
        anomaly_score = None
        detection_method = None
        is_statistical_anomaly = False
        
        if historical_values and len(historical_values) >= 3:
            result = self.anomaly_detector.detect_single(
                current_value,
                np.array(historical_values),
            )
            is_statistical_anomaly = result.is_anomaly
            anomaly_score = result.score
            detection_method = result.method.value
            details["historical_analysis"] = {
                "n_periods": len(historical_values),
                "score": anomaly_score,
                "threshold": result.threshold,
                "percentile": result.percentile,
            }
        
        # Determine anomaly type
        is_anomaly = False
        anomaly_type = "none"
        
        if spike_drop_type == "spike":
            is_anomaly = True
            anomaly_type = "spike"
        elif spike_drop_type == "drop":
            is_anomaly = True
            anomaly_type = "drop"
        elif is_statistical_anomaly:
            is_anomaly = True
            anomaly_type = "statistical"
        elif is_material and is_material_variance:
            is_anomaly = True
            anomaly_type = "material"
        
        details["is_material_balance"] = is_material
        details["is_material_variance"] = is_material_variance
        details["variance_pct_threshold"] = self.materiality_threshold_pct
        
        return VarianceAnalysisResult(
            account_code=account_code,
            account_name=account_name,
            current_value=current_value,
            prior_value=prior_value,
            variance_amount=variance_amount,
            variance_percentage=variance_percentage,
            is_anomaly=is_anomaly,
            anomaly_type=anomaly_type,
            anomaly_score=anomaly_score,
            detection_method=detection_method,
            details=details,
        )
    
    def analyze_batch(
        self,
        records: List[Dict[str, Any]],
        account_type: str = "pl",
    ) -> List[VarianceAnalysisResult]:
        """
        Analyze a batch of variance records.
        
        Args:
            records: List of records with account_code, current_value, prior_value, etc.
            account_type: "bs" for balance sheet, "pl" for profit/loss
            
        Returns:
            List of VarianceAnalysisResult
        """
        results = []
        
        for record in records:
            result = self.analyze_variance(
                account_code=record.get("account_code", ""),
                account_name=record.get("account_name", ""),
                current_value=record.get("current_value", 0),
                prior_value=record.get("prior_value"),
                historical_values=record.get("historical_values"),
                account_type=account_type,
            )
            results.append(result)
        
        return results


# =============================================================================
# Main Entry Point
# =============================================================================

if __name__ == "__main__":
    # Example usage
    print("Anomaly Detector - TB-HITL P1-2 Implementation")
    print("=" * 60)
    
    # Test with normally distributed data
    np.random.seed(42)
    normal_data = np.random.normal(100, 10, 100)
    normal_data = np.append(normal_data, [150, 160, 40])  # Add outliers
    
    detector = AnomalyDetector()
    result = detector.detect_anomalies(normal_data)
    
    print("\nNormal Distribution Test:")
    print(f"  Method: {result.method.value}")
    print(f"  P-value: {result.normality_test_pvalue:.4f}")
    print(f"  Anomalies: {result.statistics['anomaly_count']}")
    print(f"  Anomaly indices: {np.where(result.anomaly_mask)[0]}")
    
    # Test with fat-tailed data (Cauchy distribution)
    fat_tail_data = np.random.standard_cauchy(100) * 10 + 100
    
    result_fat = detector.detect_anomalies(fat_tail_data)
    
    print("\nFat-Tailed Distribution Test:")
    print(f"  Method: {result_fat.method.value}")
    if result_fat.normality_test_pvalue:
        print(f"  P-value: {result_fat.normality_test_pvalue:.4f}")
    print(f"  Anomalies: {result_fat.statistics['anomaly_count']}")
    
    # Test spike/drop detection
    print("\nSpike/Drop Detection:")
    is_anomaly, pct, direction = detector.detect_spike_drop(125, 100)
    print(f"  100 -> 125: anomaly={is_anomaly}, pct={pct:.2%}, type={direction}")
    
    is_anomaly, pct, direction = detector.detect_spike_drop(70, 100)
    print(f"  100 -> 70: anomaly={is_anomaly}, pct={pct:.2%}, type={direction}")
    
    # Test variance analysis
    print("\nVariance Analysis:")
    analyzer = VarianceAnalyzer()
    variance_result = analyzer.analyze_variance(
        account_code="4100001",
        account_name="Revenue - Product Sales",
        current_value=1_875_000,
        prior_value=1_500_000,
        historical_values=[1_400_000, 1_450_000, 1_480_000, 1_500_000],
    )
    print(f"  Account: {variance_result.account_name}")
    print(f"  Variance: ${variance_result.variance_amount:,.2f} ({variance_result.variance_percentage:.1%})")
    print(f"  Is Anomaly: {variance_result.is_anomaly}")
    print(f"  Anomaly Type: {variance_result.anomaly_type}")