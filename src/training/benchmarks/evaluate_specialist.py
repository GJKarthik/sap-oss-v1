#!/usr/bin/env python3
"""
Comprehensive Evaluation Framework for SAP-OSS Specialist Models
Supports SQL accuracy, execution testing, and model comparison (A/B testing)
"""

import os
import sys
import json
import time
import argparse
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional, Tuple
from collections import defaultdict
import re

import torch
from datetime import datetime


@dataclass
class EvaluationMetrics:
    """Metrics for a single evaluation."""
    exact_match: float = 0.0
    sql_syntax_valid: float = 0.0
    execution_success: float = 0.0
    table_accuracy: float = 0.0
    column_accuracy: float = 0.0
    condition_accuracy: float = 0.0
    rouge_l: float = 0.0
    bleu: float = 0.0
    latency_ms: float = 0.0
    throughput_qps: float = 0.0
    total_samples: int = 0
    
    def to_dict(self):
        return asdict(self)


@dataclass  
class ComparisonResult:
    """Results from A/B model comparison."""
    model_a: str
    model_b: str
    metrics_a: EvaluationMetrics
    metrics_b: EvaluationMetrics
    winner: str = ""
    improvement_pct: Dict[str, float] = field(default_factory=dict)


# =============================================================================
# SQL PARSING AND VALIDATION
# =============================================================================

