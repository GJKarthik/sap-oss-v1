# SAP CDS Views for OData Vocabularies

## Important Clarification

**The CDS views already exist in S/4HANA** - they are standard SAP-delivered views. You don't need to create them.

### Where CDS Views Exist

| Component | CDS Views Created | Description |
|-----------|-------------------|-------------|
| **S/4HANA System** | ✅ Yes (Standard) | SAP delivers `I_JournalEntryItem`, `I_CostCenter`, etc. |
| **HANA Cloud** | ❌ No | HANA Cloud receives replicated data or virtual access |
| **BTP/Datasphere** | Virtual Tables | Connects to S/4HANA CDS views via federation |

---

## Architecture: S/4HANA → HANA Cloud Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        S/4HANA System                                │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  ABAP Dictionary Tables (ACDOCA, T001, CSKS, etc.)            │  │
│  │         ↓                                                      │  │
│  │  CDS Views (I_JournalEntryItem, I_CostCenter, etc.)           │  │
│  │         ↓                                                      │  │
│  │  OData Services (API_JOURNALENTRYITEM_SRV)                    │  │
│  └───────────────────────────────────────────────────────────────┘  │
│         │                                                            │
│         │ Data Replication (SLT/SDA/Datasphere)                     │
│         ↓                                                            │
└─────────────────────────────────────────────────────────────────────┘
         │
         ↓
┌─────────────────────────────────────────────────────────────────────┐
│                    SAP HANA Cloud / BTP                              │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Option 1: Replicated Tables                                   │  │
│  │    - Physical copy of ACDOCA data                             │  │
│  │    - Updated via SLT/SDI/Datasphere                           │  │
│  │                                                                │  │
│  │  Option 2: Virtual Tables (Smart Data Access)                  │  │
│  │    - No data copy, federated query                            │  │
│  │    - Real-time access to S/4HANA                              │  │
│  │                                                                │  │
│  │  Option 3: SAP Datasphere Views                               │  │
│  │    - Consumption views over replicated/virtual data           │  │
│  └───────────────────────────────────────────────────────────────┘  │
│         │                                                            │
│         │ Vector Embeddings                                          │
│         ↓                                                            │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  PAL_STORE / FINSIGHT_RAG                                      │  │
│  │    - Embedding vectors for RAG queries                         │  │
│  │    - Vocabulary term lookups                                   │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Standard S/4HANA CDS Views (Already Exist)

These are **standard SAP-delivered CDS views** in S/4HANA. You do NOT create them:

### Finance - Universal Journal

```abap
-- Standard SAP CDS View (delivered with S/4HANA)
@AbapCatalog.sqlViewName: 'IJOURNALENTRYITEM'
@Analytics.dataCategory: #FACT
@VDM.viewType: #CONSUMPTION
@ObjectModel.representativeKey: 'JournalEntry'
define view I_JournalEntryItem
  as select from acdoca as ACDOCA
  association [1..1] to I_JournalEntry     as _JournalEntry     on ...
  association [1..1] to I_GLAccountInChartOfAccounts as _GLAccount on ...
  association [0..1] to I_CostCenter       as _CostCenter       on ...
  association [0..1] to I_ProfitCenter     as _ProfitCenter     on ...
{
  @Analytics.dimension: true
  key rldnr as Ledger,
  @Analytics.dimension: true
  key rbukrs as CompanyCode,
  @Analytics.dimension: true
  key gjahr as FiscalYear,
  @Analytics.dimension: true
  key belnr as AccountingDocument,
  @Analytics.dimension: true
  key docln as LedgerGLLineItem,
  
  @Analytics.dimension: true
  racct as GLAccount,
  @Analytics.dimension: true
  rcntr as CostCenter,
  @Analytics.dimension: true
  prctr as ProfitCenter,
  
  @Analytics.measure: true
  @Semantics.amount.currencyCode: 'CompanyCodeCurrency'
  hsl as AmountInCompanyCodeCurrency,
  @Semantics.currencyCode: true
  rhcur as CompanyCodeCurrency,
  
  @Analytics.measure: true
  @Semantics.amount.currencyCode: 'TransactionCurrency'
  wsl as AmountInTransactionCurrency,
  @Semantics.currencyCode: true
  rwcur as TransactionCurrency,
  
  -- Associations
  _JournalEntry,
  _GLAccount,
  _CostCenter,
  _ProfitCenter
}
```

### Finance - Cost Center

```abap
-- Standard SAP CDS View (delivered with S/4HANA)
@AbapCatalog.sqlViewName: 'ICOSTCENTER'
@Analytics.dataCategory: #DIMENSION
@VDM.viewType: #CONSUMPTION
define view I_CostCenter
  as select from csks as CSKS
{
  key kokrs as ControllingArea,
  key kostl as CostCenter,
  datab as ValidityStartDate,
  datbi as ValidityEndDate,
  ktext as CostCenterName,
  verak as PersonResponsible,
  prctr as ProfitCenter,
  bukrs as CompanyCode
}
```

### Finance - Profit Center

```abap
-- Standard SAP CDS View (delivered with S/4HANA)
@AbapCatalog.sqlViewName: 'IPROFITCENTER'
@Analytics.dataCategory: #DIMENSION
@VDM.viewType: #CONSUMPTION
define view I_ProfitCenter
  as select from cepc as CEPC
{
  key kokrs as ControllingArea,
  key prctr as ProfitCenter,
  datab as ValidityStartDate,
  datbi as ValidityEndDate,
  ktext as ProfitCenterName,
  bukrs as CompanyCode,
  segment as Segment
}
```

