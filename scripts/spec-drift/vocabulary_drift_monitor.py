#!/usr/bin/env python3
"""
Vocabulary Drift Monitor - Detect when user vocabulary diverges from training vocabulary.

This module addresses the meeting requirement:
"As users and international deployments grow, metrics + UI alerts will detect when 
user language diverges from training corpus."

Usage:
    # Analyze vocabulary drift from user queries
    python3 scripts/spec-drift/vocabulary_drift_monitor.py --user-queries queries.jsonl

    # Compare training corpus against production usage
    python3 scripts/spec-drift/vocabulary_drift_monitor.py --training-corpus train.jsonl --production-log prod.jsonl

    # Generate drift metrics report
    python3 scripts/spec-drift/vocabulary_drift_monitor.py --report --output-format json

Author: Spec-Drift Auditor Agent
Version: 1.0.0
"""

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

import yaml

# =============================================================================
# CONSTANTS
# =============================================================================

VOCABULARY_REGISTRY_PATH = "docs/schema/common/synonyms.yaml"
VOCAB_METRICS_DB_PATH = "docs/audit-logs/vocabulary_metrics.db"

# Drift thresholds (from vocabulary registry metadata)
DEFAULT_DIVERGENCE_WARNING = 0.20  # 20%
DEFAULT_DIVERGENCE_ALERT = 0.30    # 30%
DEFAULT_OOV_WARNING = 0.10         # 10%
DEFAULT_OOV_ALERT = 0.20           # 20%

# Minimum sample size for meaningful drift detection
MIN_SAMPLE_SIZE = 100

# Token normalization
STOPWORDS = {
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could',
    'should', 'may', 'might', 'must', 'can', 'to', 'of', 'in', 'for',
    'on', 'with', 'at', 'by', 'from', 'as', 'or', 'and', 'but', 'if',
    'then', 'else', 'when', 'where', 'why', 'how', 'what', 'which', 'who',
    'this', 'that', 'these', 'those', 'it', 'its', 'my', 'your', 'our',
    'their', 'me', 'you', 'him', 'her', 'us', 'them', 'i', 'we', 'he',
    'she', 'they', 'all', 'each', 'every', 'both', 'few', 'more', 'most',
    'other', 'some', 'such', 'no', 'nor', 'not', 'only', 'own', 'same',
    'so', 'than', 'too', 'very', 'just', 'also', 'now', 'here', 'there',
}


# =============================================================================
# ENUMS & DATA CLASSES
# =============================================================================

class DriftStatus(Enum):
    """Overall drift status."""
    HEALTHY = "healthy"           # < warning threshold
    WARNING = "warning"           # >= warning, < alert
    ALERT = "alert"               # >= alert threshold
    CRITICAL = "critical"         # Severe drift requiring immediate action


class DriftType(Enum):
    """Type of vocabulary drift detected."""
    OOV_RATE = "oov_rate"                     # Out-of-vocabulary rate
    VOCABULARY_DIVERGENCE = "divergence"      # Overall vocabulary divergence
    NEW_TERMS = "new_terms"                   # New terms appearing
    DEPRECATED_USAGE = "deprecated_usage"     # Use of deprecated terms
    LOCALE_GAP = "locale_gap"                 # Missing locale coverage


@dataclass
class VocabularyCorpus:
    """Represents a vocabulary corpus extracted from text."""
    name: str
    terms: Counter  # term -> frequency
    total_tokens: int
    unique_terms: int
    source: str
    timestamp: str
    locale: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "total_tokens": self.total_tokens,
            "unique_terms": self.unique_terms,
            "source": self.source,
            "timestamp": self.timestamp,
            "locale": self.locale,
            "top_terms": dict(self.terms.most_common(100)),
        }


@dataclass
class DriftMetric:
    """A single drift metric."""
    metric_type: DriftType
    value: float
    threshold_warning: float
    threshold_alert: float
    status: DriftStatus
    details: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": self.metric_type.value,
            "value": round(self.value, 4),
            "threshold_warning": self.threshold_warning,
            "threshold_alert": self.threshold_alert,
            "status": self.status.value,
            "details": self.details,
        }


