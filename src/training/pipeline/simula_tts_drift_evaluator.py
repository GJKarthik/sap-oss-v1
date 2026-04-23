"""
Text-to-SQL Drift Evaluator for Simula Training Pipeline.

This module implements the drift metrics framework defined in Chapter 18
of the Simula specification. It computes 12 TTS drift metrics and the
composite TTS-EVAL score.

Reference: docs/latex/specs/simula/chapters/18-text-to-sql-drift.tex
Schema: docs/schema/simula/tts-drift-metrics.schema.json
"""

from __future__ import annotations

import hashlib
import math
import uuid
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional

# Note: These imports will be available when the full pipeline is implemented
# from .schema_registry import SchemaRegistry, TableSchema
# from .simula_data_generator import TrainingExample


@dataclass
class MetricValue:
    """A single metric measurement with threshold evaluation."""
    
    value: float
    threshold: float
    passed: bool
    confidence_bound: Optional[float] = None
    direction: str = "higher_better"  # or "lower_better"
    baseline_value: Optional[float] = None
    delta: Optional[float] = None
    
    @classmethod
    def create(
        cls,
        value: float,
        threshold: float,
        direction: str = "higher_better",
        baseline_value: Optional[float] = None,
        sample_size: int = 100,
    ) -> "MetricValue":
        """Create a MetricValue with automatic threshold evaluation."""
        # Compute Wilson confidence bound
        if direction == "higher_better":
            conf_bound = cls._wilson_lcb(value, sample_size)
            passed = conf_bound >= threshold
        else:
            conf_bound = cls._wilson_ucb(value, sample_size)
            passed = conf_bound <= threshold
        
        delta = None
        if baseline_value is not None:
            delta = abs(value - baseline_value)
        
        return cls(
            value=value,
            threshold=threshold,
            passed=passed,
            confidence_bound=conf_bound,
            direction=direction,
            baseline_value=baseline_value,
            delta=delta,
        )
    
    @staticmethod
    def _wilson_lcb(p: float, n: int, z: float = 1.96) -> float:
        """Compute 95% Wilson Lower Confidence Bound."""
        if n == 0:
            return 0.0
        z2 = z * z
        denom = 1 + z2 / n
        center = p + z2 / (2 * n)
        margin = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n))
        return (center - margin) / denom
    
    @staticmethod
    def _wilson_ucb(p: float, n: int, z: float = 1.96) -> float:
        """Compute 95% Wilson Upper Confidence Bound."""
        if n == 0:
            return 1.0
        z2 = z * z
        denom = 1 + z2 / n
        center = p + z2 / (2 * n)
        margin = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n))
        return (center + margin) / denom


@dataclass
class SchemaDriftMetrics:
    """Schema-related drift metrics (TTS-M01 to TTS-M04)."""
    
    scr: MetricValue  # Schema Coverage Rate
    sss: MetricValue  # Schema Staleness Score
    ctmr: MetricValue  # Column Type Mismatch Rate
    fkcr: MetricValue  # Foreign Key Consistency Rate


@dataclass
class SemanticDriftMetrics:
    """Semantic drift metrics (TTS-M05 to TTS-M08)."""
    
    sas: MetricValue  # Semantic Alignment Score
    ipr: MetricValue  # Intent Preservation Rate
    tds: MetricValue  # Terminology Drift Score
    arr: MetricValue  # Ambiguity Resolution Rate


@dataclass
class GenerationQualityMetrics:
    """Generation quality drift metrics (TTS-M09 to TTS-M12)."""
    
    esr: MetricValue  # Execution Success Rate
    rfs: MetricValue  # Result Fidelity Score
    cdd: MetricValue  # Complexity Distribution Drift
    tcd: MetricValue  # Taxonomy Coverage Drift


@dataclass
class TTSMetricReport:
    """Complete drift metric report per tts-drift-metrics.schema.json."""
    
    report_id: str
    evaluated_at: str
    sample_size: int
    confidence_level: float
    evaluation_context: str  # training, ci_cd, production, adhoc
    baseline_id: Optional[str]
    
    schema_drift_metrics: SchemaDriftMetrics
    semantic_drift_metrics: SemanticDriftMetrics
    generation_quality_metrics: GenerationQualityMetrics
    
    tts_eval: float
    tts_eval_status: str  # GREEN, AMBER, RED
    
    drift_alerts: list[dict] = field(default_factory=list)
    
    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "report_id": self.report_id,
            "evaluated_at": self.evaluated_at,
            "sample_size": self.sample_size,
            "confidence_level": self.confidence_level,
            "evaluation_context": self.evaluation_context,
            "baseline_id": self.baseline_id,
            "schema_drift_metrics": {
                "scr": self._metric_to_dict(self.schema_drift_metrics.scr),
                "sss": self._metric_to_dict(self.schema_drift_metrics.sss),
                "ctmr": self._metric_to_dict(self.schema_drift_metrics.ctmr),
                "fkcr": self._metric_to_dict(self.schema_drift_metrics.fkcr),
            },
            "semantic_drift_metrics": {
                "sas": self._metric_to_dict(self.semantic_drift_metrics.sas),
                "ipr": self._metric_to_dict(self.semantic_drift_metrics.ipr),
                "tds": self._metric_to_dict(self.semantic_drift_metrics.tds),
                "arr": self._metric_to_dict(self.semantic_drift_metrics.arr),
            },
            "generation_quality_metrics": {
                "esr": self._metric_to_dict(self.generation_quality_metrics.esr),
                "rfs": self._metric_to_dict(self.generation_quality_metrics.rfs),
                "cdd": self._metric_to_dict(self.generation_quality_metrics.cdd),
                "tcd": self._metric_to_dict(self.generation_quality_metrics.tcd),
            },
            "tts_eval": self.tts_eval,
            "tts_eval_status": self.tts_eval_status,
            "drift_alerts": self.drift_alerts,
        }
    
    @staticmethod
    def _metric_to_dict(m: MetricValue) -> dict[str, Any]:
        return {
            "value": m.value,
            "threshold": m.threshold,
            "passed": m.passed,
            "confidence_bound": m.confidence_bound,
            "direction": m.direction,
            "baseline_value": m.baseline_value,
            "delta": m.delta,
        }


