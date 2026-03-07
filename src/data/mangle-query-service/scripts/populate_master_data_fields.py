#!/usr/bin/env python3
"""
Populate Elasticsearch with S/4HANA Master Data field mappings.

Includes:
- Cost Center (I_CostCenter)
- Profit Center (I_ProfitCenter)
- Material (I_Product)
- GL Account (I_GLAccountInChartOfAccounts)
"""

import json
import urllib.request
from typing import Dict, List

ES_ENDPOINT = "http://localhost:9200"
INDEX_NAME = "odata_entity_index"


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


def get_cost_center_fields() -> List[Dict]:
    """I_CostCenter entity fields."""
    return [
        {
            "entity": "I_CostCenter",
            "field_name": "CostCenter",
            "technical_name": "KOSTL",
            "aliases": ["kostl", "costcenter", "cost_center", "cctr"],
            "category": "key",
            "field_type": "CostCenter",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Cost Center",
            "module": "CO",
            "is_key": True
        },
        {
            "entity": "I_CostCenter",
            "field_name": "ControllingArea",
            "technical_name": "KOKRS",
            "aliases": ["kokrs", "controllingarea", "co_area"],
            "category": "key",
            "field_type": "ControllingArea",
            "data_type": "CHAR(4)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Controlling Area",
            "module": "CO",
            "is_key": True
        },
        {
            "entity": "I_CostCenter",
            "field_name": "ValidityStartDate",
            "technical_name": "DATAB",
            "aliases": ["datab", "validfrom", "valid_from"],
            "category": "key",
            "field_type": "ValidityStartDate",
            "data_type": "DATS",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Validity Start Date",
            "module": "CO",
            "is_key": True
        },
        {
            "entity": "I_CostCenter",
            "field_name": "ValidityEndDate",
            "technical_name": "DATBI",
            "aliases": ["datbi", "validto", "valid_to"],
            "category": "dimension",
            "field_type": "ValidityEndDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true",
            "description": "Validity End Date",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_CostCenter",
            "field_name": "CostCenterName",
            "technical_name": "KTEXT",
            "aliases": ["ktext", "costcentername", "cctr_name", "name"],
            "category": "dimension",
            "field_type": "CostCenterName",
            "data_type": "CHAR(40)",
            "vocabulary": "Common",
            "annotations": "@Common.Label",
            "description": "Cost Center Name",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_CostCenter",
            "field_name": "CostCenterDescription",
            "technical_name": "LTEXT",
            "aliases": ["ltext", "description", "cctr_desc"],
            "category": "dimension",
            "field_type": "CostCenterDescription",
            "data_type": "CHAR(40)",
            "vocabulary": "Common",
            "annotations": "@Common.QuickInfo",
            "description": "Cost Center Long Text",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_CostCenter",
            "field_name": "CostCenterCategory",
            "technical_name": "KOSAR",
            "aliases": ["kosar", "category", "cctr_category"],
            "category": "dimension",
            "field_type": "CostCenterCategory",
            "data_type": "CHAR(1)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Cost Center Category",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_CostCenter",
            "field_name": "CompanyCode",
            "technical_name": "BUKRS",
            "aliases": ["bukrs", "companycode"],
            "category": "dimension",
            "field_type": "CompanyCode",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Company Code",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_CostCenter",
            "field_name": "ProfitCenter",
            "technical_name": "PRCTR",
            "aliases": ["prctr", "profitcenter"],
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
            "entity": "I_CostCenter",
            "field_name": "ResponsiblePerson",
            "technical_name": "VERAK",
            "aliases": ["verak", "responsible", "manager"],
            "category": "dimension",
            "field_type": "ResponsiblePerson",
            "data_type": "CHAR(20)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true",
            "description": "Person Responsible for Cost Center",
            "module": "CO",
            "is_key": False
        },
    ]