@dataclass
class VocabularyDriftReport:
    """Complete vocabulary drift report."""
    report_id: str
    timestamp: str
    training_corpus: VocabularyCorpus
    production_corpus: VocabularyCorpus
    overall_status: DriftStatus
    metrics: List[DriftMetric]
    oov_terms: List[str]
    new_terms: List[str]
    deprecated_terms_used: List[str]
    recommendations: List[str]
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "report_id": self.report_id,
            "timestamp": self.timestamp,
            "overall_status": self.overall_status.value,
            "training_corpus": self.training_corpus.to_dict(),
            "production_corpus": self.production_corpus.to_dict(),
            "metrics": [m.to_dict() for m in self.metrics],
            "oov_terms": self.oov_terms[:50],  # Limit for readability
            "oov_terms_count": len(self.oov_terms),
            "new_terms": self.new_terms[:50],
            "new_terms_count": len(self.new_terms),
            "deprecated_terms_used": self.deprecated_terms_used,
            "recommendations": self.recommendations,
        }


# =============================================================================
# VOCABULARY LOADING
# =============================================================================

def load_vocabulary_registry(path: str = VOCABULARY_REGISTRY_PATH) -> Dict[str, Any]:
    """Load the vocabulary registry."""
    registry_path = Path(path)
    if not registry_path.exists():
        return {}
    
    with open(registry_path, "r") as f:
        return yaml.safe_load(f)


def extract_known_vocabulary(vocab_registry: Dict[str, Any]) -> Set[str]:
    """Extract all known vocabulary terms from registry."""
    terms = set()
    
    # Global synonyms
    for entry in vocab_registry.get("global_synonyms", []):
        terms.add(entry.get("canonical", "").lower())
        for syn in entry.get("synonyms", []):
            terms.add(syn.lower())
    
    # Domain terms
    for domain in vocab_registry.get("domains", {}).values():
        for term in domain.get("canonical_terms", []):
            terms.add(term.get("canonical", "").lower())
            for var in term.get("variations", []):
                terms.add(var.lower())
            for form in term.get("training_forms", []):
                terms.add(form.lower())
                
        for tech in domain.get("technical_terms", []):
            terms.add(tech.get("technical_name", "").lower())
            terms.add(tech.get("human_name", "").lower())
            for syn in tech.get("synonyms", []):
                terms.add(syn.lower())
                
        for entity in domain.get("entity_mappings", []):
            terms.add(entity.get("name", "").lower())
            terms.add(entity.get("code", "").lower())
            for var in entity.get("variations", []):
                terms.add(var.lower())
    
    # Abbreviations
    for abbrev in vocab_registry.get("abbreviations", []):
        terms.add(abbrev.get("abbreviation", "").lower())
        terms.add(abbrev.get("expansion", "").lower())
    
    # Remove empty strings
    terms.discard("")
    
    return terms


def extract_deprecated_terms(vocab_registry: Dict[str, Any]) -> Set[str]:
    """Extract deprecated terms from registry."""
    deprecated = set()
    
    for domain in vocab_registry.get("domains", {}).values():
        for term in domain.get("canonical_terms", []):
            for dep in term.get("deprecated_forms", []):
                deprecated.add(dep.lower())
    
    return deprecated


def get_drift_thresholds(vocab_registry: Dict[str, Any]) -> Dict[str, float]:
    """Get drift thresholds from registry metadata."""
    metadata = vocab_registry.get("metadata", {})
    thresholds = metadata.get("drift_thresholds", {})
    
    return {
        "divergence_warning": thresholds.get("vocabulary_divergence_warning", DEFAULT_DIVERGENCE_WARNING),
        "divergence_alert": thresholds.get("vocabulary_divergence_alert", DEFAULT_DIVERGENCE_ALERT),
        "oov_warning": thresholds.get("oov_rate_warning", DEFAULT_OOV_WARNING),
        "oov_alert": thresholds.get("oov_rate_alert", DEFAULT_OOV_ALERT),
    }


# =============================================================================
# TEXT PROCESSING
# =============================================================================

def tokenize(text: str) -> List[str]:
    """Simple tokenization of text."""
    # Convert to lowercase
    text = text.lower()
    
    # Replace punctuation with spaces
    text = re.sub(r'[^\w\s]', ' ', text)
    
    # Split on whitespace
    tokens = text.split()
    
    # Filter stopwords and short tokens
    tokens = [t for t in tokens if t not in STOPWORDS and len(t) > 1]
    
    return tokens


def extract_ngrams(tokens: List[str], n: int = 2) -> List[str]:
    """Extract n-grams from token list."""
    ngrams = []
    for i in range(len(tokens) - n + 1):
        ngram = '_'.join(tokens[i:i+n])
        ngrams.append(ngram)
    return ngrams