# Metric thresholds from Chapter 18
METRIC_THRESHOLDS = {
    "scr": {"threshold": 0.85, "direction": "higher_better"},
    "sss": {"threshold": 7.0, "direction": "lower_better"},
    "ctmr": {"threshold": 0.02, "direction": "lower_better"},
    "fkcr": {"threshold": 0.95, "direction": "higher_better"},
    "sas": {"threshold": 0.80, "direction": "higher_better"},
    "ipr": {"threshold": 0.90, "direction": "higher_better"},
    "tds": {"threshold": 0.15, "direction": "lower_better"},
    "arr": {"threshold": 0.75, "direction": "higher_better"},
    "esr": {"threshold": 0.95, "direction": "higher_better"},
    "rfs": {"threshold": 0.85, "direction": "higher_better"},
    "cdd": {"threshold": 0.10, "direction": "lower_better"},
    "tcd": {"threshold": 0.05, "direction": "lower_better"},
    # Statistical foundation metrics (TTS-M13 to TTS-M15)
    "w1d": {"threshold": 0.10, "direction": "lower_better"},
    "psi": {"threshold_low": 0.10, "threshold_high": 0.25, "direction": "lower_better"},
    "kss": {"p_value_threshold": 0.05, "direction": "higher_pvalue_better"},
}


# =============================================================================
# Statistical Foundation Metrics (TTS-M13 to TTS-M15)
# =============================================================================

@dataclass
class WassersteinResult:
    """TTS-M13: Wasserstein Distance result."""
    
    value: float  # Raw Wasserstein distance
    value_normalized: float  # Normalized to [0, 1]
    threshold: float
    passed: bool
    direction: str = "lower_better"
    feature_name: Optional[str] = None
    sample_size_p: int = 0
    sample_size_q: int = 0
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "value": self.value,
            "value_normalized": self.value_normalized,
            "threshold": self.threshold,
            "passed": self.passed,
            "direction": self.direction,
            "feature_name": self.feature_name,
            "sample_size_p": self.sample_size_p,
            "sample_size_q": self.sample_size_q,
        }


@dataclass
class PSIResult:
    """TTS-M14: Population Stability Index result."""
    
    value: float
    threshold_low: float
    threshold_high: float
    passed: bool
    drift_level: str  # "no_drift", "moderate_drift", "significant_drift"
    direction: str = "lower_better"
    num_bins: int = 10
    bin_contributions: Optional[list[dict]] = None
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "value": self.value,
            "threshold_low": self.threshold_low,
            "threshold_high": self.threshold_high,
            "passed": self.passed,
            "drift_level": self.drift_level,
            "direction": self.direction,
            "num_bins": self.num_bins,
            "bin_contributions": self.bin_contributions,
        }


@dataclass
class KSResult:
    """TTS-M15: Kolmogorov-Smirnov test result."""
    
    statistic: float  # D-statistic
    p_value: float
    p_value_threshold: float
    passed: bool
    reject_null: bool  # True = drift detected
    direction: str = "higher_pvalue_better"
    confidence_level: float = 0.95
    sample_size_p: int = 0
    sample_size_q: int = 0
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "statistic": self.statistic,
            "p_value": self.p_value,
            "p_value_threshold": self.p_value_threshold,
            "passed": self.passed,
            "reject_null": self.reject_null,
            "direction": self.direction,
            "null_hypothesis": "P = Q (distributions are identical)",
            "confidence_level": self.confidence_level,
            "sample_size_p": self.sample_size_p,
            "sample_size_q": self.sample_size_q,
        }


@dataclass
class StatisticalFoundationMetrics:
    """Statistical foundation metrics (TTS-M13 to TTS-M15)."""
    
    w1d: Optional[WassersteinResult] = None  # Wasserstein Distance
    psi: Optional[PSIResult] = None  # Population Stability Index
    kss: Optional[KSResult] = None  # Kolmogorov-Smirnov Statistic
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "w1d": self.w1d.to_dict() if self.w1d else None,
            "psi": self.psi.to_dict() if self.psi else None,
            "kss": self.kss.to_dict() if self.kss else None,
        }


