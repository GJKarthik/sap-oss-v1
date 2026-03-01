# SAP Business Data Products - Finance (GL/Subledger)

## Overview

SAP Business Data Products are pre-built, curated data products available through SAP Datasphere and SAP Business Data Cloud. For S/4HANA Finance, these include the Universal Journal (ACDOCA) and related entities.

## S/4HANA Finance - General Ledger Data Products

### Core Entities

| Data Product | CDS View | Description |
|-------------|----------|-------------|
| **Journal Entry** | `I_JournalEntry` | Journal entry header |
| **Journal Entry Item** | `I_JournalEntryItem` | Line items (ACDOCA) |
| **GL Account Line Item** | `I_GLAccountLineItem` | GL account line items |
| **GL Account** | `I_GLAccountInChartOfAccounts` | GL account master |
| **Company Code** | `I_CompanyCode` | Company code master |
| **Ledger** | `I_Ledger` | Ledger definitions |
| **Fiscal Year Period** | `I_FiscalYearPeriod` | Fiscal periods |
| **Cost Center** | `I_CostCenter` | Cost center master |
| **Profit Center** | `I_ProfitCenter` | Profit center master |

### Universal Journal (ACDOCA) Fields

The Universal Journal is the single source of truth for financial postings in S/4HANA:

```
ACDOCA Fields (I_JournalEntryItem):
├── Key Fields
│   ├── CompanyCode (BUKRS)
│   ├── FiscalYear (GJAHR)
│   ├── AccountingDocument (BELNR)
│   ├── AccountingDocumentItem (BUZEI)
│   └── Ledger (RLDNR)
│
├── GL Account
│   ├── GLAccount (RACCT/HKONT)
│   ├── ChartOfAccounts (KTOPL)
│   └── GLAccountType
│
├── Organizational Units
│   ├── CompanyCode (BUKRS)
│   ├── BusinessArea (GSBER)
│   ├── ControllingArea (KOKRS)
│   ├── CostCenter (RCNTR/KOSTL)
│   ├── ProfitCenter (PRCTR)
│   └── Segment (SEGMENT)
│
├── Amounts
│   ├── AmountInCompanyCodeCurrency (HSL)
│   ├── AmountInTransactionCurrency (WSL)
│   ├── AmountInGlobalCurrency (KSL)
│   └── Quantity (MSL)
│
├── Currencies
│   ├── CompanyCodeCurrency (RHCUR)
│   ├── TransactionCurrency (RWCUR)
│   └── GlobalCurrency (RKCUR)
│
└── Dates
    ├── PostingDate (BUDAT)
    ├── DocumentDate (BLDAT)
    └── FiscalPeriod (MONAT)
```

## OData Vocabulary Annotations for Finance

### Standard SAP Annotations Used

```xml
<!-- Analytics Vocabulary -->
@Analytics.Dimension: true
@Analytics.Measure: true

<!-- Aggregation Vocabulary -->
@Aggregation.Groupable: true
@Aggregation.Aggregatable: true

<!-- Semantics Vocabulary -->
@Semantics.amount.currencyCode: 'CompanyCodeCurrency'
@Semantics.currencyCode: true
@Semantics.quantity.unitOfMeasure: 'BaseUnit'
@Semantics.unitOfMeasure: true

<!-- Common Vocabulary -->
@Common.Label: 'GL Account'
@Common.QuickInfo: 'General Ledger Account Number'
@Common.SemanticKey: ['CompanyCode', 'FiscalYear', 'AccountingDocument']
```

### Example: I_JournalEntryItem Annotations