def extract_vocabulary_from_text(text: str) -> Counter:
    """Extract vocabulary frequency from text."""
    tokens = tokenize(text)
    
    # Also extract bigrams for multi-word terms
    bigrams = extract_ngrams(tokens, 2)
    
    vocab = Counter(tokens)
    vocab.update(bigrams)
    
    return vocab


def extract_vocabulary_from_jsonl(
    filepath: str,
    text_fields: List[str] = None,
) -> VocabularyCorpus:
    """Extract vocabulary from a JSONL file."""
    if text_fields is None:
        text_fields = ["question", "query", "text", "content", "prompt", "input"]
    
    all_vocab = Counter()
    total_tokens = 0
    
    path = Path(filepath)
    if not path.exists():
        return VocabularyCorpus(
            name=path.stem,
            terms=Counter(),
            total_tokens=0,
            unique_terms=0,
            source=filepath,
            timestamp=datetime.now().isoformat(),
        )
    
    with open(path, "r") as f:
        for line in f:
            try:
                record = json.loads(line.strip())
                
                # Extract text from known fields
                texts = []
                for field in text_fields:
                    if field in record and isinstance(record[field], str):
                        texts.append(record[field])
                
                for text in texts:
                    vocab = extract_vocabulary_from_text(text)
                    all_vocab.update(vocab)
                    total_tokens += sum(vocab.values())
                    
            except json.JSONDecodeError:
                continue
    
    return VocabularyCorpus(
        name=path.stem,
        terms=all_vocab,
        total_tokens=total_tokens,
        unique_terms=len(all_vocab),
        source=filepath,
        timestamp=datetime.now().isoformat(),
    )


def extract_vocabulary_from_queries(queries: List[str]) -> VocabularyCorpus:
    """Extract vocabulary from a list of query strings."""
    all_vocab = Counter()
    total_tokens = 0
    
    for query in queries:
        vocab = extract_vocabulary_from_text(query)
        all_vocab.update(vocab)
        total_tokens += sum(vocab.values())
    
    return VocabularyCorpus(
        name="user_queries",
        terms=all_vocab,
        total_tokens=total_tokens,
        unique_terms=len(all_vocab),
        source="queries",
        timestamp=datetime.now().isoformat(),
    )


# =============================================================================
# DRIFT CALCULATION
# =============================================================================

def calculate_vocabulary_overlap(
    corpus1: VocabularyCorpus,
    corpus2: VocabularyCorpus,
) -> float:
    """Calculate Jaccard similarity between two vocabularies."""
    terms1 = set(corpus1.terms.keys())
    terms2 = set(corpus2.terms.keys())
    
    if not terms1 or not terms2:
        return 0.0
    
    intersection = len(terms1 & terms2)
    union = len(terms1 | terms2)
    
    return intersection / union if union > 0 else 0.0


def calculate_oov_rate(
    production_corpus: VocabularyCorpus,
    known_vocabulary: Set[str],
) -> Tuple[float, List[str]]:
    """Calculate out-of-vocabulary rate for production corpus.
    
    Returns:
        - OOV rate (0.0 - 1.0)
        - List of OOV terms
    """
    production_terms = set(production_corpus.terms.keys())
    oov_terms = production_terms - known_vocabulary
    
    if not production_terms:
        return 0.0, []
    
    oov_rate = len(oov_terms) / len(production_terms)
    
    # Sort OOV terms by frequency (most common first)
    oov_sorted = sorted(
        oov_terms,
        key=lambda t: production_corpus.terms.get(t, 0),
        reverse=True,
    )
    
    return oov_rate, oov_sorted


