"""
agent/btp_kuzu_seeder.py

Seeds the KùzuDB graph with BTP schema data so that graph-RAG context
reflects the actual consolidated BTP schema.

What gets seeded:
  HANATable nodes  — one per unique (domain, wide_table, source_table) triple
  PALAlgorithm nodes (if not already present) — BTP-relevant algorithms
  EXECUTES_ON edges — links each PAL algorithm to relevant HANATable nodes
  QueryIntent nodes — one per BTP domain with routing intents
  SERVED_BY edges   — links intents to PAL algorithms

Data source (in priority order):
  1. BtpServerClient (server REST API) — preferred when server is reachable
  2. HanaClient direct (hdbcli) — fallback when server is offline
  3. Static fallback — minimal seed from known BTP wide-table catalogue
"""
from __future__ import annotations

import os
import sys
from typing import Any, Dict, List, Optional

# ---------------------------------------------------------------------------
# KùzuDB store import
# ---------------------------------------------------------------------------
_mcp_dir = os.path.join(os.path.dirname(__file__), "..", "mcp_server")
if os.path.isdir(_mcp_dir) and _mcp_dir not in sys.path:
    sys.path.insert(0, os.path.abspath(_mcp_dir))

try:
    from kuzu_store import get_kuzu_store as _get_kuzu_store  # type: ignore[import]
    _KUZU_AVAILABLE = True
except ImportError:
    _KUZU_AVAILABLE = False

# ---------------------------------------------------------------------------
# Domain → PAL algorithm mapping (BTP schema semantics)
# ---------------------------------------------------------------------------

_DOMAIN_PAL_ALGOS: Dict[str, List[str]] = {
    "TREASURY":    ["pal_forecast", "pal_anomaly", "pal_clustering"],
    "ESG":         ["pal_forecast", "pal_anomaly", "pal_clustering", "pal_classification"],
    "PERFORMANCE": ["pal_forecast", "pal_regression", "pal_anomaly"],
    "STAGING":     ["pal_anomaly", "pal_clustering"],
    "RECON":       ["pal_anomaly", "pal_regression"],
    "CLIENT":      ["pal_classification", "pal_clustering"],
}

# BTP wide-table → domain mapping (mirrors emit_hana.py _DOMAIN_TO_TABLE)
_WIDE_TABLE_DOMAIN: Dict[str, str] = {
    "FACT":               "STAGING",
    "RECON":              "RECON",
    "ESG_METRIC":         "ESG",
    "TREASURY_POSITION":  "TREASURY",
    "CLIENT_MI":          "CLIENT",
    "DIM_ENTITY":         "STAGING",
    "DIM_PRODUCT":        "STAGING",
    "DIM_LOCATION":       "STAGING",
    "DIM_ACCOUNT":        "PERFORMANCE",
    "DIM_COST_CLUSTER":   "PERFORMANCE",
    "DIM_TIME":           "STAGING",
    "TERM_MAPPING":       "STAGING",
    "DIM_DEFINITION":     "STAGING",
    "FILTER_VALUE":       "STAGING",
    "SCHEMA_REGISTRY":    "STAGING",
}

# Well-known PAL algorithm definitions
_PAL_ALGO_CATALOG: Dict[str, Dict[str, str]] = {
    "pal_forecast":       {"name": "PAL Time Series Forecast", "category": "Forecasting",    "procedure": "_SYS_AFL.PAL_ARIMA"},
    "pal_anomaly":        {"name": "PAL Anomaly Detection",    "category": "Anomaly",         "procedure": "_SYS_AFL.PAL_ANOMALYDETECTION"},
    "pal_clustering":     {"name": "PAL K-Means Clustering",   "category": "Clustering",      "procedure": "_SYS_AFL.PAL_KMEANS"},
    "pal_classification": {"name": "PAL Classification",       "category": "Classification",  "procedure": "_SYS_AFL.PAL_DT"},
    "pal_regression":     {"name": "PAL Linear Regression",    "category": "Regression",      "procedure": "_SYS_AFL.PAL_LINEAR_REGRESSION"},
}