class StatisticalDriftCalculator:
    """
    Calculator for statistical drift metrics using scipy.
    
    Implements TTS-M13 (Wasserstein), TTS-M14 (PSI), and TTS-M15 (KS).
    """
    
    @staticmethod
    def compute_wasserstein(
        p_values: list[float],
        q_values: list[float],
        feature_name: Optional[str] = None,
        threshold: float = 0.10,
    ) -> WassersteinResult:
        """
        Compute TTS-M13: Wasserstein Distance (Earth Mover's Distance).
        
        Args:
            p_values: Distribution P (real/baseline data)
            q_values: Distribution Q (synthetic/current data)
            feature_name: Name of the feature being compared
            threshold: Normalized threshold for pass/fail
            
        Returns:
            WassersteinResult with raw and normalized distances
        """
        try:
            from scipy.stats import wasserstein_distance
        except ImportError:
            # Fallback: simple approximation
            p_sorted = sorted(p_values)
            q_sorted = sorted(q_values)
            min_len = min(len(p_sorted), len(q_sorted))
            raw_distance = sum(abs(p_sorted[i] - q_sorted[i]) for i in range(min_len)) / max(min_len, 1)
        else:
            raw_distance = wasserstein_distance(p_values, q_values)
        
        # Normalize to [0, 1]
        all_values = list(p_values) + list(q_values)
        value_range = max(all_values) - min(all_values) if all_values else 1.0
        normalized = raw_distance / max(value_range, 1e-10)
        normalized = min(normalized, 1.0)  # Cap at 1.0
        
        return WassersteinResult(
            value=raw_distance,
            value_normalized=normalized,
            threshold=threshold,
            passed=normalized <= threshold,
            feature_name=feature_name,
            sample_size_p=len(p_values),
            sample_size_q=len(q_values),
        )
    
    @staticmethod
    def compute_psi(
        p_values: list[float],
        q_values: list[float],
        num_bins: int = 10,
        threshold_low: float = 0.10,
        threshold_high: float = 0.25,
        smoothing_alpha: float = 0.001,
    ) -> PSIResult:
        """
        Compute TTS-M14: Population Stability Index.
        
        Args:
            p_values: Distribution P (real/baseline data)
            q_values: Distribution Q (synthetic/current data)
            num_bins: Number of bins for discretization
            threshold_low: Threshold below which no drift
            threshold_high: Threshold above which significant drift
            smoothing_alpha: Laplace smoothing parameter
            
        Returns:
            PSIResult with PSI value and drift classification
        """
        import numpy as np
        
        # Create bins based on P distribution
        all_values = list(p_values) + list(q_values)
        min_val, max_val = min(all_values), max(all_values)
        bins = np.linspace(min_val, max_val, num_bins + 1)
        
        # Compute histograms
        p_counts, _ = np.histogram(p_values, bins=bins)
        q_counts, _ = np.histogram(q_values, bins=bins)
        
        # Apply Laplace smoothing
        n_p, n_q = len(p_values), len(q_values)
        p_props = (p_counts + smoothing_alpha) / (n_p + num_bins * smoothing_alpha)
        q_props = (q_counts + smoothing_alpha) / (n_q + num_bins * smoothing_alpha)
        
        # Compute PSI
        psi_value = 0.0
        bin_contributions = []
        
        for i in range(num_bins):
            contribution = (p_props[i] - q_props[i]) * np.log(p_props[i] / q_props[i])
            psi_value += contribution
            bin_contributions.append({
                "bin_index": i,
                "bin_label": f"[{bins[i]:.2f}, {bins[i+1]:.2f})",
                "p_proportion": float(p_props[i]),
                "q_proportion": float(q_props[i]),
                "contribution": float(contribution),
            })
        
        # Classify drift level
        if psi_value < threshold_low:
            drift_level = "no_drift"
            passed = True
        elif psi_value < threshold_high:
            drift_level = "moderate_drift"
            passed = True  # Still passes but needs investigation
        else:
            drift_level = "significant_drift"
            passed = False
        
        return PSIResult(
            value=float(psi_value),
            threshold_low=threshold_low,
            threshold_high=threshold_high,
            passed=passed,
            drift_level=drift_level,
            num_bins=num_bins,
            bin_contributions=bin_contributions,
        )
    
    @staticmethod
    def compute_ks_test(
        p_values: list[float],
        q_values: list[float],
        p_value_threshold: float = 0.05,
    ) -> KSResult:
        """
        Compute TTS-M15: Kolmogorov-Smirnov Test.
        
        Args:
            p_values: Distribution P (real/baseline data)
            q_values: Distribution Q (synthetic/current data)
            p_value_threshold: Significance level (default 0.05)
            
        Returns:
            KSResult with test statistic and p-value
        """
        try:
            from scipy.stats import ks_2samp
            statistic, p_value = ks_2samp(p_values, q_values)
        except ImportError:
            # Fallback: simplified CDF comparison
            p_sorted = sorted(p_values)
            q_sorted = sorted(q_values)
            
            # Compute maximum CDF difference
            max_diff = 0.0
            all_vals = sorted(set(p_sorted + q_sorted))
            
            for val in all_vals:
                p_cdf = sum(1 for x in p_sorted if x <= val) / len(p_sorted)
                q_cdf = sum(1 for x in q_sorted if x <= val) / len(q_sorted)
                max_diff = max(max_diff, abs(p_cdf - q_cdf))
            
            statistic = max_diff
            # Approximate p-value (very rough)
            n = min(len(p_values), len(q_values))
            p_value = max(0.0, 1.0 - statistic * math.sqrt(n))
        
        reject_null = p_value <= p_value_threshold
        
        return KSResult(
            statistic=float(statistic),
            p_value=float(p_value),
            p_value_threshold=p_value_threshold,
            passed=not reject_null,  # Passes if we don't reject H0
            reject_null=reject_null,
            sample_size_p=len(p_values),
            sample_size_q=len(q_values),
        )
    
    @staticmethod
    def compute_jsd(
        p_values: list[float],
        q_values: list[float],
        num_bins: int = 10,
    ) -> float:
        """
        Compute Jensen-Shannon Divergence (used by TTS-M07).
        
        Args:
            p_values: Distribution P
            q_values: Distribution Q
            num_bins: Number of bins for discretization
            
        Returns:
            JSD value in [0, 1]
        """
        try:
            from scipy.spatial.distance import jensenshannon
            import numpy as np
            
            # Create bins
            all_values = list(p_values) + list(q_values)
            min_val, max_val = min(all_values), max(all_values)
            bins = np.linspace(min_val, max_val, num_bins + 1)
            
            # Compute histograms and normalize to probabilities
            p_hist, _ = np.histogram(p_values, bins=bins, density=True)
            q_hist, _ = np.histogram(q_values, bins=bins, density=True)
            
            # Add small epsilon to avoid division by zero
            epsilon = 1e-10
            p_hist = p_hist + epsilon
            q_hist = q_hist + epsilon
            
            # Normalize
            p_hist = p_hist / p_hist.sum()
            q_hist = q_hist / q_hist.sum()
            
            return float(jensenshannon(p_hist, q_hist))
        except ImportError:
            # Fallback: rough approximation
            return 0.0