def calculate_divergence(
    training_corpus: VocabularyCorpus,
    production_corpus: VocabularyCorpus,
) -> float:
    """Calculate vocabulary divergence using frequency distribution comparison.
    
    Uses a simplified KL-divergence inspired metric.
    """
    training_terms = set(training_corpus.terms.keys())
    production_terms = set(production_corpus.terms.keys())
    
    if not training_terms or not production_terms:
        return 1.0
    
    # Calculate overlap ratio
    overlap = training_terms & production_terms
    overlap_ratio = len(overlap) / len(production_terms) if production_terms else 0
    
    # Calculate frequency distribution similarity for overlapping terms
    freq_similarity = 0.0
    if overlap:
        training_total = sum(training_corpus.terms[t] for t in overlap)
        production_total = sum(production_corpus.terms[t] for t in overlap)
        
        for term in overlap:
            train_freq = training_corpus.terms[term] / training_total if training_total > 0 else 0
            prod_freq = production_corpus.terms[term] / production_total if production_total > 0 else 0
            
            # Simple frequency ratio (bounded)
            if train_freq > 0 and prod_freq > 0:
                ratio = min(train_freq, prod_freq) / max(train_freq, prod_freq)
                freq_similarity += ratio
        
        freq_similarity = freq_similarity / len(overlap)
    
    # Combine overlap and frequency similarity
    divergence = 1.0 - (0.6 * overlap_ratio + 0.4 * freq_similarity)
    
    return max(0.0, min(1.0, divergence))


def identify_new_terms(
    training_corpus: VocabularyCorpus,
    production_corpus: VocabularyCorpus,
    min_frequency: int = 3,
) -> List[str]:
    """Identify new terms in production not in training.
    
    Returns terms sorted by frequency (most common first).
    """
    training_terms = set(training_corpus.terms.keys())
    production_terms = set(production_corpus.terms.keys())
    
    new_terms = production_terms - training_terms
    
    # Filter by minimum frequency
    new_terms = [t for t in new_terms if production_corpus.terms.get(t, 0) >= min_frequency]
    
    # Sort by frequency
    new_terms = sorted(
        new_terms,
        key=lambda t: production_corpus.terms.get(t, 0),
        reverse=True,
    )
    
    return new_terms


def check_deprecated_usage(
    production_corpus: VocabularyCorpus,
    deprecated_terms: Set[str],
) -> List[str]:
    """Check if deprecated terms are being used in production."""
    production_terms = set(production_corpus.terms.keys())
    
    used_deprecated = production_terms & deprecated_terms
    
    # Sort by frequency
    return sorted(
        used_deprecated,
        key=lambda t: production_corpus.terms.get(t, 0),
        reverse=True,
    )


def determine_status(value: float, warning: float, alert: float) -> DriftStatus:
    """Determine drift status based on thresholds."""
    if value >= alert * 1.5:
        return DriftStatus.CRITICAL
    elif value >= alert:
        return DriftStatus.ALERT
    elif value >= warning:
        return DriftStatus.WARNING
    else:
        return DriftStatus.HEALTHY


# =============================================================================
# DRIFT ANALYSIS
# =============================================================================