```cds
@Analytics.dataCategory: #FACT
@VDM.viewType: #CONSUMPTION
entity I_JournalEntryItem {
  
  // Key fields - Dimensions
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Company Code'
  key CompanyCode : abap.char(4);
  
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Fiscal Year'
  key FiscalYear : abap.numc(4);
  
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Accounting Document'
  key AccountingDocument : abap.char(10);
  
  @Analytics.dimension: true
  @Common.label: 'Line Item'
  key AccountingDocumentItem : abap.numc(6);
  
  @Analytics.dimension: true
  @Common.label: 'Ledger'
  key Ledger : abap.char(2);
  
  // GL Account - Dimension
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'G/L Account'
  GLAccount : abap.char(10);
  
  // Organizational Units - Dimensions
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Cost Center'
  CostCenter : abap.char(10);
  
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Profit Center'
  ProfitCenter : abap.char(10);
  
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Segment'
  Segment : abap.char(10);
  
  // Amounts - Measures
  @Analytics.measure: true
  @Aggregation.aggregatable: true
  @Semantics.amount.currencyCode: 'CompanyCodeCurrency'
  @Common.label: 'Amount in Company Code Currency'
  AmountInCompanyCodeCurrency : abap.curr(23, 2);
  
  @Analytics.measure: true
  @Aggregation.aggregatable: true
  @Semantics.amount.currencyCode: 'TransactionCurrency'
  @Common.label: 'Amount in Transaction Currency'
  AmountInTransactionCurrency : abap.curr(23, 2);
  
  @Analytics.measure: true
  @Aggregation.aggregatable: true
  @Semantics.amount.currencyCode: 'GlobalCurrency'
  @Common.label: 'Amount in Global Currency'
  AmountInGlobalCurrency : abap.curr(23, 2);
  
  // Currencies - Reference
  @Semantics.currencyCode: true
  @Common.label: 'Company Code Currency'
  CompanyCodeCurrency : abap.cuky(5);
  
  @Semantics.currencyCode: true
  @Common.label: 'Transaction Currency'
  TransactionCurrency : abap.cuky(5);
  
  // Dates - Dimensions
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Posting Date'
  PostingDate : abap.dats;
  
  @Analytics.dimension: true
  @Aggregation.groupable: true
  @Common.label: 'Fiscal Period'
  FiscalPeriod : abap.numc(3);
}
```

## Field Classification for Data Cleaning

### Dimension Fields (Groupable)
- `CompanyCode` - Company Code
- `FiscalYear` - Fiscal Year
- `FiscalPeriod` - Fiscal Period
- `GLAccount` - G/L Account
- `CostCenter` - Cost Center
- `ProfitCenter` - Profit Center
- `Segment` - Segment
- `BusinessArea` - Business Area
- `AccountingDocumentType` - Document Type
- `PostingDate` - Posting Date

### Measure Fields (Aggregatable)
- `AmountInCompanyCodeCurrency` (HSL)
- `AmountInTransactionCurrency` (WSL)
- `AmountInGlobalCurrency` (KSL)
- `Quantity` (MSL)

### Reference Fields
- `CompanyCodeCurrency` - Currency key for HSL
- `TransactionCurrency` - Currency key for WSL
- `GlobalCurrency` - Currency key for KSL
- `BaseUnit` - Unit of measure for quantity

### Key Fields
- `AccountingDocument` - Document number
- `AccountingDocumentItem` - Line item
- `Ledger` - Ledger identifier

## Subledger Integration

### Accounts Receivable (Customer)
| Field | Description | Annotation |
|-------|-------------|------------|
| `Customer` | Customer number | `@Analytics.dimension` |
| `CustomerName` | Customer name | `@Common.label` |
| `DueDate` | Payment due date | `@Analytics.dimension` |
| `ClearingDate` | Clearing date | `@Analytics.dimension` |

### Accounts Payable (Supplier)
| Field | Description | Annotation |
|-------|-------------|------------|
| `Supplier` | Supplier number | `@Analytics.dimension` |
| `SupplierName` | Supplier name | `@Common.label` |
| `PaymentTerms` | Payment terms | `@Analytics.dimension` |
| `CashDiscount` | Cash discount | `@Analytics.measure` |

### Asset Accounting
| Field | Description | Annotation |
|-------|-------------|------------|
| `FixedAsset` | Asset number | `@Analytics.dimension` |
| `AssetSubNumber` | Asset sub-number | `@Analytics.dimension` |
| `DepreciationArea` | Depreciation area | `@Analytics.dimension` |
| `DepreciationAmount` | Depreciation | `@Analytics.measure` |

## Usage in Data Cleaning

When cleaning S/4HANA Finance data, use these vocabularies to:

1. **Validate Dimensions**: Check that dimension fields are groupable
2. **Validate Measures**: Ensure amounts have currency references
3. **Check Semantic Keys**: Verify document uniqueness
4. **Validate Currency**: Ensure currency codes are valid ISO
5. **Check Organizational Units**: Validate cost center/profit center hierarchy

## References

- SAP Business Data Products: https://www.sap.com/products/technology-platform/datasphere.html
- S/4HANA CDS View Documentation: https://api.sap.com
- SAP OData Vocabularies: https://github.com/SAP/odata-vocabularies