# Static BTP wide-table fallback when no live source is available
_STATIC_BTP_TABLES: List[Dict[str, str]] = [
    {"tableId": "btp:FACT",              "name": "BTP.FACT",              "schema_name": "BTP", "table_type": "WIDE", "wide_table": "FACT",              "domain": "STAGING"},
    {"tableId": "btp:RECON",             "name": "BTP.RECON",             "schema_name": "BTP", "table_type": "WIDE", "wide_table": "RECON",             "domain": "RECON"},
    {"tableId": "btp:ESG_METRIC",        "name": "BTP.ESG_METRIC",        "schema_name": "BTP", "table_type": "WIDE", "wide_table": "ESG_METRIC",        "domain": "ESG"},
    {"tableId": "btp:TREASURY_POSITION", "name": "BTP.TREASURY_POSITION", "schema_name": "BTP", "table_type": "WIDE", "wide_table": "TREASURY_POSITION", "domain": "TREASURY"},
    {"tableId": "btp:CLIENT_MI",         "name": "BTP.CLIENT_MI",         "schema_name": "BTP", "table_type": "WIDE", "wide_table": "CLIENT_MI",         "domain": "CLIENT"},
    {"tableId": "btp:DIM_ENTITY",        "name": "BTP.DIM_ENTITY",        "schema_name": "BTP", "table_type": "DIM",  "wide_table": "DIM_ENTITY",        "domain": "STAGING"},
    {"tableId": "btp:DIM_PRODUCT",       "name": "BTP.DIM_PRODUCT",       "schema_name": "BTP", "table_type": "DIM",  "wide_table": "DIM_PRODUCT",       "domain": "STAGING"},
    {"tableId": "btp:DIM_ACCOUNT",       "name": "BTP.DIM_ACCOUNT",       "schema_name": "BTP", "table_type": "DIM",  "wide_table": "DIM_ACCOUNT",       "domain": "PERFORMANCE"},
    {"tableId": "btp:DIM_COST_CLUSTER",  "name": "BTP.DIM_COST_CLUSTER",  "schema_name": "BTP", "table_type": "DIM",  "wide_table": "DIM_COST_CLUSTER",  "domain": "PERFORMANCE"},
    {"tableId": "btp:DIM_LOCATION",      "name": "BTP.DIM_LOCATION",      "schema_name": "BTP", "table_type": "DIM",  "wide_table": "DIM_LOCATION",      "domain": "STAGING"},
    {"tableId": "btp:DIM_TIME",          "name": "BTP.DIM_TIME",          "schema_name": "BTP", "table_type": "DIM",  "wide_table": "DIM_TIME",          "domain": "STAGING"},
    {"tableId": "btp:SCHEMA_REGISTRY",   "name": "BTP.SCHEMA_REGISTRY",   "schema_name": "BTP", "table_type": "META", "wide_table": "SCHEMA_REGISTRY",   "domain": "STAGING"},
]


# ---------------------------------------------------------------------------
# Data fetching
# ---------------------------------------------------------------------------

def _fetch_tables_from_server() -> Optional[List[Dict[str, Any]]]:
    """Try to fetch BTP tables via the server REST API."""
    try:
        from btp_server_client import registry_query  # type: ignore[import]
        result = registry_query(limit=2000)
        fields: List[Dict[str, Any]] = result.get("fields", [])
        if not fields:
            return None
        # Deduplicate by (domain, wide_table, source_table)
        seen = set()
        tables: List[Dict[str, Any]] = []
        for f in fields:
            key = (f.get("domain", ""), f.get("wide_table", ""), f.get("source_table", ""))
            if key in seen:
                continue
            seen.add(key)
            domain = f.get("domain", "STAGING")
            wide = f.get("wide_table", "FACT")
            src = f.get("source_table", "")
            tables.append({
                "tableId": f"btp:{wide}:{src}" if src else f"btp:{wide}",
                "name": f"BTP.{wide}" + (f"/{src}" if src else ""),
                "schema_name": "BTP",
                "table_type": "WIDE",
                "wide_table": wide,
                "domain": domain,
            })
        return tables
    except Exception:
        return None


def _fetch_tables_from_hana() -> Optional[List[Dict[str, Any]]]:
    """Try to fetch BTP tables directly from HANA."""
    try:
        from hana_client import query_schema_registry, is_available  # type: ignore[import]
        if not is_available():
            return None
        rows = query_schema_registry(limit=2000)
        if not rows:
            return None
        seen = set()
        tables: List[Dict[str, Any]] = []
        for r in rows:
            key = (r.get("domain", ""), r.get("wide_table", ""), r.get("source_table", ""))
            if key in seen:
                continue
            seen.add(key)
            wide = r.get("wide_table", "FACT")
            src = r.get("source_table", "")
            domain = r.get("domain", "STAGING")
            tables.append({
                "tableId": f"btp:{wide}:{src}" if src else f"btp:{wide}",
                "name": f"BTP.{wide}" + (f"/{src}" if src else ""),
                "schema_name": "BTP",
                "table_type": "WIDE",
                "wide_table": wide,
                "domain": domain,
            })
        return tables
    except Exception:
        return None