def analyze_vocabulary_drift(
    training_corpus: VocabularyCorpus,
    production_corpus: VocabularyCorpus,
    vocab_registry: Dict[str, Any],
) -> VocabularyDriftReport:
    """Perform complete vocabulary drift analysis."""
    thresholds = get_drift_thresholds(vocab_registry)
    known_vocabulary = extract_known_vocabulary(vocab_registry)
    deprecated_terms = extract_deprecated_terms(vocab_registry)
    
    metrics = []
    recommendations = []
    overall_statuses = []
    
    # Metric 1: OOV Rate
    oov_rate, oov_terms = calculate_oov_rate(production_corpus, known_vocabulary)
    oov_status = determine_status(oov_rate, thresholds["oov_warning"], thresholds["oov_alert"])
    overall_statuses.append(oov_status)
    
    metrics.append(DriftMetric(
        metric_type=DriftType.OOV_RATE,
        value=oov_rate,
        threshold_warning=thresholds["oov_warning"],
        threshold_alert=thresholds["oov_alert"],
        status=oov_status,
        details={
            "oov_count": len(oov_terms),
            "total_unique_terms": production_corpus.unique_terms,
            "top_oov_terms": oov_terms[:10],
        },
    ))
    
    if oov_status in (DriftStatus.ALERT, DriftStatus.CRITICAL):
        recommendations.append(
            f"OOV rate is {oov_rate:.1%}. Add top OOV terms to vocabulary registry: "
            f"{', '.join(oov_terms[:5])}"
        )
    
    # Metric 2: Vocabulary Divergence
    divergence = calculate_divergence(training_corpus, production_corpus)
    div_status = determine_status(divergence, thresholds["divergence_warning"], thresholds["divergence_alert"])
    overall_statuses.append(div_status)
    
    metrics.append(DriftMetric(
        metric_type=DriftType.VOCABULARY_DIVERGENCE,
        value=divergence,
        threshold_warning=thresholds["divergence_warning"],
        threshold_alert=thresholds["divergence_alert"],
        status=div_status,
        details={
            "overlap_ratio": calculate_vocabulary_overlap(training_corpus, production_corpus),
        },
    ))
    
    if div_status in (DriftStatus.ALERT, DriftStatus.CRITICAL):
        recommendations.append(
            f"Vocabulary divergence is {divergence:.1%}. Consider retraining with recent data."
        )
    
    # Metric 3: New Terms
    new_terms = identify_new_terms(training_corpus, production_corpus)
    new_terms_ratio = len(new_terms) / max(production_corpus.unique_terms, 1)
    new_status = determine_status(new_terms_ratio, 0.15, 0.25)
    overall_statuses.append(new_status)
    
    metrics.append(DriftMetric(
        metric_type=DriftType.NEW_TERMS,
        value=new_terms_ratio,
        threshold_warning=0.15,
        threshold_alert=0.25,
        status=new_status,
        details={
            "new_terms_count": len(new_terms),
            "top_new_terms": new_terms[:10],
        },
    ))
    
    retraining_threshold = vocab_registry.get("metadata", {}).get(
        "retraining_triggers", {}
    ).get("new_terms_threshold", 50)
    
    if len(new_terms) >= retraining_threshold:
        recommendations.append(
            f"Detected {len(new_terms)} new terms (threshold: {retraining_threshold}). "
            f"Consider triggering retraining pipeline."
        )
    
    # Metric 4: Deprecated Terms Usage
    deprecated_used = check_deprecated_usage(production_corpus, deprecated_terms)
    deprecated_status = DriftStatus.WARNING if deprecated_used else DriftStatus.HEALTHY
    
    metrics.append(DriftMetric(
        metric_type=DriftType.DEPRECATED_USAGE,
        value=len(deprecated_used),
        threshold_warning=1,
        threshold_alert=5,
        status=deprecated_status,
        details={
            "deprecated_terms_used": deprecated_used,
        },
    ))
    
    if deprecated_used:
        recommendations.append(
            f"Deprecated terms in use: {', '.join(deprecated_used[:5])}. "
            f"Update prompts to use canonical forms."
        )
    
    # Determine overall status (worst of all)
    status_priority = {
        DriftStatus.HEALTHY: 0,
        DriftStatus.WARNING: 1,
        DriftStatus.ALERT: 2,
        DriftStatus.CRITICAL: 3,
    }
    overall_status = max(overall_statuses, key=lambda s: status_priority[s])
    
    # Generate report ID
    report_id = f"VOCAB-DRIFT-{datetime.now().strftime('%Y%m%d%H%M%S')}"
    
    return VocabularyDriftReport(
        report_id=report_id,
        timestamp=datetime.now().isoformat(),
        training_corpus=training_corpus,
        production_corpus=production_corpus,
        overall_status=overall_status,
        metrics=metrics,
        oov_terms=oov_terms,
        new_terms=new_terms,
        deprecated_terms_used=deprecated_used,
        recommendations=recommendations,
    )


# =============================================================================
# METRICS PERSISTENCE
# =============================================================================

def init_metrics_db(db_path: str = VOCAB_METRICS_DB_PATH):
    """Initialize SQLite database for metrics persistence."""
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS vocabulary_drift_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            report_id TEXT NOT NULL,
            metric_type TEXT NOT NULL,
            value REAL NOT NULL,
            status TEXT NOT NULL,
            details TEXT,
            UNIQUE(report_id, metric_type)
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS vocabulary_terms (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            report_id TEXT NOT NULL,
            term_type TEXT NOT NULL,
            term TEXT NOT NULL,
            frequency INTEGER DEFAULT 0
        )
    """)
    
    cursor.execute("""
        CREATE INDEX IF NOT EXISTS idx_metrics_timestamp ON vocabulary_drift_metrics(timestamp)
    """)
    
    conn.commit()
    conn.close()


def save_drift_report(report: VocabularyDriftReport, db_path: str = VOCAB_METRICS_DB_PATH):
    """Save drift report to database."""
    init_metrics_db(db_path)
    
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # Save metrics
    for metric in report.metrics:
        cursor.execute("""
            INSERT OR REPLACE INTO vocabulary_drift_metrics
            (timestamp, report_id, metric_type, value, status, details)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            report.timestamp,
            report.report_id,
            metric.metric_type.value,
            metric.value,
            metric.status.value,
            json.dumps(metric.details),
        ))
    
    # Save OOV terms
    for term in report.oov_terms[:100]:  # Limit stored terms
        cursor.execute("""
            INSERT INTO vocabulary_terms
            (timestamp, report_id, term_type, term, frequency)
            VALUES (?, ?, ?, ?, ?)
        """, (
            report.timestamp,
            report.report_id,
            "oov",
            term,
            report.production_corpus.terms.get(term, 0),
        ))
    
    # Save new terms
    for term in report.new_terms[:100]:
        cursor.execute("""
            INSERT INTO vocabulary_terms
            (timestamp, report_id, term_type, term, frequency)
            VALUES (?, ?, ?, ?, ?)
        """, (
            report.timestamp,
            report.report_id,
            "new",
            term,
            report.production_corpus.terms.get(term, 0),
        ))
    
    conn.commit()
    conn.close()


