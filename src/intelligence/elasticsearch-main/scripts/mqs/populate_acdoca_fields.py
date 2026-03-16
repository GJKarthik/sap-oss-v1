#!/usr/bin/env python3
"""
Populate Elasticsearch with ACDOCA (I_JournalEntryItem) field mappings.

This script loads S/4HANA Finance Universal Journal field definitions
into the odata_entity_index for field classification lookups.
"""

import json
import urllib.request
from typing import Dict, List

ES_ENDPOINT = "http://localhost:9200"
INDEX_NAME = "odata_entity_index"


def create_index():
    """Create the odata_entity_index if it doesn't exist."""
    mapping = {
        "settings": {
            "number_of_shards": 1,
            "number_of_replicas": 0,
            "analysis": {
                "analyzer": {
                    "field_analyzer": {
                        "type": "custom",
                        "tokenizer": "standard",
                        "filter": ["lowercase", "asciifolding"]
                    }
                }
            }
        },
        "mappings": {
            "properties": {
                "entity": {"type": "keyword"},
                "field_name": {"type": "text", "analyzer": "field_analyzer"},
                "technical_name": {"type": "keyword"},
                "aliases": {"type": "text", "analyzer": "field_analyzer"},
                "category": {"type": "keyword"},
                "field_type": {"type": "keyword"},
                "data_type": {"type": "keyword"},
                "vocabulary": {"type": "keyword"},
                "annotations": {"type": "text"},
                "description": {"type": "text"},
                "module": {"type": "keyword"},
                "is_key": {"type": "boolean"},
                "currency_reference": {"type": "keyword"}
            }
        }
    }
    
    try:
        req = urllib.request.Request(
            f"{ES_ENDPOINT}/{INDEX_NAME}",
            data=json.dumps(mapping).encode(),
            headers={"Content-Type": "application/json"},
            method="PUT"
        )
        with urllib.request.urlopen(req) as resp:
            print(f"Index created: {resp.read().decode()}")
    except urllib.error.HTTPError as e:
        if e.code == 400:
            print(f"Index already exists")
        else:
            print(f"Error creating index: {e}")


