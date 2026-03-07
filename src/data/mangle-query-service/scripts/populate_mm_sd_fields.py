#!/usr/bin/env python3
"""
Populate Elasticsearch with S/4HANA Procurement (MM) and Sales (SD) field mappings.

Includes:
- Purchase Order (I_PurchaseOrder, I_PurchaseOrderItem)
- Purchase Requisition (I_PurchaseRequisition)
- Sales Order (I_SalesOrder, I_SalesOrderItem)
- Sales Document (I_SalesDocument)
- Delivery (I_DeliveryDocument)
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


def get_purchase_order_fields() -> List[Dict]:
    """I_PurchaseOrder and I_PurchaseOrderItem entity fields."""
    return [
        # Purchase Order Header
        {
            "entity": "I_PurchaseOrder",
            "field_name": "PurchaseOrder",
            "technical_name": "EBELN",
            "aliases": ["ebeln", "purchaseorder", "purchase_order", "po_number", "ponumber"],
            "category": "key",
            "field_type": "PurchaseOrder",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Purchase Order Number",
            "module": "MM-PUR",
            "is_key": True
        },
        {
            "entity": "I_PurchaseOrder",
            "field_name": "PurchaseOrderType",
            "technical_name": "BSART",
            "aliases": ["bsart", "purchaseordertype", "po_type", "doc_type"],
            "category": "dimension",
            "field_type": "PurchaseOrderType",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Purchase Order Type",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrder",
            "field_name": "PurchasingOrganization",
            "technical_name": "EKORG",
            "aliases": ["ekorg", "purchasingorg", "purchasing_org", "purch_org"],
            "category": "dimension",
            "field_type": "PurchasingOrganization",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Purchasing Organization",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrder",
            "field_name": "PurchasingGroup",
            "technical_name": "EKGRP",
            "aliases": ["ekgrp", "purchasinggroup", "purchasing_group", "purch_group"],
            "category": "dimension",
            "field_type": "PurchasingGroup",
            "data_type": "CHAR(3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Purchasing Group",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrder",
            "field_name": "Supplier",
            "technical_name": "LIFNR",
            "aliases": ["lifnr", "supplier", "vendor"],
            "category": "dimension",
            "field_type": "Supplier",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Supplier Number",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrder",
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
            "entity": "I_PurchaseOrder",
            "field_name": "DocumentCurrency",
            "technical_name": "WAERS",
            "aliases": ["waers", "documentcurrency", "currency"],
            "category": "currency",
            "field_type": "DocumentCurrency",
            "data_type": "CUKY(5)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.currencyCode: true",
            "description": "Document Currency",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrder",
            "field_name": "PurchaseOrderDate",
            "technical_name": "BEDAT",
            "aliases": ["bedat", "purchaseorderdate", "po_date", "order_date"],
            "category": "dimension",
            "field_type": "PurchaseOrderDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Purchase Order Date",
            "module": "MM-PUR",
            "is_key": False
        },
        
        # Purchase Order Item
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "PurchaseOrderItem",
            "technical_name": "EBELP",
            "aliases": ["ebelp", "purchaseorderitem", "po_item", "item_no"],
            "category": "key",
            "field_type": "PurchaseOrderItem",
            "data_type": "NUMC(5)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Purchase Order Item Number",
            "module": "MM-PUR",
            "is_key": True
        },
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "Material",
            "technical_name": "MATNR",
            "aliases": ["matnr", "material", "product"],
            "category": "dimension",
            "field_type": "Material",
            "data_type": "CHAR(40)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Material Number",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "Plant",
            "technical_name": "WERKS",
            "aliases": ["werks", "plant"],
            "category": "dimension",
            "field_type": "Plant",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Plant",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "StorageLocation",
            "technical_name": "LGORT",
            "aliases": ["lgort", "storagelocation", "storage_loc"],
            "category": "dimension",
            "field_type": "StorageLocation",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Storage Location",
            "module": "MM-IM",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "OrderQuantity",
            "technical_name": "MENGE",
            "aliases": ["menge", "orderquantity", "order_qty", "quantity"],
            "category": "measure",
            "field_type": "OrderQuantity",
            "data_type": "QUAN(13,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Order Quantity",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "NetPriceAmount",
            "technical_name": "NETPR",
            "aliases": ["netpr", "netprice", "net_price", "unitprice"],
            "category": "measure",
            "field_type": "NetPriceAmount",
            "data_type": "CURR(11,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Net Price",
            "module": "MM-PUR",
            "is_key": False
        },
        {
            "entity": "I_PurchaseOrderItem",
            "field_name": "NetOrderValue",
            "technical_name": "NETWR",
            "aliases": ["netwr", "netvalue", "net_value", "ordervalue"],
            "category": "measure",
            "field_type": "NetOrderValue",
            "data_type": "CURR(13,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Net Order Value",
            "module": "MM-PUR",
            "is_key": False
        },
    ]


def get_sales_order_fields() -> List[Dict]:
    """I_SalesOrder and I_SalesOrderItem entity fields."""
    return [
        # Sales Order Header
        {
            "entity": "I_SalesOrder",
            "field_name": "SalesOrder",
            "technical_name": "VBELN",
            "aliases": ["vbeln", "salesorder", "sales_order", "so_number", "sonumber"],
            "category": "key",
            "field_type": "SalesOrder",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Sales Order Number",
            "module": "SD-SLS",
            "is_key": True
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "SalesOrderType",
            "technical_name": "AUART",
            "aliases": ["auart", "salesordertype", "so_type", "order_type"],
            "category": "dimension",
            "field_type": "SalesOrderType",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Sales Order Type",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "SalesOrganization",
            "technical_name": "VKORG",
            "aliases": ["vkorg", "salesorg", "sales_org"],
            "category": "dimension",
            "field_type": "SalesOrganization",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Sales Organization",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "DistributionChannel",
            "technical_name": "VTWEG",
            "aliases": ["vtweg", "distributionchannel", "dist_channel"],
            "category": "dimension",
            "field_type": "DistributionChannel",
            "data_type": "CHAR(2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Distribution Channel",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "Division",
            "technical_name": "SPART",
            "aliases": ["spart", "division"],
            "category": "dimension",
            "field_type": "Division",
            "data_type": "CHAR(2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Division",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "SoldToParty",
            "technical_name": "KUNNR",
            "aliases": ["kunnr", "soldtoparty", "sold_to", "customer"],
            "category": "dimension",
            "field_type": "Customer",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Sold-To Party (Customer)",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "SalesOrderDate",
            "technical_name": "AUDAT",
            "aliases": ["audat", "salesorderdate", "so_date", "order_date"],
            "category": "dimension",
            "field_type": "SalesOrderDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Sales Order Date",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "TransactionCurrency",
            "technical_name": "WAERK",
            "aliases": ["waerk", "transactioncurrency", "currency"],
            "category": "currency",
            "field_type": "TransactionCurrency",
            "data_type": "CUKY(5)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.currencyCode: true",
            "description": "SD Document Currency",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrder",
            "field_name": "TotalNetAmount",
            "technical_name": "NETWR",
            "aliases": ["netwr", "totalnetamount", "net_value", "total_net"],
            "category": "measure",
            "field_type": "TotalNetAmount",
            "data_type": "CURR(15,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Total Net Amount",
            "module": "SD-SLS",
            "is_key": False
        },
        
        # Sales Order Item
        {
            "entity": "I_SalesOrderItem",
            "field_name": "SalesOrderItem",
            "technical_name": "POSNR",
            "aliases": ["posnr", "salesorderitem", "so_item", "item_no"],
            "category": "key",
            "field_type": "SalesOrderItem",
            "data_type": "NUMC(6)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Sales Order Item Number",
            "module": "SD-SLS",
            "is_key": True
        },
        {
            "entity": "I_SalesOrderItem",
            "field_name": "Material",
            "technical_name": "MATNR",
            "aliases": ["matnr", "material", "product"],
            "category": "dimension",
            "field_type": "Material",
            "data_type": "CHAR(40)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Material Number",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_SalesOrderItem",
            "field_name": "Plant",
            "technical_name": "WERKS",
            "aliases": ["werks", "plant"],
            "category": "dimension",
            "field_type": "Plant",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Plant",
            "module": "MM",
            "is_key": False
        },
        {
            "entity": "I_SalesOrderItem",
            "field_name": "RequestedQuantity",
            "technical_name": "KWMENG",
            "aliases": ["kwmeng", "requestedquantity", "requested_qty", "order_qty"],
            "category": "measure",
            "field_type": "RequestedQuantity",
            "data_type": "QUAN(15,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Requested Quantity",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrderItem",
            "field_name": "NetAmount",
            "technical_name": "NETWR",
            "aliases": ["netwr", "netamount", "net_value", "line_value"],
            "category": "measure",
            "field_type": "NetAmount",
            "data_type": "CURR(15,2)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Net Amount",
            "module": "SD-SLS",
            "is_key": False
        },
        {
            "entity": "I_SalesOrderItem",
            "field_name": "BaseUnit",
            "technical_name": "MEINS",
            "aliases": ["meins", "baseunit", "uom"],
            "category": "dimension",
            "field_type": "BaseUnit",
            "data_type": "UNIT(3)",
            "vocabulary": "Semantics",
            "annotations": "@Semantics.unitOfMeasure: true",
            "description": "Base Unit of Measure",
            "module": "MM",
            "is_key": False
        },
    ]


def get_delivery_fields() -> List[Dict]:
    """I_DeliveryDocument entity fields."""
    return [
        {
            "entity": "I_DeliveryDocument",
            "field_name": "DeliveryDocument",
            "technical_name": "VBELN",
            "aliases": ["vbeln", "deliverydocument", "delivery", "delivery_no"],
            "category": "key",
            "field_type": "DeliveryDocument",
            "data_type": "CHAR(10)",
            "vocabulary": "Common",
            "annotations": "@Common.SemanticKey",
            "description": "Delivery Document Number",
            "module": "SD-DLV",
            "is_key": True
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "DeliveryDocumentType",
            "technical_name": "LFART",
            "aliases": ["lfart", "deliverytype", "delivery_type"],
            "category": "dimension",
            "field_type": "DeliveryDocumentType",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Delivery Type",
            "module": "SD-DLV",
            "is_key": False
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "ShipToParty",
            "technical_name": "KUNNR",
            "aliases": ["kunnr", "shiptoparty", "ship_to", "customer"],
            "category": "dimension",
            "field_type": "Customer",
            "data_type": "CHAR(10)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Ship-To Party",
            "module": "SD-DLV",
            "is_key": False
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "ShippingPoint",
            "technical_name": "VSTEL",
            "aliases": ["vstel", "shippingpoint", "shipping_point"],
            "category": "dimension",
            "field_type": "ShippingPoint",
            "data_type": "CHAR(4)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Shipping Point",
            "module": "SD-DLV",
            "is_key": False
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "PlannedGoodsIssueDate",
            "technical_name": "WADAT",
            "aliases": ["wadat", "plannedgidate", "planned_gi_date", "gi_date"],
            "category": "dimension",
            "field_type": "PlannedGoodsIssueDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Planned Goods Issue Date",
            "module": "SD-DLV",
            "is_key": False
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "ActualGoodsMovementDate",
            "technical_name": "WADAT_IST",
            "aliases": ["wadat_ist", "actualgidate", "actual_gi_date"],
            "category": "dimension",
            "field_type": "ActualGoodsMovementDate",
            "data_type": "DATS",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.dimension: true, @Aggregation.groupable: true",
            "description": "Actual Goods Movement Date",
            "module": "SD-DLV",
            "is_key": False
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "TotalGrossWeight",
            "technical_name": "BTGEW",
            "aliases": ["btgew", "totalgrossweight", "gross_weight"],
            "category": "measure",
            "field_type": "TotalGrossWeight",
            "data_type": "QUAN(15,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Total Gross Weight",
            "module": "SD-DLV",
            "is_key": False
        },
        {
            "entity": "I_DeliveryDocument",
            "field_name": "TotalNetWeight",
            "technical_name": "NTGEW",
            "aliases": ["ntgew", "totalnetweight", "net_weight"],
            "category": "measure",
            "field_type": "TotalNetWeight",
            "data_type": "QUAN(15,3)",
            "vocabulary": "Analytics",
            "annotations": "@Analytics.measure: true, @Aggregation.aggregatable: true",
            "description": "Total Net Weight",
            "module": "SD-DLV",
            "is_key": False
        },
    ]


def main():
    print("=" * 60)
    print("Populating MM (Procurement) and SD (Sales) fields")
    print("=" * 60)
    
    all_fields = []
    
    # Purchase Order
    print("\n1. Loading Purchase Order fields...")
    po_fields = get_purchase_order_fields()
    print(f"   Loaded {len(po_fields)} fields")
    all_fields.extend(po_fields)
    
    # Sales Order
    print("\n2. Loading Sales Order fields...")
    so_fields = get_sales_order_fields()
    print(f"   Loaded {len(so_fields)} fields")
    all_fields.extend(so_fields)
    
    # Delivery
    print("\n3. Loading Delivery fields...")
    dlv_fields = get_delivery_fields()
    print(f"   Loaded {len(dlv_fields)} fields")
    all_fields.extend(dlv_fields)
    
    # Bulk index all
    print("\n4. Indexing all fields...")
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
    
    modules = {}
    for f in all_fields:
        mod = f.get("module", "unknown")
        modules[mod] = modules.get(mod, 0) + 1
    
    print("\nSummary by Module:")
    for mod, count in sorted(modules.items()):
        print(f"  {mod}: {count} fields")
    
    print(f"\nTotal: {len(all_fields)} fields indexed")
    print("=" * 60)


if __name__ == "__main__":
    main()