# =============================================================================
# EWMA Sequential Monitoring
# =============================================================================

class EWMAMonitor:
    """
    Exponentially Weighted Moving Average monitor for drift detection.
    
    EWMA_t = λ * D_t + (1 - λ) * EWMA_{t-1}
    
    Alarm triggers when EWMA_t exceeds control limit (μ + 3σ).
    """
    
    def __init__(
        self,
        smoothing_factor: float = 0.3,
        baseline_mean: float = 0.0,
        baseline_std: float = 0.1,
        control_limit_sigma: float = 3.0,
    ):
        """
        Initialize EWMA monitor.
        
        Args:
            smoothing_factor: λ parameter (0 < λ ≤ 1)
            baseline_mean: Expected mean from baseline
            baseline_std: Expected standard deviation from baseline
            control_limit_sigma: Number of sigmas for control limit
        """
        self.lambda_ = smoothing_factor
        self.baseline_mean = baseline_mean
        self.baseline_std = baseline_std
        self.control_limit_sigma = control_limit_sigma
        
        self._ewma: Optional[float] = None
        self._history: list[tuple[datetime, float, float]] = []  # (timestamp, value, ewma)
    
    @property
    def control_limit(self) -> float:
        """Upper control limit for alarm."""
        return self.baseline_mean + self.control_limit_sigma * self.baseline_std
    
    def update(self, value: float, timestamp: Optional[datetime] = None) -> tuple[float, bool]:
        """
        Update EWMA with new observation.
        
        Args:
            value: New drift metric value (D_t)
            timestamp: Observation timestamp
            
        Returns:
            Tuple of (current_ewma, alarm_triggered)
        """
        timestamp = timestamp or datetime.now()
        
        if self._ewma is None:
            self._ewma = value
        else:
            self._ewma = self.lambda_ * value + (1 - self.lambda_) * self._ewma
        
        alarm = self._ewma > self.control_limit
        self._history.append((timestamp, value, self._ewma))
        
        return self._ewma, alarm
    
    def reset(self) -> None:
        """Reset the monitor."""
        self._ewma = None
        self._history = []
    
    def get_history(self) -> list[dict[str, Any]]:
        """Get monitoring history."""
        return [
            {
                "timestamp": ts.isoformat(),
                "value": val,
                "ewma": ewma,
                "alarm": ewma > self.control_limit,
            }
            for ts, val, ewma in self._history
        ]
    
    @property
    def current_ewma(self) -> Optional[float]:
        """Get current EWMA value."""
        return self._ewma


# =============================================================================
# Stochastic Surprise Gate (SSG) Framework
# =============================================================================

@dataclass
class HullWhiteState:
    """Hull-White model state for surprise analytics."""
    
    mean_reversion: float  # a: how fast the system returns to baseline
    long_run_mean: float  # θ: target value (can be time-dependent)
    volatility: float  # σ: current volatility estimate
    variance_estimate: float  # σ²_t for Z-score calculation
    last_prediction: float  # x̂_t: previous prediction
    
    # Time-dependent θ(t) parameters
    long_run_mean_schedule: str = "constant"  # constant, linear, piecewise
    linear_drift_rate: Optional[float] = None  # β in θ(t) = θ₀ + βt
    
    def get_theta(self, t: float = 0.0) -> float:
        """Get time-dependent long-run mean θ(t)."""
        if self.long_run_mean_schedule == "constant":
            return self.long_run_mean
        elif self.long_run_mean_schedule == "linear":
            beta = self.linear_drift_rate or 0.0
            return self.long_run_mean + beta * t
        else:
            return self.long_run_mean


@dataclass
class SurpriseResult:
    """Result of a surprise gate evaluation."""
    
    z_score: float
    p_value: float
    trigger: bool
    significance: str  # "normal", "noteworthy", "significant", "extreme"
    observed_value: float
    predicted_value: float
    residual: float
    audit_trail: dict[str, Any]
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "z_score": self.z_score,
            "p_value": self.p_value,
            "trigger": self.trigger,
            "significance": self.significance,
            "observed_value": self.observed_value,
            "predicted_value": self.predicted_value,
            "residual": self.residual,
            "audit_trail": self.audit_trail,
        }


@dataclass
class OnlineCalibrator:
    """
    Recursive calibrator for Hull-White model parameters.
    
    Uses recursive least squares (RLS) with exponential forgetting
    to adapt model parameters to the current environment.
    """
    
    forgetting_factor: float = 0.98  # λ ∈ [0.95, 0.99]
    
    # Parameter estimates
    mean_reversion_estimate: float = 0.5
    long_run_mean_estimate: float = 0.0
    volatility_estimate: float = 0.1
    
    # RLS state
    _P: float = 1.0  # Covariance estimate
    _observations: int = 0
    
    def update(self, x_t: float, x_hat: float, epsilon: float) -> None:
        """
        Update parameter estimates using new observation.
        
        Args:
            x_t: Actual observed value
            x_hat: Predicted value
            epsilon: Residual (x_t - x_hat)
        """
        self._observations += 1
        
        # Update covariance with forgetting
        self._P = (1 / self.forgetting_factor) * self._P
        
        # Compute Kalman gain
        K = self._P / (1 + self._P)
        
        # Update mean reversion estimate (simplified)
        if abs(x_t - self.long_run_mean_estimate) > 1e-9:
            self.mean_reversion_estimate += K * epsilon * (
                x_t - self.long_run_mean_estimate
            ) / max(abs(x_t - self.long_run_mean_estimate), 1e-9)
            self.mean_reversion_estimate = max(0.01, min(10.0, self.mean_reversion_estimate))
        
        # Update long-run mean estimate (slow adaptation)
        self.long_run_mean_estimate += 0.01 * K * epsilon
        
        # Update volatility using EWMA variance
        self.volatility_estimate = math.sqrt(
            self.forgetting_factor * self.volatility_estimate**2 +
            (1 - self.forgetting_factor) * epsilon**2
        )
        
        # Update covariance
        self._P = (1 - K) * self._P
    
    def get_state(self) -> dict[str, Any]:
        """Get current calibrator state."""
        return {
            "forgetting_factor": self.forgetting_factor,
            "covariance_estimate": self._P,
            "observations_since_reset": self._observations,
            "calibrator_version": "1.0.0",
        }
    
    def reset(self) -> None:
        """Reset calibrator state."""
        self._P = 1.0
        self._observations = 0