def bulk_index(docs: List[Dict]):
    """Bulk index documents."""
    bulk_data = ""
    for doc in docs:
        action = {"index": {"_index": INDEX_NAME}}
        bulk_data += json.dumps(action) + "\n"
        bulk_data += json.dumps(doc) + "\n"
    
    req = urllib.request.Request(
        f"{ES_ENDPOINT}/_bulk",
        data=bulk_data.encode(),
        headers={"Content-Type": "application/x-ndjson"},
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            errors = result.get("errors", False)
            items = result.get("items", [])
            print(f"Indexed {len(items)} documents, errors: {errors}")
    except Exception as e:
        print(f"Bulk index error: {e}")


def get_acdoca_fields() -> List[Dict]:
    """
    Get ACDOCA (I_JournalEntryItem) field definitions.
    
    Based on SAP Business Data Products for S/4HANA Finance.
    """
    return [
        # ===== KEY FIELDS =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "CompanyCode",
            "technical_name": "BUKRS",
            "aliases": ["bukrs", "companycode", "company_code", "comp_code"],
            "category": "dimension",
            "field_type": "CompanyCode",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true, @Common.SemanticKey",
            "description": "Company Code - Organizational unit for which an independent set of accounts can be drawn up",
            "module": "FI",
            "is_key": True
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "FiscalYear",
            "technical_name": "GJAHR",
            "aliases": ["gjahr", "fiscalyear", "fiscal_year", "fy"],
            "category": "dimension",
            "field_type": "FiscalYear",
            "data_type": "NUMC(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true, @Common.SemanticKey",
            "description": "Fiscal Year",
            "module": "FI",
            "is_key": True
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AccountingDocument",
            "technical_name": "BELNR",
            "aliases": ["belnr", "accountingdocument", "document_number", "docnumber", "doc_no"],
            "category": "key",
            "field_type": "AccountingDocument",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Accounting Document Number",
            "module": "FI",
            "is_key": True
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AccountingDocumentItem",
            "technical_name": "BUZEI",
            "aliases": ["buzei", "lineitem", "line_item", "item_no"],
            "category": "key",
            "field_type": "AccountingDocumentItem",
            "data_type": "NUMC(6)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Number of Line Item Within Accounting Document",
            "module": "FI",
            "is_key": True
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "Ledger",
            "technical_name": "RLDNR",
            "aliases": ["rldnr", "ledger"],
            "category": "dimension",
            "field_type": "Ledger",
            "data_type": "CHAR(2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Ledger in General Ledger Accounting",
            "module": "FI",
            "is_key": True
        },
        
        # ===== GL ACCOUNT =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "GLAccount",
            "technical_name": "HKONT",
            "aliases": ["hkont", "racct", "glaccount", "gl_account", "sachkonto", "account"],
            "category": "dimension",
            "field_type": "GLAccount",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "General Ledger Account",
            "module": "FI-GL",
            "is_key": False
        },
        
        # ===== ORGANIZATIONAL UNITS =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "CostCenter",
            "technical_name": "KOSTL",
            "aliases": ["kostl", "rcntr", "costcenter", "cost_center", "kostenstelle", "cctr"],
            "category": "dimension",
            "field_type": "CostCenter",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Cost Center",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "ProfitCenter",
            "technical_name": "PRCTR",
            "aliases": ["prctr", "profitcenter", "profit_center", "pctr"],
            "category": "dimension",
            "field_type": "ProfitCenter",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Profit Center",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "Segment",
            "technical_name": "SEGMENT",
            "aliases": ["segment"],
            "category": "dimension",
            "field_type": "Segment",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Segment for Segmental Reporting",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "BusinessArea",
            "technical_name": "GSBER",
            "aliases": ["gsber", "businessarea", "business_area", "ba"],
            "category": "dimension",
            "field_type": "BusinessArea",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Business Area",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "ControllingArea",
            "technical_name": "KOKRS",
            "aliases": ["kokrs", "controllingarea", "controlling_area", "co_area"],
            "category": "dimension",
            "field_type": "ControllingArea",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Controlling Area",
            "module": "CO",
            "is_key": False
        },
        
        # ===== AMOUNTS (MEASURES) =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AmountInCompanyCodeCurrency",
            "technical_name": "HSL",
            "aliases": ["hsl", "amountincompanycodecurrency", "amount_lc", "localamount", "local_amount"],
            "category": "measure",
            "field_type": "AmountInCompanyCodeCurrency",
            "data_type": "CURR(23,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true, @Semantics.amount.currencyCode: 'CompanyCodeCurrency'",
            "description": "Amount in Company Code Currency",
            "module": "FI",
            "is_key": False,
            "currency_reference": "CompanyCodeCurrency"
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AmountInTransactionCurrency",
            "technical_name": "WSL",
            "aliases": ["wsl", "amountintransactioncurrency", "amount_tc", "transactionamount", "doc_amount"],
            "category": "measure",
            "field_type": "AmountInTransactionCurrency",
            "data_type": "CURR(23,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true, @Semantics.amount.currencyCode: 'TransactionCurrency'",
            "description": "Amount in Transaction Currency",
            "module": "FI",
            "is_key": False,
            "currency_reference": "TransactionCurrency"
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AmountInGlobalCurrency",
            "technical_name": "KSL",
            "aliases": ["ksl", "amountinglobalcurrency", "amount_gc", "globalamount", "group_amount"],
            "category": "measure",
            "field_type": "AmountInGlobalCurrency",
            "data_type": "CURR(23,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true, @Semantics.amount.currencyCode: 'GlobalCurrency'",
            "description": "Amount in Global Currency",
            "module": "FI",
            "is_key": False,
            "currency_reference": "GlobalCurrency"
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "Quantity",
            "technical_name": "MSL",
            "aliases": ["msl", "quantity", "menge", "qty"],
            "category": "measure",
            "field_type": "Quantity",
            "data_type": "QUAN(13,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true, @Semantics.quantity.unitOfMeasure: 'BaseUnit'",
            "description": "Quantity",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "DebitAmount",
            "technical_name": "DMBTR",
            "aliases": ["dmbtr", "debitamount", "debit"],
            "category": "measure",
            "field_type": "DebitCreditAmount",
            "data_type": "CURR(13,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Amount in Local Currency (Debit/Credit)",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "TransactionAmount",
            "technical_name": "WRBTR",
            "aliases": ["wrbtr", "transactionamount"],
            "category": "measure",
            "field_type": "DebitCreditAmount",
            "data_type": "CURR(13,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Amount in Document Currency",
            "module": "FI",
            "is_key": False
        },
        
        # ===== CURRENCIES =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "CompanyCodeCurrency",
            "technical_name": "RHCUR",
            "aliases": ["rhcur", "companycodecurrency", "currency_lc", "localcurrency", "waers", "local_curr"],
            "category": "currency",
            "field_type": "CompanyCodeCurrency",
            "data_type": "CUKY(5)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.currencyCode: true",
            "description": "Currency Key for Company Code Currency",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "TransactionCurrency",
            "technical_name": "RWCUR",
            "aliases": ["rwcur", "transactioncurrency", "currency_tc", "doc_curr"],
            "category": "currency",
            "field_type": "TransactionCurrency",
            "data_type": "CUKY(5)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.currencyCode: true",
            "description": "Currency Key for Transaction Currency",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "GlobalCurrency",
            "technical_name": "RKCUR",
            "aliases": ["rkcur", "globalcurrency", "currency_gc", "group_curr"],
            "category": "currency",
            "field_type": "GlobalCurrency",
            "data_type": "CUKY(5)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.currencyCode: true",
            "description": "Currency Key for Global Currency",
            "module": "FI",
            "is_key": False
        },
        
        # ===== DATES =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "PostingDate",
            "technical_name": "BUDAT",
            "aliases": ["budat", "postingdate", "posting_date", "post_date"],
            "category": "dimension",
            "field_type": "PostingDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Posting Date in the Document",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "DocumentDate",
            "technical_name": "BLDAT",
            "aliases": ["bldat", "documentdate", "document_date", "doc_date"],
            "category": "dimension",
            "field_type": "DocumentDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Document Date in Document",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "FiscalPeriod",
            "technical_name": "MONAT",
            "aliases": ["monat", "fiscalperiod", "fiscal_period", "period", "postingperiod"],
            "category": "dimension",
            "field_type": "FiscalPeriod",
            "data_type": "NUMC(3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Fiscal Period",
            "module": "FI",
            "is_key": False
        },
        
        # ===== DOCUMENT ATTRIBUTES =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AccountingDocumentType",
            "technical_name": "BLART",
            "aliases": ["blart", "documenttype", "doc_type", "acct_doc_type"],
            "category": "dimension",
            "field_type": "AccountingDocumentType",
            "data_type": "CHAR(2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Document Type",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "DebitCreditCode",
            "technical_name": "SHKZG",
            "aliases": ["shkzg", "debitcreditcode", "debit_credit", "dc_indicator"],
            "category": "dimension",
            "field_type": "DebitCreditCode",
            "data_type": "CHAR(1)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Debit/Credit Indicator",
            "module": "FI",
            "is_key": False
        },
        
        # ===== SUBLEDGER - ACCOUNTS RECEIVABLE =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "Customer",
            "technical_name": "KUNNR",
            "aliases": ["kunnr", "customer", "customer_no", "debtor"],
            "category": "subledger",
            "field_type": "Customer",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Customer Number",
            "module": "FI-AR",
            "is_key": False
        },
        
        # ===== SUBLEDGER - ACCOUNTS PAYABLE =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "Supplier",
            "technical_name": "LIFNR",
            "aliases": ["lifnr", "supplier", "vendor", "vendor_no", "creditor"],
            "category": "subledger",
            "field_type": "Supplier",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Supplier/Vendor Number",
            "module": "FI-AP",
            "is_key": False
        },
        
        # ===== SUBLEDGER - ASSET ACCOUNTING =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "FixedAsset",
            "technical_name": "ANLN1",
            "aliases": ["anln1", "fixedasset", "asset", "asset_no"],
            "category": "subledger",
            "field_type": "FixedAsset",
            "data_type": "CHAR(12)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Main Asset Number",
            "module": "FI-AA",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AssetSubNumber",
            "technical_name": "ANLN2",
            "aliases": ["anln2", "assetsubnumber", "asset_sub", "sub_asset"],
            "category": "subledger",
            "field_type": "AssetSubNumber",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Asset Subnumber",
            "module": "FI-AA",
            "is_key": False
        },
        
        # ===== REFERENCE FIELDS =====
        {
            "entity": "I_JournalEntryItem",
            "field_name": "Reference",
            "technical_name": "XBLNR",
            "aliases": ["xblnr", "reference", "ref_doc", "external_ref"],
            "category": "dimension",
            "field_type": "Reference",
            "data_type": "CHAR(16)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true",
            "description": "Reference Document Number",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_JournalEntryItem",
            "field_name": "AssignmentReference",
            "technical_name": "ZUONR",
            "aliases": ["zuonr", "assignment", "assignment_ref"],
            "category": "dimension",
            "field_type": "AssignmentReference",
            "data_type": "CHAR(18)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true",
            "description": "Assignment Reference",
            "module": "FI",
            "is_key": False
        },
    ]


def main():
    print("=" * 60)
    print("Populating ACDOCA fields into Elasticsearch")
    print("=" * 60)
    
    # Create index
    print("\n1. Creating index...")
    create_index()
    
    # Get field definitions
    print("\n2. Loading field definitions...")
    fields = get_acdoca_fields()
    print(f"   Loaded {len(fields)} field definitions")
    
    # Bulk index
    print("\n3. Indexing fields...")
    bulk_index(fields)
    
    # Summary
    print("\n" + "=" * 60)
    print("Summary:")
    categories = {}
    for f in fields:
        cat = f.get("category", "unknown")
        categories[cat] = categories.get(cat, 0) + 1
    
    for cat, count in sorted(categories.items()):
        print(f"  {cat}: {count} fields")
    
    print(f"\nTotal: {len(fields)} fields indexed")
    print("=" * 60)


if __name__ == "__main__":
    main()