---

## What You Need in HANA Cloud

For the OData Vocabularies AI system, you need these in HANA Cloud:

### Option A: Replicated Finance Data (Recommended for Production)

```sql
-- ============================================================================
-- HANA Cloud - Replicated Finance Tables (via SLT/SDI/Datasphere)
-- ============================================================================

-- 1. Create schema for replicated S/4HANA data
CREATE SCHEMA IF NOT EXISTS "S4HANA_FINANCE";

-- 2. Tables are created automatically by replication tool (SLT/SDI)
-- These mirror the S/4HANA tables:
--   S4HANA_FINANCE.ACDOCA     → Universal Journal items
--   S4HANA_FINANCE.T001       → Company codes
--   S4HANA_FINANCE.CSKS       → Cost centers
--   S4HANA_FINANCE.CEPC       → Profit centers
--   S4HANA_FINANCE.SKA1       → GL account master

-- 3. Create consumption views on top (optional)
CREATE VIEW "S4HANA_FINANCE"."V_JOURNAL_ENTRY_ITEM" AS
SELECT
    rldnr AS "Ledger",
    rbukrs AS "CompanyCode",
    gjahr AS "FiscalYear",
    belnr AS "AccountingDocument",
    docln AS "LedgerGLLineItem",
    racct AS "GLAccount",
    rcntr AS "CostCenter",
    prctr AS "ProfitCenter",
    budat AS "PostingDate",
    hsl AS "AmountInCompanyCodeCurrency",
    rhcur AS "CompanyCodeCurrency",
    wsl AS "AmountInTransactionCurrency",
    rwcur AS "TransactionCurrency"
FROM "S4HANA_FINANCE"."ACDOCA";
```

### Option B: Virtual Tables via SDA (Real-time Federation)

```sql
-- ============================================================================
-- HANA Cloud - Virtual Tables (Smart Data Access to S/4HANA)
-- ============================================================================

-- 1. Create remote source connection to S/4HANA HANA database
CREATE REMOTE SOURCE "S4HANA_SDA"
ADAPTER "hanaodbc"
CONFIGURATION FILE 'property_s4hana.ini';

-- 2. Create virtual tables pointing to S/4HANA
CREATE VIRTUAL TABLE "S4HANA_FINANCE"."ACDOCA_VIRTUAL"
AT "S4HANA_SDA"."<SID>"."SAPABAP1"."ACDOCA";

CREATE VIRTUAL TABLE "S4HANA_FINANCE"."T001_VIRTUAL"
AT "S4HANA_SDA"."<SID>"."SAPABAP1"."T001";
```

### Option C: SAP Datasphere (Recommended for AI/Analytics)

In SAP Datasphere, create:

1. **Connections** → S/4HANA Cloud or On-Premise
2. **Import Entities** → Select CDS views (I_JournalEntryItem, etc.)
3. **Analytical Datasets** → Create on top of imported views
4. **Consumption Layer** → Expose via OData or HANA Cloud views

---

## For the OData Vocabularies RAG System

The vocabularies describe **how to interpret** the fields. You need:

### In S/4HANA (No Action Required)
- ✅ Standard CDS views exist (I_JournalEntryItem, etc.)
- ✅ OData services exposed (API_JOURNALENTRYITEM_SRV)

### In HANA Cloud (Your Setup)

```sql
-- 1. Metadata tables (created from deploy_all_hana_tables.sql)
ODATA_VOCAB.VOCABULARY_TERMS    -- OData vocabulary definitions
ODATA_VOCAB.ENTITY_FIELDS       -- Field metadata (what the vocab describes)
ODATA_VOCAB.FIELD_ALIASES       -- Alternative field names

-- 2. Vector store for RAG
PAL_STORE.EMBEDDINGS            -- Vocabulary embeddings for search
PAL_STORE.COLLECTIONS           -- Embedding collections

-- 3. Optional: Finance data for AI training
S4HANA_FINANCE.ACDOCA           -- Replicated/virtual journal entries
```

---

## Quick Reference: Where Everything Lives

| Component | Location | Type |
|-----------|----------|------|
| **CDS Views** | S/4HANA | Standard SAP-delivered |
| **ACDOCA Table** | S/4HANA | ABAP Dictionary Table |
| **OData Services** | S/4HANA | Auto-generated from CDS |
| **Vocabulary Metadata** | HANA Cloud | ODATA_VOCAB schema |
| **Embeddings** | HANA Cloud | PAL_STORE schema |
| **Replicated Data** | HANA Cloud | Via SLT/SDI/Datasphere |

---

## Summary

**You do NOT need to create CDS views** - they already exist in S/4HANA as standard SAP content.

**What you DO need:**
1. **S/4HANA**: Access to the standard CDS views (I_JournalEntryItem, etc.)
2. **HANA Cloud**: 
   - Vocabulary metadata tables (`ODATA_VOCAB.*`)
   - Vector store tables (`PAL_STORE.*`)
   - Optional: Replicated or virtual access to S/4HANA data

**Data Flow:**
```
S/4HANA (CDS Views) → Replication/Federation → HANA Cloud → RAG/AI Services