class HullWhiteSurpriseGate:
    """
    Stochastic Surprise Gate (SSG) implementation for drift detection.
    
    The SSG models drift-sensitive observables as evolving according to
    a Hull-White mean-reverting SDE:
    
        dx_t = a(θ(t) - x_t)dt + σdW_t
    
    Drift is detected when the Z-score (surprise) exceeds a threshold:
    
        Z_t = |ε_t| / σ_t  where ε_t = x_t - x̂_t
    
    Reference: Chapter 18, Section "Stochastic Surprise Gate (SSG) Framework"
    """
    
    # Significance classification thresholds
    SIGNIFICANCE_LEVELS = {
        "normal": (0.0, 1.0),
        "noteworthy": (1.0, 2.0),
        "significant": (2.0, 3.0),
        "extreme": (3.0, float("inf")),
    }
    
    def __init__(
        self,
        observable_type: str,
        mean_reversion: float = 0.5,
        long_run_mean: float = 0.0,
        initial_volatility: float = 0.1,
        forgetting_factor: float = 0.98,
        z_threshold: float = 2.0,
        sigma_min: float = 1e-9,
        time_dependent_theta: bool = False,
        linear_drift_rate: Optional[float] = None,
    ):
        """
        Initialize the Hull-White Surprise Gate.
        
        Args:
            observable_type: Type of artifact ("code", "schema", "prompt", "toon")
            mean_reversion: Speed of mean reversion 'a' (default 0.5)
            long_run_mean: Long-run mean θ (default 0.0)
            initial_volatility: Initial volatility estimate σ (default 0.1)
            forgetting_factor: Exponential forgetting λ (default 0.98)
            z_threshold: Z-score threshold for drift detection (default 2.0)
            sigma_min: Minimum volatility to prevent division by zero
            time_dependent_theta: Whether to use time-dependent θ(t)
            linear_drift_rate: β for θ(t) = θ₀ + βt (if time_dependent_theta)
        """
        self.observable_type = observable_type
        self.z_threshold = z_threshold
        self.sigma_min = sigma_min
        
        # Initialize Hull-White state
        self.state = HullWhiteState(
            mean_reversion=mean_reversion,
            long_run_mean=long_run_mean,
            volatility=initial_volatility,
            variance_estimate=initial_volatility**2,
            last_prediction=long_run_mean,
            long_run_mean_schedule="linear" if time_dependent_theta else "constant",
            linear_drift_rate=linear_drift_rate,
        )
        
        # Initialize online calibrator
        self.calibrator = OnlineCalibrator(
            forgetting_factor=forgetting_factor,
            mean_reversion_estimate=mean_reversion,
            long_run_mean_estimate=long_run_mean,
            volatility_estimate=initial_volatility,
        )
        
        # Observation history for analysis
        self._history: list[SurpriseResult] = []
        self._t: float = 0.0  # Time counter
    
    def observe(
        self,
        x_t: float,
        timestamp: Optional[datetime] = None,
        context: Optional[dict] = None,
    ) -> SurpriseResult:
        """
        Process a new observation and compute surprise.
        
        Args:
            x_t: The observed value at time t
            timestamp: Observation timestamp (default: now)
            context: Additional context for audit trail
            
        Returns:
            SurpriseResult containing Z-score, p-value, trigger decision, and audit trail
        """
        timestamp = timestamp or datetime.now()
        self._t += 1.0
        
        # Step 1: Get prediction from Hull-White model
        theta_t = self.state.get_theta(self._t)
        x_hat = self.state.last_prediction + self.state.mean_reversion * (
            theta_t - self.state.last_prediction
        )
        
        # Step 2: Compute residual (innovation)
        epsilon = x_t - x_hat
        
        # Step 3: Update volatility estimate (EWMA variance)
        self.state.variance_estimate = (
            self.calibrator.forgetting_factor * self.state.variance_estimate +
            (1 - self.calibrator.forgetting_factor) * epsilon**2
        )
        sigma_t = max(math.sqrt(self.state.variance_estimate), self.sigma_min)
        self.state.volatility = sigma_t
        
        # Step 4: Compute Z-score (surprise)
        z_score = abs(epsilon) / sigma_t
        
        # Step 5: Convert to p-value using error function
        try:
            from scipy.special import erfc
            p_value = erfc(z_score / math.sqrt(2))
        except ImportError:
            # Fallback approximation
            p_value = max(0.0, 1.0 - 0.5 * (1 + math.erf(z_score / math.sqrt(2))))
        
        # Step 6: Apply surprise gate
        trigger = z_score > self.z_threshold
        
        # Step 7: Classify significance
        significance = self._classify_significance(z_score)
        
        # Step 8: Update state for next prediction
        self.state.last_prediction = x_t
        
        # Step 9: Calibrate model if no trigger (adapt to normal behavior)
        if not trigger:
            self.calibrator.update(x_t, x_hat, epsilon)
            # Sync calibrator estimates to state
            self.state.mean_reversion = self.calibrator.mean_reversion_estimate
            self.state.long_run_mean = self.calibrator.long_run_mean_estimate
        
        # Step 10: Build audit trail
        audit_trail = self._build_audit_trail(
            x_t=x_t,
            x_hat=x_hat,
            epsilon=epsilon,
            z_score=z_score,
            p_value=p_value,
            significance=significance,
            trigger=trigger,
            timestamp=timestamp,
            context=context,
        )
        
        result = SurpriseResult(
            z_score=z_score,
            p_value=p_value,
            trigger=trigger,
            significance=significance,
            observed_value=x_t,
            predicted_value=x_hat,
            residual=epsilon,
            audit_trail=audit_trail,
        )
        
        self._history.append(result)
        return result
    
    def _classify_significance(self, z_score: float) -> str:
        """Classify Z-score into significance level."""
        for level, (low, high) in self.SIGNIFICANCE_LEVELS.items():
            if low <= z_score < high:
                return level
        return "extreme"
    
    def _build_audit_trail(
        self,
        x_t: float,
        x_hat: float,
        epsilon: float,
        z_score: float,
        p_value: float,
        significance: str,
        trigger: bool,
        timestamp: datetime,
        context: Optional[dict],
    ) -> dict[str, Any]:
        """Build immutable audit trail record."""
        audit_id = f"ssg-audit-{uuid.uuid4().hex[:12]}"
        
        metric_code_map = {
            "code": "TTS-M16",
            "schema": "TTS-M17",
            "prompt": "TTS-M18",
            "toon": "TTS-M19",
        }
        
        return {
            "audit_id": audit_id,
            "timestamp": timestamp.isoformat(),
            "observable_type": self.observable_type,
            "metric_code": metric_code_map.get(self.observable_type, "TTS-M16"),
            "observed_value": x_t,
            "predicted_value": x_hat,
            "residual": epsilon,
            "z_score": z_score,
            "p_value": p_value,
            "significance": significance,
            "trigger": trigger,
            "hull_white_state": {
                "mean_reversion": self.state.mean_reversion,
                "long_run_mean": self.state.long_run_mean,
                "long_run_mean_schedule": self.state.long_run_mean_schedule,
                "linear_drift_rate": self.state.linear_drift_rate,
                "volatility": self.state.volatility,
                "variance_estimate": self.state.variance_estimate,
                "last_prediction": self.state.last_prediction,
            },
            "calibrator_state": self.calibrator.get_state(),
            "context": context or {},
            "compliance": {
                "compliant_with": ["MAS-TRH-2024", "ISO-42001"],
                "retention_days": 2555,  # 7 years
                "immutable": True,
            },
        }
    
    def get_history(self) -> list[dict[str, Any]]:
        """Get observation history."""
        return [r.to_dict() for r in self._history]
    
    def reset(self) -> None:
        """Reset the surprise gate to initial state."""
        self.state.last_prediction = self.state.long_run_mean
        self.state.variance_estimate = self.state.volatility**2
        self.calibrator.reset()
        self._history = []
        self._t = 0.0
    
    @property
    def current_state(self) -> dict[str, Any]:
        """Get current model state."""
        return {
            "observable_type": self.observable_type,
            "z_threshold": self.z_threshold,
            "observations": len(self._history),
            "hull_white_state": {
                "mean_reversion": self.state.mean_reversion,
                "long_run_mean": self.state.long_run_mean,
                "volatility": self.state.volatility,
            },
            "last_z_score": self._history[-1].z_score if self._history else None,
            "trigger_count": sum(1 for r in self._history if r.trigger),
        }