def get_profit_center_fields() -> List[Dict]:
    """I_ProfitCenter entity fields."""
    return [
        {
            "entity": "I_ProfitCenter",
            "field_name": "ProfitCenter",
            "technical_name": "PRCTR",
            "aliases": ["prctr", "profitcenter", "profit_center", "pctr"],
            "category": "key",
            "field_type": "ProfitCenter",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Profit Center",
            "module": "CO",
            "is_key": True
        },
        {
            "entity": "I_ProfitCenter",
            "field_name": "ControllingArea",
            "technical_name": "KOKRS",
            "aliases": ["kokrs", "controllingarea"],
            "category": "key",
            "field_type": "ControllingArea",
            "data_type": "CHAR(4)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Controlling Area",
            "module": "CO",
            "is_key": True
        },
        {
            "entity": "I_ProfitCenter",
            "field_name": "ValidityStartDate",
            "technical_name": "DATAB",
            "aliases": ["datab", "validfrom"],
            "category": "key",
            "field_type": "ValidityStartDate",
            "data_type": "DATS",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Validity Start Date",
            "module": "CO",
            "is_key": True
        },
        {
            "entity": "I_ProfitCenter",
            "field_name": "ProfitCenterName",
            "technical_name": "KTEXT",
            "aliases": ["ktext", "profitcentername", "name"],
            "category": "dimension",
            "field_type": "ProfitCenterName",
            "data_type": "CHAR(40)",
            "vocabulary": "Common",
            "annotations": "@Common.Label",
            "description": "Profit Center Name",
            "module": "CO",
            "is_key": False
        },
        {
            "entity": "I_ProfitCenter",
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
            "entity": "I_ProfitCenter",
            "field_name": "CompanyCode",
            "technical_name": "BUKRS",
            "aliases": ["bukrs", "companycode"],
            "category": "dimension",
            "field_type": "CompanyCode",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Company Code",
            "module": "FI",
            "is_key": False
        },
        {
            "entity": "I_ProfitCenter",
            "field_name": "ResponsiblePerson",
            "technical_name": "VERAK",
            "aliases": ["verak", "responsible"],
            "category": "dimension",
            "field_type": "ResponsiblePerson",
            "data_type": "CHAR(20)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true",
            "description": "Person Responsible",
            "module": "CO",
            "is_key": False
        },
    ]


def get_material_fields() -> List[Dict]:
    """I_Product (Material) entity fields."""
    return [
        {
            "entity": "I_Product",
            "field_name": "Product",
            "technical_name": "MATNR",
            "aliases": ["matnr", "material", "product", "material_number"],
            "category": "key",
            "field_type": "Product",
            "data_type": "CHAR(40)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Material/Product Number",
            "module": "MM",
            "is_key": True
        },
        {
            "entity": "I_Product",
            "field_name": "ProductType",
            "technical_name": "MTART",
            "aliases": ["mtart", "materialtype", "product_type"],
            "category": "dimension",
            "field_type": "ProductType",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Material Type",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "ProductGroup",
            "technical_name": "MATKL",
            "aliases": ["matkl", "materialgroup", "product_group"],
            "category": "dimension",
            "field_type": "ProductGroup",
            "data_type": "CHAR(9)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Material Group",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "ProductDescription",
            "technical_name": "MAKTX",
            "aliases": ["maktx", "description", "material_desc"],
            "category": "dimension",
            "field_type": "ProductDescription",
            "data_type": "CHAR(40)",
            "vocabulary": "Common",
            "annotations": "@Common.Label",
            "description": "Material Description",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "BaseUnit",
            "technical_name": "MEINS",
            "aliases": ["meins", "baseunit", "base_uom", "uom"],
            "category": "dimension",
            "field_type": "BaseUnit",
            "data_type": "UNIT(3)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.unitOfMeasure: true",
            "description": "Base Unit of Measure",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "GrossWeight",
            "technical_name": "BRGEW",
            "aliases": ["brgew", "grossweight", "gross_weight"],
            "category": "measure",
            "field_type": "GrossWeight",
            "data_type": "QUAN(13,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Gross Weight",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "NetWeight",
            "technical_name": "NTGEW",
            "aliases": ["ntgew", "netweight", "net_weight"],
            "category": "measure",
            "field_type": "NetWeight",
            "data_type": "QUAN(13,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Net Weight",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "WeightUnit",
            "technical_name": "GEWEI",
            "aliases": ["gewei", "weightunit", "weight_uom"],
            "category": "dimension",
            "field_type": "WeightUnit",
            "data_type": "UNIT(3)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.unitOfMeasure: true",
            "description": "Weight Unit",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_Product",
            "field_name": "IndustryStandardName",
            "technical_name": "NORMT",
            "aliases": ["normt", "industrystandard", "ean"],
            "category": "dimension",
            "field_type": "IndustryStandardName",
            "data_type": "CHAR(18)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true",
            "description": "Industry Standard Description (EAN)",
            "module": "MM",
            "is_key": False
        },
    ]