class SQLParser:
    """Parse and analyze SQL queries."""
    
    @staticmethod
    def extract_tables(sql: str) -> List[str]:
        """Extract table names from SQL."""
        # Match FROM and JOIN clauses
        tables = []
        sql_upper = sql.upper()
        
        # FROM table
        from_match = re.findall(r'FROM\s+([A-Z0-9_\.]+)', sql_upper)
        tables.extend(from_match)
        
        # JOIN table
        join_match = re.findall(r'JOIN\s+([A-Z0-9_\.]+)', sql_upper)
        tables.extend(join_match)
        
        return [t.strip() for t in tables]
    
    @staticmethod
    def extract_columns(sql: str) -> List[str]:
        """Extract column names from SELECT clause."""
        sql_upper = sql.upper()
        
        # Find SELECT ... FROM
        select_match = re.search(r'SELECT\s+(.+?)\s+FROM', sql_upper, re.DOTALL)
        if not select_match:
            return []
        
        select_clause = select_match.group(1)
        
        # Parse columns (simplified)
        columns = []
        for part in select_clause.split(','):
            # Remove aggregates and aliases
            col = re.sub(r'(SUM|COUNT|AVG|MAX|MIN|DISTINCT)\s*\(', '', part)
            col = re.sub(r'\)\s*AS\s+\w+', '', col)
            col = re.sub(r'\s+AS\s+\w+', '', col)
            col = col.strip()
            if col and col != '*':
                columns.append(col)
        
        return columns
    
    @staticmethod
    def extract_conditions(sql: str) -> List[str]:
        """Extract WHERE conditions."""
        sql_upper = sql.upper()
        
        # Find WHERE clause
        where_match = re.search(r'WHERE\s+(.+?)(?:GROUP BY|ORDER BY|LIMIT|$)', sql_upper, re.DOTALL)
        if not where_match:
            return []
        
        where_clause = where_match.group(1)
        
        # Split by AND/OR
        conditions = re.split(r'\s+AND\s+|\s+OR\s+', where_clause)
        return [c.strip() for c in conditions if c.strip()]
    
    @staticmethod
    def validate_syntax(sql: str) -> Tuple[bool, str]:
        """Basic SQL syntax validation."""
        sql = sql.strip().upper()
        
        # Must start with SELECT, INSERT, UPDATE, DELETE
        if not sql.startswith(('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'WITH')):
            return False, "Query must start with SELECT, INSERT, UPDATE, or DELETE"
        
        # Check balanced parentheses
        if sql.count('(') != sql.count(')'):
            return False, "Unbalanced parentheses"
        
        # Check for FROM clause in SELECT
        if sql.startswith('SELECT') and 'FROM' not in sql:
            return False, "SELECT query missing FROM clause"
        
        # Check for common errors
        if '  ' in sql:
            pass  # Double spaces are fine
        
        if sql.endswith(','):
            return False, "Query ends with comma"
        
        return True, "Valid"


class SQLExecutor:
    """Execute SQL queries (mock for testing)."""
    
    def __init__(self, connection_string: Optional[str] = None):
        self.connection_string = connection_string
        self.mock_mode = connection_string is None
    
    def execute(self, sql: str) -> Tuple[bool, any, str]:
        """Execute SQL and return (success, result, error_message)."""
        if self.mock_mode:
            # Mock execution - just validate syntax
            valid, msg = SQLParser.validate_syntax(sql)
            if valid:
                return True, {"rows": [], "columns": []}, ""
            else:
                return False, None, msg
        
        # Real execution (requires SAP HANA connection)
        try:
            import hdbcli.dbapi
            conn = hdbcli.dbapi.connect(self.connection_string)
            cursor = conn.cursor()
            cursor.execute(sql)
            result = cursor.fetchall()
            columns = [desc[0] for desc in cursor.description]
            return True, {"rows": result, "columns": columns}, ""
        except Exception as e:
            return False, None, str(e)


# =============================================================================
# METRICS CALCULATION
# =============================================================================

def calculate_exact_match(prediction: str, expected: str) -> bool:
    """Check if prediction exactly matches expected."""
    # Normalize whitespace
    pred_norm = ' '.join(prediction.split())
    exp_norm = ' '.join(expected.split())
    return pred_norm.upper() == exp_norm.upper()


def calculate_component_accuracy(prediction: str, expected: str) -> Dict[str, float]:
    """Calculate accuracy of SQL components."""
    pred_tables = set(SQLParser.extract_tables(prediction))
    exp_tables = set(SQLParser.extract_tables(expected))
    
    pred_cols = set(SQLParser.extract_columns(prediction))
    exp_cols = set(SQLParser.extract_columns(expected))
    
    pred_conds = set(SQLParser.extract_conditions(prediction))
    exp_conds = set(SQLParser.extract_conditions(expected))
    
    def jaccard(a, b):
        if not a and not b:
            return 1.0
        if not a or not b:
            return 0.0
        return len(a & b) / len(a | b)
    
    return {
        "table_accuracy": jaccard(pred_tables, exp_tables),
        "column_accuracy": jaccard(pred_cols, exp_cols),
        "condition_accuracy": jaccard(pred_conds, exp_conds),
    }


def calculate_rouge_l(prediction: str, expected: str) -> float:
    """Calculate ROUGE-L score."""
    def lcs_length(s1, s2):
        m, n = len(s1), len(s2)
        dp = [[0] * (n + 1) for _ in range(m + 1)]
        for i in range(1, m + 1):
            for j in range(1, n + 1):
                if s1[i-1] == s2[j-1]:
                    dp[i][j] = dp[i-1][j-1] + 1
                else:
                    dp[i][j] = max(dp[i-1][j], dp[i][j-1])
        return dp[m][n]
    
    pred_tokens = prediction.split()
    exp_tokens = expected.split()
    
    lcs = lcs_length(pred_tokens, exp_tokens)
    
    if len(pred_tokens) == 0 or len(exp_tokens) == 0:
        return 0.0
    
    precision = lcs / len(pred_tokens)
    recall = lcs / len(exp_tokens)
    
    if precision + recall == 0:
        return 0.0
    
    f1 = 2 * precision * recall / (precision + recall)
    return f1


def calculate_bleu(prediction: str, expected: str, max_n: int = 4) -> float:
    """Calculate BLEU score."""
    from collections import Counter
    import math
    
    pred_tokens = prediction.split()
    exp_tokens = expected.split()
    
    if len(pred_tokens) == 0:
        return 0.0
    
    # Calculate n-gram precision
    precisions = []
    for n in range(1, min(max_n + 1, len(pred_tokens) + 1)):
        pred_ngrams = Counter(tuple(pred_tokens[i:i+n]) for i in range(len(pred_tokens) - n + 1))
        exp_ngrams = Counter(tuple(exp_tokens[i:i+n]) for i in range(len(exp_tokens) - n + 1))
        
        overlap = sum((pred_ngrams & exp_ngrams).values())
        total = sum(pred_ngrams.values())
        
        if total > 0:
            precisions.append(overlap / total)
        else:
            precisions.append(0)
    
    if not precisions or all(p == 0 for p in precisions):
        return 0.0
    
    # Geometric mean
    log_precision = sum(math.log(p) if p > 0 else -float('inf') for p in precisions) / len(precisions)
    
    # Brevity penalty
    bp = 1.0 if len(pred_tokens) >= len(exp_tokens) else math.exp(1 - len(exp_tokens) / len(pred_tokens))
    
    bleu = bp * math.exp(log_precision) if log_precision > -float('inf') else 0.0
    return bleu


# =============================================================================
# EVALUATION ENGINE
# =============================================================================

class SpecialistEvaluator:
    """Evaluate specialist model performance."""
    
    def __init__(
        self,
        model_path: str,
        model_type: str = "qwen",  # qwen, nemotron
        device: str = "auto",
    ):
        self.model_path = model_path
        self.model_type = model_type
        self.device = device
        self.model = None
        self.tokenizer = None
        self.sql_executor = SQLExecutor()
    
    def load_model(self):
        """Load model and tokenizer."""
        from transformers import AutoModelForCausalLM, AutoTokenizer
        from peft import PeftModel
        
        print(f"Loading model from {self.model_path}...")
        
        # Check if it's a LoRA adapter or full model
        adapter_config = Path(self.model_path) / "adapter_config.json"
        
        if adapter_config.exists():
            # Load base model + adapter
            with open(adapter_config) as f:
                config = json.load(f)
            base_model_name = config.get("base_model_name_or_path", "")
            
            self.tokenizer = AutoTokenizer.from_pretrained(
                base_model_name,
                trust_remote_code=True,
            )
            
            base_model = AutoModelForCausalLM.from_pretrained(
                base_model_name,
                device_map="auto",
                torch_dtype=torch.float16,
                trust_remote_code=True,
            )
            
            self.model = PeftModel.from_pretrained(base_model, self.model_path)
        else:
            # Load full model
            self.tokenizer = AutoTokenizer.from_pretrained(
                self.model_path,
                trust_remote_code=True,
            )
            self.model = AutoModelForCausalLM.from_pretrained(
                self.model_path,
                device_map="auto",
                torch_dtype=torch.float16,
                trust_remote_code=True,
            )
        
        if self.tokenizer.pad_token is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token
        
        self.model.eval()
        print("Model loaded.")
    
    def generate(self, prompt: str, max_new_tokens: int = 256) -> Tuple[str, float]:
        """Generate response and return (response, latency_ms)."""
        if self.model is None:
            self.load_model()
        
        # Format prompt
        if self.model_type == "qwen":
            formatted = f"<|im_start|>user\n{prompt}\n<|im_end|>\n<|im_start|>assistant\n"
        else:
            formatted = f"<|im_start|>user\n{prompt}\n<|im_end|>\n<|im_start|>assistant\n"
        
        inputs = self.tokenizer(formatted, return_tensors="pt").to(self.model.device)
        
        start_time = time.perf_counter()
        
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                temperature=0.1,
                do_sample=False,
                pad_token_id=self.tokenizer.pad_token_id,
            )
        
        latency_ms = (time.perf_counter() - start_time) * 1000
        
        response = self.tokenizer.decode(outputs[0], skip_special_tokens=True)
        
        # Extract assistant response
        if "<|im_start|>assistant" in response:
            response = response.split("<|im_start|>assistant")[-1].strip()
        
        return response, latency_ms
    
    def evaluate(self, test_set: List[Dict]) -> EvaluationMetrics:
        """Evaluate model on test set."""
        metrics = EvaluationMetrics()
        metrics.total_samples = len(test_set)
        
        exact_matches = 0
        syntax_valid = 0
        execution_success = 0
        table_accs = []
        col_accs = []
        cond_accs = []
        rouge_ls = []
        bleus = []
        latencies = []
        
        for i, sample in enumerate(test_set):
            question = sample["question"]
            expected = sample["expected_sql"]
            
            # Generate prediction
            prediction, latency = self.generate(question)
            latencies.append(latency)
            
            # Exact match
            if calculate_exact_match(prediction, expected):
                exact_matches += 1
            
            # Syntax validation
            valid, _ = SQLParser.validate_syntax(prediction)
            if valid:
                syntax_valid += 1
            
            # Execution test
            success, _, _ = self.sql_executor.execute(prediction)
            if success:
                execution_success += 1
            
            # Component accuracy
            comp_acc = calculate_component_accuracy(prediction, expected)
            table_accs.append(comp_acc["table_accuracy"])
            col_accs.append(comp_acc["column_accuracy"])
            cond_accs.append(comp_acc["condition_accuracy"])
            
            # Text similarity
            rouge_ls.append(calculate_rouge_l(prediction, expected))
            bleus.append(calculate_bleu(prediction, expected))
            
            # Progress
            if (i + 1) % 10 == 0:
                print(f"Evaluated {i + 1}/{len(test_set)} samples...")
        
        # Aggregate metrics
        metrics.exact_match = exact_matches / len(test_set)
        metrics.sql_syntax_valid = syntax_valid / len(test_set)
        metrics.execution_success = execution_success / len(test_set)
        metrics.table_accuracy = sum(table_accs) / len(table_accs)
        metrics.column_accuracy = sum(col_accs) / len(col_accs)
        metrics.condition_accuracy = sum(cond_accs) / len(cond_accs)
        metrics.rouge_l = sum(rouge_ls) / len(rouge_ls)
        metrics.bleu = sum(bleus) / len(bleus)
        metrics.latency_ms = sum(latencies) / len(latencies)
        metrics.throughput_qps = 1000 / metrics.latency_ms if metrics.latency_ms > 0 else 0
        
        return metrics


# =============================================================================
# A/B COMPARISON
# =============================================================================

def compare_models(
    model_a_path: str,
    model_b_path: str,
    test_set: List[Dict],
    model_a_name: str = "Model A",
    model_b_name: str = "Model B",
) -> ComparisonResult:
    """Compare two models on the same test set."""
    print(f"\n{'=' * 60}")
    print(f"A/B Comparison: {model_a_name} vs {model_b_name}")
    print(f"{'=' * 60}")
    
    # Evaluate Model A
    print(f"\nEvaluating {model_a_name}...")
    eval_a = SpecialistEvaluator(model_a_path)
    metrics_a = eval_a.evaluate(test_set)
    
    # Evaluate Model B
    print(f"\nEvaluating {model_b_name}...")
    eval_b = SpecialistEvaluator(model_b_path)
    metrics_b = eval_b.evaluate(test_set)
    
    # Calculate improvements
    improvement = {}
    for metric in ["exact_match", "sql_syntax_valid", "execution_success", 
                   "table_accuracy", "column_accuracy", "rouge_l"]:
        a_val = getattr(metrics_a, metric)
        b_val = getattr(metrics_b, metric)
        if a_val > 0:
            improvement[metric] = ((b_val - a_val) / a_val) * 100
        else:
            improvement[metric] = 100.0 if b_val > 0 else 0.0
    
    # Determine winner based on weighted score
    weights = {
        "exact_match": 0.3,
        "execution_success": 0.3,
        "table_accuracy": 0.15,
        "column_accuracy": 0.15,
        "rouge_l": 0.1,
    }
    
    score_a = sum(getattr(metrics_a, m) * w for m, w in weights.items())
    score_b = sum(getattr(metrics_b, m) * w for m, w in weights.items())
    
    winner = model_b_name if score_b > score_a else model_a_name
    
    result = ComparisonResult(
        model_a=model_a_name,
        model_b=model_b_name,
        metrics_a=metrics_a,
        metrics_b=metrics_b,
        winner=winner,
        improvement_pct=improvement,
    )
    
    return result


def print_comparison_report(result: ComparisonResult):
    """Print formatted comparison report."""
    print(f"\n{'=' * 70}")
    print("COMPARISON REPORT")
    print(f"{'=' * 70}")
    
    print(f"\n{'Metric':<25} {result.model_a:<15} {result.model_b:<15} {'Δ':<10}")
    print("-" * 70)
    
    metrics = ["exact_match", "sql_syntax_valid", "execution_success",
               "table_accuracy", "column_accuracy", "condition_accuracy",
               "rouge_l", "bleu", "latency_ms"]
    
    for metric in metrics:
        a_val = getattr(result.metrics_a, metric)
        b_val = getattr(result.metrics_b, metric)
        
        if metric == "latency_ms":
            delta = f"{b_val - a_val:+.1f}ms"
        else:
            delta = f"{(b_val - a_val) * 100:+.1f}%"
        
        if metric == "latency_ms":
            print(f"{metric:<25} {a_val:<15.1f} {b_val:<15.1f} {delta:<10}")
        else:
            print(f"{metric:<25} {a_val*100:<14.1f}% {b_val*100:<14.1f}% {delta:<10}")
    
    print("-" * 70)
    print(f"\n🏆 WINNER: {result.winner}")
    print(f"\nKey Improvements ({result.model_b} vs {result.model_a}):")
    for metric, pct in sorted(result.improvement_pct.items(), key=lambda x: -x[1]):
        print(f"  {metric}: {pct:+.1f}%")


# =============================================================================
# TEST SET GENERATION
# =============================================================================

def generate_test_set(specialist_type: str, num_samples: int = 100) -> List[Dict]:
    """Generate test set for evaluation."""
    TEST_TEMPLATES = {
        "router": [
            {"question": "What was our revenue last quarter?", "expected_sql": "performance"},
            {"question": "Show total assets breakdown", "expected_sql": "balance_sheet"},
            {"question": "Get bond portfolio MtM", "expected_sql": "treasury"},
            {"question": "Financed emissions by sector", "expected_sql": "esg"},
        ],
        "performance": [
            {
                "question": "Total income for CIB in Q1 2025",
                "expected_sql": "SELECT SUM(AMOUNT) as TOTAL_INCOME FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN WHERE SEGMENT = 'CIB' AND PERIOD = 'Q1' AND YEAR = 2025"
            },
            {
                "question": "Show NII by region for FY2024",
                "expected_sql": "SELECT REGION, SUM(NII) as NET_INTEREST_INCOME FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN WHERE YEAR = 2024 GROUP BY REGION"
            },
        ],
        "treasury": [
            {
                "question": "Get MtM for ISIN US91282CGB19",
                "expected_sql": "SELECT SUM(MTM_VALUE) as TOTAL_MTM FROM TREASURY.POSITION WHERE ISIN = 'US91282CGB19'"
            },
        ],
        "esg": [
            {
                "question": "Financed emissions for ASEAN Dec 2024",
                "expected_sql": "SELECT SUM(FINANCED_EMISSION) FROM ESG.SF_FLAT WHERE BOOKING_LOCATION = 'ASEAN' AND PERIOD = '202412'"
            },
        ],
        "balance_sheet": [
            {
                "question": "CASA to TD ratio for Group",
                "expected_sql": "SELECT SUM(CASE WHEN ACCOUNT_TYPE = 'CASA' THEN AMOUNT END) / NULLIF(SUM(CASE WHEN ACCOUNT_TYPE = 'TD' THEN AMOUNT END), 0) FROM GL.FAGLFLEXT"
            },
        ],
    }
    
    templates = TEST_TEMPLATES.get(specialist_type, TEST_TEMPLATES["performance"])
    
    # Expand to requested size
    test_set = []
    while len(test_set) < num_samples:
        test_set.extend(templates)
    
    return test_set[:num_samples]


# =============================================================================
# CLI
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="Specialist Model Evaluation")
    
    subparsers = parser.add_subparsers(dest="command", help="Command")
    
    # Evaluate single model
    eval_parser = subparsers.add_parser("evaluate", help="Evaluate a model")
    eval_parser.add_argument("--model-path", required=True, help="Path to model")
    eval_parser.add_argument("--specialist", required=True, 
                            choices=["router", "performance", "balance_sheet", "treasury", "esg"])
    eval_parser.add_argument("--test-set", help="Path to test set JSON")
    eval_parser.add_argument("--num-samples", type=int, default=100)
    eval_parser.add_argument("--output", help="Output JSON file")
    
    # Compare two models
    compare_parser = subparsers.add_parser("compare", help="Compare two models")
    compare_parser.add_argument("--model-a", required=True, help="Path to model A")
    compare_parser.add_argument("--model-b", required=True, help="Path to model B")
    compare_parser.add_argument("--name-a", default="Baseline", help="Name for model A")
    compare_parser.add_argument("--name-b", default="Fine-tuned", help="Name for model B")
    compare_parser.add_argument("--specialist", required=True)
    compare_parser.add_argument("--test-set", help="Path to test set JSON")
    compare_parser.add_argument("--num-samples", type=int, default=100)
    compare_parser.add_argument("--output", help="Output JSON file")
    
    args = parser.parse_args()
    
    if args.command == "evaluate":
        # Load or generate test set
        if args.test_set:
            with open(args.test_set) as f:
                test_set = json.load(f)
        else:
            test_set = generate_test_set(args.specialist, args.num_samples)
        
        # Evaluate
        evaluator = SpecialistEvaluator(args.model_path)
        metrics = evaluator.evaluate(test_set)
        
        # Print results
        print(f"\n{'=' * 60}")
        print("EVALUATION RESULTS")
        print(f"{'=' * 60}")
        for key, value in metrics.to_dict().items():
            if key == "total_samples":
                print(f"{key}: {value}")
            elif key in ["latency_ms"]:
                print(f"{key}: {value:.1f}")
            else:
                print(f"{key}: {value*100:.1f}%")
        
        # Save results
        if args.output:
            with open(args.output, 'w') as f:
                json.dump(metrics.to_dict(), f, indent=2)
            print(f"\nResults saved to {args.output}")
    
    elif args.command == "compare":
        # Load or generate test set
        if args.test_set:
            with open(args.test_set) as f:
                test_set = json.load(f)
        else:
            test_set = generate_test_set(args.specialist, args.num_samples)
        
        # Compare
        result = compare_models(
            args.model_a, args.model_b, test_set,
            args.name_a, args.name_b
        )
        
        # Print report
        print_comparison_report(result)
        
        # Save results
        if args.output:
            output_data = {
                "model_a": result.model_a,
                "model_b": result.model_b,
                "winner": result.winner,
                "metrics_a": result.metrics_a.to_dict(),
                "metrics_b": result.metrics_b.to_dict(),
                "improvement_pct": result.improvement_pct,
            }
            with open(args.output, 'w') as f:
                json.dump(output_data, f, indent=2)
            print(f"\nResults saved to {args.output}")
    
    else:
        parser.print_help()


if __name__ == "__main__":
    main()