# =============================================================================
# Specialized Surprise Gates for Each Drift Area
# =============================================================================

class CodebaseSurpriseGate(HullWhiteSurpriseGate):
    """
    TTS-M16: Codebase Surprise Score (CSS)
    
    Monitors architecture constraint violations for AI coding agents.
    """
    
    def __init__(self, **kwargs):
        super().__init__(
            observable_type="code",
            mean_reversion=0.5,
            long_run_mean=0.0,  # Ideal: zero violations
            initial_volatility=1.0,
            z_threshold=2.0,
            **kwargs,
        )


class SchemaSurpriseGate(HullWhiteSurpriseGate):
    """
    TTS-M17: Schema Surprise Score (SSS-HW)
    
    Monitors HANA schema drift against Simula generator expectations.
    Supports time-dependent θ(t) for planned migrations.
    """
    
    def __init__(
        self,
        expected_drift_rate: float = 0.0,
        **kwargs,
    ):
        super().__init__(
            observable_type="schema",
            mean_reversion=0.3,  # Slower reversion (schema changes are rare)
            long_run_mean=0.0,
            initial_volatility=2.0,
            z_threshold=2.0,
            time_dependent_theta=expected_drift_rate > 0,
            linear_drift_rate=expected_drift_rate,
            **kwargs,
        )


class PromptSurpriseGate(HullWhiteSurpriseGate):
    """
    TTS-M18: Prompt Surprise Score (PSS)
    
    Monitors user/agent prompt drift from training distribution.
    Observable is embedding distance from training centroid.
    """
    
    def __init__(self, **kwargs):
        super().__init__(
            observable_type="prompt",
            mean_reversion=0.7,  # Faster reversion (prompts vary naturally)
            long_run_mean=0.0,
            initial_volatility=0.5,
            z_threshold=2.0,
            forgetting_factor=0.95,  # Adapt faster to prompt evolution
            **kwargs,
        )


class TOONSurpriseGate(HullWhiteSurpriseGate):
    """
    TTS-M19: Token Surprise Score (TSS)
    
    Monitors TOON token stream for unexpected structures.
    Observable is normalized token surprise: -log₂P(token) / H
    """
    
    def __init__(self, **kwargs):
        super().__init__(
            observable_type="toon",
            mean_reversion=0.9,  # Fast reversion (tokens are very frequent)
            long_run_mean=1.0,  # Normalized surprise centered at 1
            initial_volatility=0.3,
            z_threshold=2.0,
            forgetting_factor=0.99,  # Very slow adaptation (deterministic format)
            **kwargs,
        )


