"""Evaluation module for benchmarking error detection performance."""

import pandas as pd
from typing import Dict, Optional, Set, Tuple, Union
from dataclasses import dataclass
from pathlib import Path
from loguru import logger


@dataclass
class EvaluationMetrics:
    """Container for evaluation metrics."""

    precision: float
    recall: float
    f1_score: float
    true_positives: int
    false_positives: int
    false_negatives: int
    total_violations_found: int
    total_ground_truth_violations: int


def extract_violation_cells(violations_df: pd.DataFrame) -> Set[Tuple[str, str, int]]:
    """
    Extract unique cell identifiers from a violations DataFrame.
    """
    cells = set()
    for _, row in violations_df.iterrows():
        # Skip rows with None index values
        if row["index"] is not None:
            cells.add((str(row["table_name"]), str(row["column"]), int(row["index"])))
    return cells


class Evaluation:
    """
    Evaluation class for measuring error detection performance.

    This class compares detected violations against ground truth to calculate
    precision, recall, and F1 scores.
    """

    def __init__(self, ground_truth: pd.DataFrame, predictions: pd.DataFrame):
        """
        Initialize evaluation with ground truth and predictions.

        Parameters
        ----------
        ground_truth : pd.DataFrame
            DataFrame with all ground truth violations (standard corruption columns)
        predictions : pd.DataFrame
            DataFrame with all predicted violations (standard corruption columns)
        """
        self.ground_truth = ground_truth
        self.predictions = predictions

    def calculate_metrics(self, check_name: Optional[str] = None) -> EvaluationMetrics:
        """
        Calculate precision, recall, and F1 score based on cell-level comparison.

        Compares violations at the cell level using (table_name, column, index) tuples,
        ignoring check names and failure_case values. This allows proper evaluation
        even when different checks find the same violations.

        Parameters
        ----------
        check_name : Optional[str]
            If provided, only evaluate violations from this specific check in predictions.
            If None, evaluates all violations (overall metrics).

        Returns
        -------
        EvaluationMetrics
            Evaluation metrics including precision, recall, F1 score
        """
        # Extract all ground truth cells (regardless of check name)
        # This is our reference set of actual violations
        all_gt_cells = extract_violation_cells(self.ground_truth)

        if check_name is None:
            # Overall metrics: compare all predictions against all ground truth
            pred_cells = extract_violation_cells(self.predictions)
        else:
            # Per-check metrics: filter predictions by check name, but compare against ALL ground truth
            if "check" in self.predictions.columns and check_name in self.predictions["check"].values:
                pred_violations = self.predictions[self.predictions["check"] == check_name]
                pred_cells = extract_violation_cells(pred_violations)
            else:
                # This check doesn't exist in predictions
                pred_cells = set()

        # Calculate metrics by comparing cell sets
        # True positives: cells that appear in both ground truth and predictions
        true_positives = len(all_gt_cells & pred_cells)
        # False positives: cells in predictions but not in ground truth
        false_positives = len(pred_cells - all_gt_cells)
        # False negatives: cells in ground truth but not in predictions
        false_negatives = len(all_gt_cells - pred_cells)

        # Calculate precision, recall, and F1
        precision = (
            true_positives / (true_positives + false_positives) if (true_positives + false_positives) > 0 else 0.0
        )
        recall = true_positives / (true_positives + false_negatives) if (true_positives + false_negatives) > 0 else 0.0
        f1_score = 2 * (precision * recall) / (precision + recall) if (precision + recall) > 0 else 0.0

        return EvaluationMetrics(
            precision=precision,
            recall=recall,
            f1_score=f1_score,
            true_positives=true_positives,
            false_positives=false_positives,
            false_negatives=false_negatives,
            total_violations_found=len(pred_cells),
            total_ground_truth_violations=len(all_gt_cells),
        )

    def evaluate_all_checks(self) -> Dict[str, EvaluationMetrics]:
        """
        Evaluate each check individually.

        Returns
        -------
        Dict[str, EvaluationMetrics]
            Dictionary mapping check names to their evaluation metrics
        """
        results = {}

        # Get all unique check names from both DataFrames
        all_checks = set()
        if "check" in self.ground_truth.columns:
            all_checks.update(self.ground_truth["check"].unique())
        if "check" in self.predictions.columns:
            all_checks.update(self.predictions["check"].unique())

        for check_name in all_checks:
            results[check_name] = self.calculate_metrics(check_name)

        return results

    def generate_report(self) -> pd.DataFrame:
        """
        Generate a comprehensive evaluation report as DataFrame.

        Returns
        -------
        pd.DataFrame
            Report with metrics for each check and overall performance
        """
        rows = []

        # Evaluate individual checks
        check_metrics = self.evaluate_all_checks()
        for check_name, metrics in check_metrics.items():
            rows.append(
                {
                    "check_name": check_name,
                    "precision": round(metrics.precision, 4),
                    "recall": round(metrics.recall, 4),
                    "f1_score": round(metrics.f1_score, 4),
                    "true_positives": metrics.true_positives,
                    "false_positives": metrics.false_positives,
                    "false_negatives": metrics.false_negatives,
                    "violations_found": metrics.total_violations_found,
                    "ground_truth_violations": metrics.total_ground_truth_violations,
                }
            )

        # Add overall metrics
        overall_metrics = self.calculate_metrics()
        rows.append(
            {
                "check_name": "OVERALL",
                "precision": round(overall_metrics.precision, 4),
                "recall": round(overall_metrics.recall, 4),
                "f1_score": round(overall_metrics.f1_score, 4),
                "true_positives": overall_metrics.true_positives,
                "false_positives": overall_metrics.false_positives,
                "false_negatives": overall_metrics.false_negatives,
                "violations_found": overall_metrics.total_violations_found,
                "ground_truth_violations": overall_metrics.total_ground_truth_violations,
            }
        )

        return pd.DataFrame(rows)

    def generate_report_for_checks(
        self, check_names: Set[str], check_results: Dict[str, Union[pd.DataFrame, Exception]]
    ) -> pd.DataFrame:
        """
        Generate evaluation report for specific checks only.

        Parameters
        ----------
        check_names : Set[str]
            Set of check names to include in the report
        check_results : Dict[str, Union[pd.DataFrame, Exception]]
            All check results to determine runnability

        Returns
        -------
        pd.DataFrame
            Report with metrics for specified checks and overall performance
        """
        rows = []

        # Evaluate only specified checks
        for check_name in check_names:
            # Determine if check is runnable
            is_runnable = check_name in check_results and not isinstance(check_results[check_name], Exception)

            # Calculate metrics for this check
            metrics = self.calculate_metrics(check_name)

            rows.append(
                {
                    "check_name": check_name,
                    "is_runnable": is_runnable,
                    "precision": round(metrics.precision, 4),
                    "recall": round(metrics.recall, 4),
                    "f1_score": round(metrics.f1_score, 4),
                    "true_positives": metrics.true_positives,
                    "false_positives": metrics.false_positives,
                    "false_negatives": metrics.false_negatives,
                    "violations_found": metrics.total_violations_found,
                    "ground_truth_violations": metrics.total_ground_truth_violations,
                }
            )

        # Add overall metrics
        overall_metrics = self.calculate_metrics()
        rows.append(
            {
                "check_name": "OVERALL",
                "is_runnable": True,  # Overall is always "runnable"
                "precision": round(overall_metrics.precision, 4),
                "recall": round(overall_metrics.recall, 4),
                "f1_score": round(overall_metrics.f1_score, 4),
                "true_positives": overall_metrics.true_positives,
                "false_positives": overall_metrics.false_positives,
                "false_negatives": overall_metrics.false_negatives,
                "violations_found": overall_metrics.total_violations_found,
                "ground_truth_violations": overall_metrics.total_ground_truth_violations,
            }
        )

        return pd.DataFrame(rows)

    def save_report(self, output_path: str, format: str = "csv") -> None:
        """
        Save evaluation report to file.

        Parameters
        ----------
        output_path : str
            Path to save the report
        format : str
            Output format ('csv' or 'json')
        """
        report = self.generate_report()

        if format == "csv":
            report.to_csv(output_path, index=False)
        elif format == "json":
            report.to_json(output_path, orient="records", indent=2)
        else:
            raise ValueError(f"Unsupported format: {format}")

        logger.info(f"Evaluation report saved to {output_path}")