def get_gl_account_fields() -> List[Dict]:
    """I_GLAccountInChartOfAccounts entity fields."""
    return [
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "GLAccount",
            "technical_name": "SAKNR",
            "aliases": ["saknr", "glaccount", "gl_account", "account"],
            "category": "key",
            "field_type": "GLAccount",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "G/L Account Number",
            "module": "FI-GL",
            "is_key": True
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "ChartOfAccounts",
            "technical_name": "KTOPL",
            "aliases": ["ktopl", "chartofaccounts", "coa"],
            "category": "key",
            "field_type": "ChartOfAccounts",
            "data_type": "CHAR(4)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Chart of Accounts",
            "module": "FI-GL",
            "is_key": True
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "GLAccountName",
            "technical_name": "TXT20",
            "aliases": ["txt20", "accountname", "gl_name"],
            "category": "dimension",
            "field_type": "GLAccountName",
            "data_type": "CHAR(20)",
            "vocabulary": "Common",
            "annotations": "@Common.Label",
            "description": "G/L Account Short Text",
            "module": "FI-GL",
            "is_key": False
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "GLAccountLongName",
            "technical_name": "TXT50",
            "aliases": ["txt50", "accountlongname", "gl_long_name"],
            "category": "dimension",
            "field_type": "GLAccountLongName",
            "data_type": "CHAR(50)",
            "vocabulary": "Common",
            "annotations": "@Common.QuickInfo",
            "description": "G/L Account Long Text",
            "module": "FI-GL",
            "is_key": False
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "GLAccountType",
            "technical_name": "KTOKS",
            "aliases": ["ktoks", "accounttype", "gl_type"],
            "category": "dimension",
            "field_type": "GLAccountType",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "G/L Account Type",
            "module": "FI-GL",
            "is_key": False
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "GLAccountGroup",
            "technical_name": "KTOGR",
            "aliases": ["ktogr", "accountgroup", "gl_group"],
            "category": "dimension",
            "field_type": "GLAccountGroup",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "G/L Account Group",
            "module": "FI-GL",
            "is_key": False
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "IsBalanceSheetAccount",
            "technical_name": "XBILK",
            "aliases": ["xbilk", "balancesheet", "bs_indicator"],
            "category": "dimension",
            "field_type": "IsBalanceSheetAccount",
            "data_type": "CHAR(1)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Balance Sheet Account Indicator",
            "module": "FI-GL",
            "is_key": False
        },
        {
            "entity": "I_GLAccountInChartOfAccounts",
            "field_name": "IsProfitLossAccount",
            "technical_name": "GVTYP",
            "aliases": ["gvtyp", "profitloss", "pl_indicator"],
            "category": "dimension",
            "field_type": "IsProfitLossAccount",
            "data_type": "CHAR(1)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "P&L Statement Account Type",
            "module": "FI-GL",
            "is_key": False
        },
    ]


def main():
    print("=" * 60)
    print("Populating Master Data fields into Elasticsearch")
    print("=" * 60)
    
    all_fields = []
    
    # Cost Center
    print("\n1. Loading Cost Center (I_CostCenter) fields...")
    cc_fields = get_cost_center_fields()
    print(f"   Loaded {len(cc_fields)} fields")
    all_fields.extend(cc_fields)
    
    # Profit Center
    print("\n2. Loading Profit Center (I_ProfitCenter) fields...")
    pc_fields = get_profit_center_fields()
    print(f"   Loaded {len(pc_fields)} fields")
    all_fields.extend(pc_fields)
    
    # Material/Product
    print("\n3. Loading Material (I_Product) fields...")
    mat_fields = get_material_fields()
    print(f"   Loaded {len(mat_fields)} fields")
    all_fields.extend(mat_fields)
    
    # GL Account
    print("\n4. Loading GL Account (I_GLAccountInChartOfAccounts) fields...")
    gl_fields = get_gl_account_fields()
    print(f"   Loaded {len(gl_fields)} fields")
    all_fields.extend(gl_fields)
    
    # Bulk index all
    print("\n5. Indexing all fields...")
    bulk_index(all_fields)
    
    # Summary
    print("\n" + "=" * 60)
    print("Summary by Entity:")
    entities = {}
    for f in all_fields:
        ent = f.get("entity", "unknown")
        entities[ent] = entities.get(ent, 0) + 1
    
    for ent, count in sorted(entities.items()):
        print(f"  {ent}: {count} fields")
    
    print(f"\nTotal: {len(all_fields)} fields indexed")
    print("=" * 60)


if __name__ == "__main__":
    main()