class TTSTrainingEvaluator:
    """
    Evaluate drift metrics during training data generation.
    
    This class implements the training-time drift evaluation described
    in Chapter 18 of the Simula specification.
    
    Example:
        evaluator = TTSTrainingEvaluator(schema_registry)
        report = await evaluator.evaluate_batch(examples)
        if report.tts_eval < 70:
            raise DriftError("TTS-EVAL below threshold")
    """
    
    def __init__(
        self,
        schema_registry: Any,  # SchemaRegistry when available
        embedding_model: str = "sentence-transformers/all-MiniLM-L6-v2",
    ):
        """
        Initialize the drift evaluator.
        
        Args:
            schema_registry: Registry containing HANA schema information
            embedding_model: Model for computing semantic embeddings
        """
        self.schema_registry = schema_registry
        self.embedding_model = embedding_model
        self._embedder = None  # Lazy load
    
    async def evaluate_batch(
        self,
        examples: list[Any],  # list[TrainingExample] when available
        baseline: Optional[TTSMetricReport] = None,
    ) -> TTSMetricReport:
        """
        Evaluate drift metrics for a batch of training examples.
        
        Args:
            examples: Training examples to evaluate
            baseline: Optional baseline for drift comparison
            
        Returns:
            Complete drift metric report
        """
        sample_size = len(examples)
        
        # Schema drift metrics
        scr = self._compute_schema_coverage(examples, sample_size)
        sss = self._compute_schema_staleness(sample_size)
        ctmr = self._compute_type_mismatch_rate(examples, sample_size)
        fkcr = self._compute_fk_consistency(examples, sample_size)
        
        schema_metrics = SchemaDriftMetrics(scr=scr, sss=sss, ctmr=ctmr, fkcr=fkcr)
        
        # Semantic drift metrics
        sas = await self._compute_semantic_alignment(examples, sample_size)
        ipr = await self._compute_intent_preservation(examples, sample_size)
        tds = self._compute_terminology_drift(examples, sample_size)
        arr = await self._compute_ambiguity_resolution(examples, sample_size)
        
        semantic_metrics = SemanticDriftMetrics(sas=sas, ipr=ipr, tds=tds, arr=arr)
        
        # Generation quality metrics
        esr = self._compute_execution_success(examples, sample_size)
        rfs = await self._compute_result_fidelity(examples, sample_size)
        
        # Distribution drift (requires baseline)
        cdd = self._compute_complexity_drift(examples, baseline, sample_size)
        tcd = self._compute_taxonomy_drift(examples, baseline, sample_size)
        
        quality_metrics = GenerationQualityMetrics(esr=esr, rfs=rfs, cdd=cdd, tcd=tcd)
        
        # Composite score
        tts_eval = self._compute_tts_eval(schema_metrics, semantic_metrics, quality_metrics)
        tts_eval_status = self._eval_to_status(tts_eval)
        
        # Generate report
        report = TTSMetricReport(
            report_id=f"tts-report-{uuid.uuid4().hex[:8]}",
            evaluated_at=datetime.now().isoformat(),
            sample_size=sample_size,
            confidence_level=0.95,
            evaluation_context="training",
            baseline_id=baseline.report_id if baseline else None,
            schema_drift_metrics=schema_metrics,
            semantic_drift_metrics=semantic_metrics,
            generation_quality_metrics=quality_metrics,
            tts_eval=tts_eval,
            tts_eval_status=tts_eval_status,
        )
        
        return report
    
    def _compute_schema_coverage(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Schema Coverage Rate (TTS-M01)."""
        # TODO: Implement actual schema coverage calculation
        # This requires parsing SQL and comparing to schema_registry
        
        # Placeholder implementation
        coverage = 0.90  # Would be computed from actual analysis
        
        return MetricValue.create(
            value=coverage,
            threshold=METRIC_THRESHOLDS["scr"]["threshold"],
            direction=METRIC_THRESHOLDS["scr"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_schema_staleness(self, sample_size: int) -> MetricValue:
        """Compute Schema Staleness Score (TTS-M02)."""
        # TODO: Implement actual staleness calculation
        # This requires tracking schema changes and training data sync times
        
        # Placeholder: 0 means perfectly in sync
        staleness = 0.0
        
        return MetricValue.create(
            value=staleness,
            threshold=METRIC_THRESHOLDS["sss"]["threshold"],
            direction=METRIC_THRESHOLDS["sss"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_type_mismatch_rate(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Column Type Mismatch Rate (TTS-M03)."""
        # TODO: Implement SQL parsing and type checking
        
        mismatch_rate = 0.01  # Placeholder
        
        return MetricValue.create(
            value=mismatch_rate,
            threshold=METRIC_THRESHOLDS["ctmr"]["threshold"],
            direction=METRIC_THRESHOLDS["ctmr"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_fk_consistency(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Foreign Key Consistency Rate (TTS-M04)."""
        # TODO: Implement JOIN validation against FK relationships
        
        consistency = 0.98  # Placeholder
        
        return MetricValue.create(
            value=consistency,
            threshold=METRIC_THRESHOLDS["fkcr"]["threshold"],
            direction=METRIC_THRESHOLDS["fkcr"]["direction"],
            sample_size=sample_size,
        )
    
    async def _compute_semantic_alignment(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Semantic Alignment Score (TTS-M05)."""
        # TODO: Implement embedding-based alignment calculation
        
        alignment = 0.85  # Placeholder
        
        return MetricValue.create(
            value=alignment,
            threshold=METRIC_THRESHOLDS["sas"]["threshold"],
            direction=METRIC_THRESHOLDS["sas"]["direction"],
            sample_size=sample_size,
        )
    
    async def _compute_intent_preservation(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Intent Preservation Rate (TTS-M06)."""
        # TODO: Implement critic-based intent evaluation
        
        preservation = 0.92  # Placeholder
        
        return MetricValue.create(
            value=preservation,
            threshold=METRIC_THRESHOLDS["ipr"]["threshold"],
            direction=METRIC_THRESHOLDS["ipr"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_terminology_drift(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Terminology Drift Score (TTS-M07)."""
        # TODO: Implement Jensen-Shannon divergence calculation
        
        drift = 0.08  # Placeholder
        
        return MetricValue.create(
            value=drift,
            threshold=METRIC_THRESHOLDS["tds"]["threshold"],
            direction=METRIC_THRESHOLDS["tds"]["direction"],
            sample_size=sample_size,
        )
    
    async def _compute_ambiguity_resolution(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Ambiguity Resolution Rate (TTS-M08)."""
        # TODO: Implement ambiguity detection and resolution evaluation
        
        resolution = 0.80  # Placeholder
        
        return MetricValue.create(
            value=resolution,
            threshold=METRIC_THRESHOLDS["arr"]["threshold"],
            direction=METRIC_THRESHOLDS["arr"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_execution_success(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Execution Success Rate (TTS-M09)."""
        # TODO: Track actual SQL execution results
        
        # Use quality signals if available
        success_count = sum(
            1 for ex in examples 
            if hasattr(ex, 'quality_signals') and 
            getattr(ex.quality_signals, 'sql_executable', True)
        ) if examples else sample_size
        
        success_rate = success_count / max(sample_size, 1)
        
        return MetricValue.create(
            value=success_rate,
            threshold=METRIC_THRESHOLDS["esr"]["threshold"],
            direction=METRIC_THRESHOLDS["esr"]["direction"],
            sample_size=sample_size,
        )
    
    async def _compute_result_fidelity(self, examples: list, sample_size: int) -> MetricValue:
        """Compute Result Fidelity Score (TTS-M10)."""
        # TODO: Compare expected vs actual query results
        
        fidelity = 0.88  # Placeholder
        
        return MetricValue.create(
            value=fidelity,
            threshold=METRIC_THRESHOLDS["rfs"]["threshold"],
            direction=METRIC_THRESHOLDS["rfs"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_complexity_drift(
        self, 
        examples: list, 
        baseline: Optional[TTSMetricReport],
        sample_size: int,
    ) -> MetricValue:
        """Compute Complexity Distribution Drift (TTS-M11)."""
        # TODO: Implement KL divergence calculation
        
        # Without baseline, drift is 0
        drift = 0.0 if baseline is None else 0.05  # Placeholder
        
        return MetricValue.create(
            value=drift,
            threshold=METRIC_THRESHOLDS["cdd"]["threshold"],
            direction=METRIC_THRESHOLDS["cdd"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_taxonomy_drift(
        self, 
        examples: list, 
        baseline: Optional[TTSMetricReport],
        sample_size: int,
    ) -> MetricValue:
        """Compute Taxonomy Coverage Drift (TTS-M12)."""
        # TODO: Compare taxonomy coverage to baseline
        
        drift = 0.0 if baseline is None else 0.02  # Placeholder
        
        return MetricValue.create(
            value=drift,
            threshold=METRIC_THRESHOLDS["tcd"]["threshold"],
            direction=METRIC_THRESHOLDS["tcd"]["direction"],
            sample_size=sample_size,
        )
    
    def _compute_tts_eval(
        self,
        schema: SchemaDriftMetrics,
        semantic: SemanticDriftMetrics,
        quality: GenerationQualityMetrics,
    ) -> float:
        """
        Compute composite TTS-EVAL score per Chapter 18 formula.
        
        TTS_EVAL = 100 * (positive contributions) - 100 * (negative contributions)
        """
        # Normalize SSS to 0-1 range (14 days max)
        sss_norm = min(schema.sss.value / 14.0, 1.0)
        
        # Positive contributions
        positive = (
            0.15 * schema.scr.value +
            0.10 * (1 - sss_norm) +
            0.10 * schema.fkcr.value +
            0.15 * semantic.sas.value +
            0.10 * semantic.ipr.value +
            0.15 * quality.esr.value +
            0.10 * quality.rfs.value +
            0.05 * semantic.arr.value
        )
        
        # Negative contributions (penalties)
        negative = (
            0.05 * schema.ctmr.value +
            0.03 * semantic.tds.value +
            0.02 * quality.cdd.value
        )
        
        return 100 * positive - 100 * negative
    
    @staticmethod
    def _eval_to_status(tts_eval: float) -> str:
        """Convert TTS-EVAL score to traffic-light status."""
        if tts_eval >= 85:
            return "GREEN"
        elif tts_eval >= 55:
            return "AMBER"
        else:
            return "RED"


# =============================================================================
# CLI Entry Point
# =============================================================================

def main():
    """CLI entry point for TTS drift evaluation."""
    import argparse
    import json
    import sys
    
    parser = argparse.ArgumentParser(
        description="Evaluate Text-to-SQL drift metrics",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--examples",
        required=True,
        help="Path to training examples JSONL file",
    )
    parser.add_argument(
        "--schema-registry",
        help="Path to schema registry JSON file",
    )
    parser.add_argument(
        "--baseline",
        help="Path to baseline report JSON file",
    )
    parser.add_argument(
        "--output",
        default="tts_drift_report.json",
        help="Output path for drift report",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=70.0,
        help="Minimum TTS-EVAL score to pass (default: 70)",
    )
    
    args = parser.parse_args()
    
    # TODO: Implement full CLI with actual file loading
    print(f"Would evaluate examples from: {args.examples}")
    print(f"Output to: {args.output}")
    print(f"Threshold: {args.threshold}")
    
    # Placeholder: Create a sample report
    # In production, this would load actual examples and evaluate
    print("\nNote: This is a stub implementation. Full implementation pending.")
    
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())