def get_historical_metrics(
    days: int = 30,
    db_path: str = VOCAB_METRICS_DB_PATH,
) -> List[Dict[str, Any]]:
    """Get historical drift metrics."""
    if not Path(db_path).exists():
        return []
    
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    cutoff = (datetime.now() - timedelta(days=days)).isoformat()
    
    cursor.execute("""
        SELECT timestamp, report_id, metric_type, value, status, details
        FROM vocabulary_drift_metrics
        WHERE timestamp >= ?
        ORDER BY timestamp DESC
    """, (cutoff,))
    
    results = []
    for row in cursor.fetchall():
        results.append({
            "timestamp": row[0],
            "report_id": row[1],
            "metric_type": row[2],
            "value": row[3],
            "status": row[4],
            "details": json.loads(row[5]) if row[5] else {},
        })
    
    conn.close()
    return results


# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

def format_console_output(report: VocabularyDriftReport) -> str:
    """Format drift report for console output."""
    lines = []
    lines.append("=" * 80)
    lines.append("VOCABULARY DRIFT REPORT")
    lines.append("=" * 80)
    lines.append(f"Report ID: {report.report_id}")
    lines.append(f"Timestamp: {report.timestamp}")
    
    status_icon = {
        DriftStatus.HEALTHY: "✅",
        DriftStatus.WARNING: "⚠️",
        DriftStatus.ALERT: "🔶",
        DriftStatus.CRITICAL: "🔴",
    }
    
    lines.append(f"Overall Status: {status_icon.get(report.overall_status, '?')} {report.overall_status.value.upper()}")
    lines.append("-" * 80)
    
    # Corpus info
    lines.append("\nCORPUS SUMMARY")
    lines.append(f"  Training: {report.training_corpus.unique_terms} unique terms, {report.training_corpus.total_tokens} tokens")
    lines.append(f"  Production: {report.production_corpus.unique_terms} unique terms, {report.production_corpus.total_tokens} tokens")
    
    # Metrics
    lines.append("\nMETRICS")
    lines.append("-" * 40)
    
    for metric in report.metrics:
        icon = status_icon.get(metric.status, "?")
        lines.append(f"  {icon} {metric.metric_type.value}: {metric.value:.2%}")
        lines.append(f"     Thresholds: warning={metric.threshold_warning:.0%}, alert={metric.threshold_alert:.0%}")
    
    # OOV Terms
    if report.oov_terms:
        lines.append(f"\nTOP OOV TERMS ({len(report.oov_terms)} total)")
        lines.append("-" * 40)
        for term in report.oov_terms[:10]:
            freq = report.production_corpus.terms.get(term, 0)
            lines.append(f"  • {term} (freq: {freq})")
    
    # New Terms
    if report.new_terms:
        lines.append(f"\nNEW TERMS ({len(report.new_terms)} total)")
        lines.append("-" * 40)
        for term in report.new_terms[:10]:
            freq = report.production_corpus.terms.get(term, 0)
            lines.append(f"  • {term} (freq: {freq})")
    
    # Deprecated
    if report.deprecated_terms_used:
        lines.append("\n⚠️ DEPRECATED TERMS IN USE")
        lines.append("-" * 40)
        for term in report.deprecated_terms_used:
            lines.append(f"  • {term}")
    
    # Recommendations
    if report.recommendations:
        lines.append("\nRECOMMENDATIONS")
        lines.append("-" * 40)
        for rec in report.recommendations:
            lines.append(f"  → {rec}")
    
    lines.append("\n" + "=" * 80)
    
    return "\n".join(lines)


