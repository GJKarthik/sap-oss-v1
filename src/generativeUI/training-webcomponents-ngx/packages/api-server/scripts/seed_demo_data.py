#!/usr/bin/env python3
"""
Demo Seed Data — pre-populates Translation Memory, glossary, and vector store
for live demos. Run once against a running api-server instance.

Usage:
    python seed_demo_data.py [--base-url http://localhost:4200/api]
"""

import argparse
import json
import sys
from typing import Any, Dict, List

try:
    import httpx
except ImportError:
    print("Install httpx: pip install httpx", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Seed Data
# ---------------------------------------------------------------------------

GLOSSARY_TERMS: List[Dict[str, Any]] = [
    # Treasury domain
    {"source": "Balance Sheet", "target": "الميزانية العمومية", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.98},
    {"source": "Cash Flow", "target": "التدفق النقدي", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.97},
    {"source": "Net Asset Value", "target": "صافي قيمة الأصول", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.95},
    {"source": "Mark to Market", "target": "تقييم بسعر السوق", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.93},
    {"source": "Hedging", "target": "التحوط", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.96},
    {"source": "Yield Curve", "target": "منحنى العائد", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.94},
    {"source": "Foreign Exchange", "target": "صرف العملات الأجنبية", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.99},
    {"source": "Maturity Date", "target": "تاريخ الاستحقاق", "source_lang": "en", "target_lang": "ar", "category": "treasury", "confidence": 0.92},
    # ESG domain
    {"source": "Carbon Footprint", "target": "البصمة الكربونية", "source_lang": "en", "target_lang": "ar", "category": "esg", "confidence": 0.96},
    {"source": "Scope 1 Emissions", "target": "انبعاثات النطاق الأول", "source_lang": "en", "target_lang": "ar", "category": "esg", "confidence": 0.91},
    {"source": "Sustainability Report", "target": "تقرير الاستدامة", "source_lang": "en", "target_lang": "ar", "category": "esg", "confidence": 0.97},
    {"source": "Green Bond", "target": "السند الأخضر", "source_lang": "en", "target_lang": "ar", "category": "esg", "confidence": 0.90},
    {"source": "ESG Rating", "target": "تصنيف الحوكمة البيئية", "source_lang": "en", "target_lang": "ar", "category": "esg", "confidence": 0.94},
    {"source": "Water Intensity", "target": "كثافة استهلاك المياه", "source_lang": "en", "target_lang": "ar", "category": "esg", "confidence": 0.88},
    # Performance / BPC domain
    {"source": "Cost Center", "target": "مركز التكلفة", "source_lang": "en", "target_lang": "ar", "category": "performance", "confidence": 0.99},
    {"source": "Profit Center", "target": "مركز الربح", "source_lang": "en", "target_lang": "ar", "category": "performance", "confidence": 0.98},
    {"source": "Variance Analysis", "target": "تحليل الانحراف", "source_lang": "en", "target_lang": "ar", "category": "performance", "confidence": 0.95},
    {"source": "Consolidation", "target": "التوحيد المالي", "source_lang": "en", "target_lang": "ar", "category": "performance", "confidence": 0.93},
    {"source": "Intercompany Elimination", "target": "إزالة المعاملات البينية", "source_lang": "en", "target_lang": "ar", "category": "performance", "confidence": 0.91},
    {"source": "Budget Plan", "target": "خطة الميزانية", "source_lang": "en", "target_lang": "ar", "category": "performance", "confidence": 0.96},
    # DB field mappings
    {"source": "BUKRS", "target": "Company Code", "source_lang": "sap", "target_lang": "en", "category": "db_field_mapping", "confidence": 0.99},
    {"source": "WAERS", "target": "Currency Key", "source_lang": "sap", "target_lang": "en", "category": "db_field_mapping", "confidence": 0.99},
    {"source": "KUNNR", "target": "Customer Number", "source_lang": "sap", "target_lang": "en", "category": "db_field_mapping", "confidence": 0.98},
    {"source": "LIFNR", "target": "Vendor Number", "source_lang": "sap", "target_lang": "en", "category": "db_field_mapping", "confidence": 0.98},
    {"source": "DMBTR", "target": "Amount in Local Currency", "source_lang": "sap", "target_lang": "en", "category": "db_field_mapping", "confidence": 0.97},
]

TM_ENTRIES: List[Dict[str, Any]] = [
    {
        "source": "The consolidated balance sheet shows total assets of SAR 1.2 billion.",
        "target": "تظهر الميزانية العمومية الموحدة إجمالي أصول بقيمة 1.2 مليار ريال سعودي.",
        "source_lang": "en",
        "target_lang": "ar",
        "domain": "treasury",
        "is_approved": True,
    },
    {
        "source": "Scope 1 and Scope 2 greenhouse gas emissions decreased by 12% year-over-year.",
        "target": "انخفضت انبعاثات الغازات الدفيئة للنطاق 1 والنطاق 2 بنسبة 12% على أساس سنوي.",
        "source_lang": "en",
        "target_lang": "ar",
        "domain": "esg",
        "is_approved": True,
    },
    {
        "source": "The hedging effectiveness test resulted in a ratio within the 80-125% corridor.",
        "target": "أسفر اختبار فعالية التحوط عن نسبة ضمن نطاق 80-125%.",
        "source_lang": "en",
        "target_lang": "ar",
        "domain": "treasury",
        "is_approved": True,
    },
    {
        "source": "Operating expenses for Q3 exceeded budget by 4.2%, primarily driven by FX losses.",
        "target": "تجاوزت المصاريف التشغيلية للربع الثالث الميزانية بنسبة 4.2%، مدفوعة بشكل رئيسي بخسائر صرف العملات.",
        "source_lang": "en",
        "target_lang": "ar",
        "domain": "performance",
        "is_approved": True,
    },
    {
        "source": "Water intensity per unit of revenue improved to 3.8 m³/SAR million.",
        "target": "تحسنت كثافة استهلاك المياه لكل وحدة إيرادات إلى 3.8 متر مكعب/مليون ريال سعودي.",
        "source_lang": "en",
        "target_lang": "ar",
        "domain": "esg",
        "is_approved": True,
    },
]


# ---------------------------------------------------------------------------
# Seeder
# ---------------------------------------------------------------------------

def seed(base_url: str) -> None:
    client = httpx.Client(base_url=base_url, timeout=30.0)

    # Header with admin role for write access
    headers = {"X-Team-Context": json.dumps({"country": "AE", "domain": "treasury", "role": "admin"})}

    print("=== Demo Seed Data ===\n")

    # 1. Verify connectivity
    try:
        r = client.get("/health")
        r.raise_for_status()
        print(f"[OK] API healthy: {r.json().get('status')}")
    except Exception as e:
        print(f"[FAIL] Cannot reach API at {base_url}: {e}")
        sys.exit(1)

    # 2. Seed glossary / TM entries
    tm_ok = 0
    for entry in TM_ENTRIES:
        try:
            r = client.post("/rag/tm", json=entry, headers=headers)
            if r.status_code in (200, 201):
                tm_ok += 1
        except Exception:
            pass
    print(f"[OK] Seeded {tm_ok}/{len(TM_ENTRIES)} TM entries")

    # 3. Trigger vectorization of approved TM entries
    try:
        r = client.post("/rag/tm/vectorize-batch", headers=headers)
        if r.status_code == 200:
            result = r.json()
            print(f"[OK] Vectorized {result.get('vectorized', '?')} TM entries into GLOSSARY_VECTORS")
        else:
            print(f"[WARN] Vectorize batch returned {r.status_code}")
    except Exception as e:
        print(f"[WARN] Vectorize batch failed: {e}")

    # 4. Verify data products
    try:
        r = client.get("/data-products/products")
        products = r.json()
        print(f"[OK] {len(products)} data products registered")
        for p in products:
            enrichment = "enriched" if p.get("enrichmentAvailable") else ""
            print(f"     - {p['name']} ({p['domain']}) — {p['fieldCount']} fields {enrichment}")
    except Exception as e:
        print(f"[WARN] Could not list data products: {e}")

    # 5. Verify TM count
    try:
        r = client.get("/rag/tm/meta")
        meta = r.json()
        print(f"[OK] TM store: {meta.get('count', '?')} entries ({meta.get('backend', '?')})")
    except Exception:
        pass

    print("\n=== Seed complete ===")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed demo data for Training Console")
    parser.add_argument("--base-url", default="http://localhost:4200/api", help="API base URL")
    args = parser.parse_args()
    seed(args.base_url)