def load_violations_from_file(file_path: str) -> pd.DataFrame:
    """
    Load violations DataFrame from a CSV file with proper type handling.

    This function handles potential data type issues like leading zeros
    by first reading all columns as strings, then applying appropriate
    type inference for numeric columns while preserving string columns
    that may contain leading zeros (like dates in YYYYMMDD format).

    Parameters
    ----------
    file_path : str
        Path to the violations CSV file

    Returns
    -------
    pd.DataFrame
        DataFrame with violation records
    """
    path = Path(file_path)

    if not path.exists():
        logger.warning(f"File not found: {file_path}")
        from definition.base.corruption import COLUMNS

        return pd.DataFrame(columns=COLUMNS)

    try:
        # First read everything as string to preserve leading zeros
        df = pd.read_csv(path, dtype=str)

        # Define columns that should remain as strings (to preserve leading zeros)
        # These are typically date columns or ID columns that might have leading zeros
        string_columns = {"failure_case"}  # failure_case might contain dates like '00000000'

        # Define columns that should be numeric
        numeric_columns = {"check_number", "index"}

        # Define columns that should be boolean
        boolean_columns = {"from_pandera"}

        # Convert numeric columns
        for col in numeric_columns:
            if col in df.columns:
                # Use pd.to_numeric with errors='coerce' to handle invalid values
                df[col] = pd.to_numeric(df[col], errors="coerce")

        # Convert boolean columns
        for col in boolean_columns:
            if col in df.columns:
                # Map string representations to boolean
                df[col] = df[col].map(
                    {"True": True, "true": True, "False": False, "false": False, "1": True, "0": False}
                )
                # Fill any remaining NaN values with False
                df[col] = df[col].fillna(False)

        # For all other columns not explicitly handled, let pandas infer the type
        # but exclude the string columns we want to preserve
        other_columns = set(df.columns) - string_columns - numeric_columns - boolean_columns
        for col in other_columns:
            if col not in {"table_name", "schema_context", "column", "check"}:  # Keep these as strings
                # Try to infer type, but if it fails, keep as string
                try:
                    df[col] = df[col].infer_objects()
                except:
                    pass

        logger.info(f"Loaded {len(df)} violations from {file_path}")
        return df
    except Exception as e:
        logger.error(f"Failed to load {file_path}: {e}")
        from definition.base.corruption import COLUMNS

        return pd.DataFrame(columns=COLUMNS)


def evaluate_benchmark(
    ground_truth_file: str, predictions_file: str, output_path: Optional[str] = None
) -> EvaluationMetrics:
    """
    Evaluate benchmark performance by comparing predictions against ground truth.

    Parameters
    ----------
    ground_truth_file : str
        Path to ground truth violations CSV file
    predictions_file : str
        Path to predicted violations CSV file
    output_path : Optional[str]
        Path to save evaluation report (if provided)

    Returns
    -------
    EvaluationMetrics
        Overall evaluation metrics
    """
    # Load ground truth and predictions
    ground_truth = load_violations_from_file(ground_truth_file)
    predictions = load_violations_from_file(predictions_file)

    logger.info(f"Loaded {len(ground_truth)} ground truth violations and {len(predictions)} predicted violations")

    # Create evaluator
    evaluator = Evaluation(ground_truth, predictions)

    # Generate and optionally save report
    if output_path:
        evaluator.save_report(output_path)

    # Return overall metrics
    return evaluator.calculate_metrics()