def format_json_output(report: VocabularyDriftReport) -> str:
    """Format report as JSON."""
    return json.dumps(report.to_dict(), indent=2)


def format_yaml_output(report: VocabularyDriftReport) -> str:
    """Format report as YAML."""
    return yaml.dump(report.to_dict(), default_flow_style=False, sort_keys=False, allow_unicode=True)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Monitor vocabulary drift between training and production",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Analyze drift from user queries file
  %(prog)s --training-corpus train.jsonl --production-log prod.jsonl

  # Quick check with query list
  %(prog)s --queries "show me sales" "what is total revenue"

  # Generate historical trends report
  %(prog)s --trends --days 30

  # Output as JSON for CI integration
  %(prog)s --training-corpus train.jsonl --production-log prod.jsonl --output-format json
        """,
    )
    
    parser.add_argument(
        "--training-corpus",
        help="Path to training data JSONL file",
    )
    
    parser.add_argument(
        "--production-log",
        help="Path to production queries JSONL file",
    )
    
    parser.add_argument(
        "--queries",
        nargs="+",
        help="List of query strings to analyze",
    )
    
    parser.add_argument(
        "--vocab-registry",
        default=VOCABULARY_REGISTRY_PATH,
        help=f"Path to vocabulary registry (default: {VOCABULARY_REGISTRY_PATH})",
    )
    
    parser.add_argument(
        "--trends",
        action="store_true",
        help="Show historical drift trends",
    )
    
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="Number of days for trend analysis (default: 30)",
    )
    
    parser.add_argument(
        "--output-format",
        choices=["console", "json", "yaml"],
        default="console",
        help="Output format (default: console)",
    )
    
    parser.add_argument(
        "--output-file",
        help="Write output to file instead of stdout",
    )
    
    parser.add_argument(
        "--save-metrics",
        action="store_true",
        help="Save metrics to database for trend tracking",
    )
    
    args = parser.parse_args()
    
    # Load vocabulary registry
    vocab_registry = load_vocabulary_registry(args.vocab_registry)
    
    # Handle trends mode
    if args.trends:
        historical = get_historical_metrics(args.days)
        if args.output_format == "json":
            output = json.dumps(historical, indent=2)
        elif args.output_format == "yaml":
            output = yaml.dump(historical, default_flow_style=False)
        else:
            lines = ["VOCABULARY DRIFT TRENDS", "=" * 60]
            for entry in historical[:20]:
                lines.append(f"{entry['timestamp']}: {entry['metric_type']} = {entry['value']:.2%} ({entry['status']})")
            output = "\n".join(lines)
        print(output)
        sys.exit(0)
    
    # Build corpora
    if args.training_corpus:
        training_corpus = extract_vocabulary_from_jsonl(args.training_corpus)
    else:
        # Use vocabulary registry as training baseline
        known_vocab = extract_known_vocabulary(vocab_registry)
        training_corpus = VocabularyCorpus(
            name="vocabulary_registry",
            terms=Counter({t: 1 for t in known_vocab}),
            total_tokens=len(known_vocab),
            unique_terms=len(known_vocab),
            source="vocabulary_registry",
            timestamp=datetime.now().isoformat(),
        )
    
    if args.production_log:
        production_corpus = extract_vocabulary_from_jsonl(args.production_log)
    elif args.queries:
        production_corpus = extract_vocabulary_from_queries(args.queries)
    else:
        print("Error: Specify --production-log or --queries", file=sys.stderr)
        sys.exit(1)
    
    # Analyze drift
    report = analyze_vocabulary_drift(training_corpus, production_corpus, vocab_registry)
    
    # Save metrics if requested
    if args.save_metrics:
        save_drift_report(report)
        print(f"Metrics saved to {VOCAB_METRICS_DB_PATH}", file=sys.stderr)
    
    # Format output
    if args.output_format == "console":
        output = format_console_output(report)
    elif args.output_format == "json":
        output = format_json_output(report)
    elif args.output_format == "yaml":
        output = format_yaml_output(report)
    
    # Write output
    if args.output_file:
        with open(args.output_file, "w") as f:
            f.write(output)
        print(f"Report written to {args.output_file}")
    else:
        print(output)
    
    # Exit with appropriate code
    if report.overall_status == DriftStatus.CRITICAL:
        sys.exit(2)
    elif report.overall_status == DriftStatus.ALERT:
        sys.exit(1)
    
    sys.exit(0)


if __name__ == "__main__":
    main()