def _get_btp_tables() -> List[Dict[str, Any]]:
    """Fetch BTP table list; try server → HANA direct → static fallback."""
    tables = _fetch_tables_from_server()
    if tables:
        return tables
    tables = _fetch_tables_from_hana()
    if tables:
        return tables
    return _STATIC_BTP_TABLES


# ---------------------------------------------------------------------------
# Seeder
# ---------------------------------------------------------------------------

def seed_btp_into_kuzu(verbose: bool = False) -> Dict[str, Any]:
    """
    Main entry point: seed BTP schema data into KùzuDB.

    Returns a summary dict with counts of what was seeded.
    """
    if not _KUZU_AVAILABLE:
        return {"error": "KùzuDB not available; install hippocpp or kuzu>=0.7.0"}

    store = _get_kuzu_store()
    if not store.available():
        return {"error": "KùzuDB backend unavailable"}

    store.ensure_schema()

    summary: Dict[str, int] = {
        "algos_upserted": 0,
        "tables_upserted": 0,
        "algo_table_links": 0,
        "intents_upserted": 0,
        "intent_algo_links": 0,
        "intent_service_links": 0,
    }

    # 1. Upsert PAL algorithms
    for algo_id, algo in _PAL_ALGO_CATALOG.items():
        store.upsert_pal_algorithm(
            algo_id,
            algo["name"],
            algo["category"],
            algo["procedure"],
            f"SAP HANA PAL: {algo['name']}",
        )
        summary["algos_upserted"] += 1
    if verbose:
        print(f"[btp_seeder] Upserted {summary['algos_upserted']} PAL algorithms")

    # 2. Fetch and upsert BTP tables
    btp_tables = _get_btp_tables()
    domain_to_table_ids: Dict[str, List[str]] = {}

    for t in btp_tables:
        table_id = t["tableId"]
        store.upsert_hana_table(
            table_id,
            t["name"],
            t["schema_name"],
            t["table_type"],
        )
        summary["tables_upserted"] += 1
        domain = t.get("domain", "STAGING")
        domain_to_table_ids.setdefault(domain, []).append(table_id)

    if verbose:
        print(f"[btp_seeder] Upserted {summary['tables_upserted']} HANATable nodes")

    # 3. Link PAL algorithms → BTP tables based on domain
    for domain, table_ids in domain_to_table_ids.items():
        algo_ids = _DOMAIN_PAL_ALGOS.get(domain, [])
        for algo_id in algo_ids:
            for table_id in table_ids:
                store.link_algo_table(algo_id, table_id, weight=1)
                summary["algo_table_links"] += 1

    if verbose:
        print(f"[btp_seeder] Created {summary['algo_table_links']} EXECUTES_ON edges")

    # 4. Upsert QueryIntent nodes and link to PAL algorithms
    for domain, algo_ids in _DOMAIN_PAL_ALGOS.items():
        intent_id = f"btp_intent_{domain.lower()}"
        store.upsert_query_intent(
            intent_id,
            f"BTP {domain.title()} Analytics",
            f"*{domain.lower()}*|*{domain.lower()} data*|*{domain.lower()} analysis*",
            "btp_analytics",
        )
        summary["intents_upserted"] += 1
        for algo_id in algo_ids:
            store.link_intent_algo(intent_id, algo_id, confidence=85)
            summary["intent_algo_links"] += 1

    if verbose:
        print(f"[btp_seeder] Upserted {summary['intents_upserted']} QueryIntent nodes")
        print(f"[btp_seeder] Created {summary['intent_algo_links']} SERVED_BY edges")

    # 5. Register the BTP server as a MeshService
    btp_server_url = os.environ.get("BTP_SERVER_URL", "http://localhost:8080")
    store.upsert_mesh_service(
        "btp-server",
        "BTP Schema Server",
        btp_server_url,
        int(os.environ.get("PORT", "8080")),
        priority=10,
    )
    # Link all intents to the BTP server service
    for domain in _DOMAIN_PAL_ALGOS:
        intent_id = f"btp_intent_{domain.lower()}"
        store.link_intent_service(intent_id, "btp-server", priority=1)
        summary["intent_service_links"] += 1

    return {"status": "success", "source": "btp", **summary}
