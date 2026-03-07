# ============================================================================
# Data Cleaning Copilot - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for data cleaning MCP communication.
# Integrated with SAP Business Data Products for S/4HANA Finance GL/Subledger
# ============================================================================

# 1. Service Registry
service_registry("dcc-quality",     "http://localhost:9110/mcp",  "quality-analyzer").
service_registry("dcc-profiling",   "http://localhost:9110/mcp",  "data-profiler").
service_registry("dcc-anomaly",     "http://localhost:9110/mcp",  "anomaly-detector").
service_registry("dcc-ai-chat",     "http://localhost:9110/mcp",  "claude-3.5-sonnet").

# OData Vocabularies Service - Analytics/Aggregation for S/4 Finance
service_registry("odata-vocab",     "http://localhost:9150/mcp",  "odata-vocab-annotator").

# 2. Intent Routing
resolve_service_for_intent(/quality_check, URL) :-
    service_registry("dcc-quality", URL, _).

resolve_service_for_intent(/profiling, URL) :-
    service_registry("dcc-profiling", URL, _).

resolve_service_for_intent(/anomaly, URL) :-
    service_registry("dcc-anomaly", URL, _).

resolve_service_for_intent(/chat, URL) :-
    service_registry("dcc-ai-chat", URL, _).

resolve_service_for_intent(/finance_field_classification, URL) :-
    service_registry("odata-vocab", URL, _).

resolve_service_for_intent(/gl_subledger_validation, URL) :-
    service_registry("odata-vocab", URL, _).

# 3. Tool Routing
tool_service("data_quality_check", "dcc-quality").
tool_service("schema_analysis", "dcc-quality").
tool_service("data_profiling", "dcc-profiling").
tool_service("anomaly_detection", "dcc-anomaly").
tool_service("generate_cleaning_query", "dcc-ai-chat").
tool_service("ai_chat", "dcc-ai-chat").
tool_service("mangle_query", "dcc-quality").

# OData Vocabulary Tools for S/4 Finance Data Classification
tool_service("get_finance_vocabulary_terms", "odata-vocab").
tool_service("classify_gl_fields", "odata-vocab").
tool_service("suggest_finance_annotations", "odata-vocab").
tool_service("validate_acdoca_schema", "odata-vocab").

# 4. Quality Rules
quality_threshold("completeness", 95.0).
quality_threshold("accuracy", 99.0).
quality_threshold("consistency", 98.0).

quality_pass(Check, Score) :-
    quality_threshold(Check, Threshold),
    Score >= Threshold.

quality_fail(Check, Score) :-
    quality_threshold(Check, Threshold),
    Score < Threshold.

# ============================================================================
# 5. SAP S/4HANA Finance Field Classification Rules
# Uses Analytics/Aggregation vocabulary for GL/Subledger field classification
# Based on SAP Business Data Products: I_JournalEntryItem (ACDOCA)
# ============================================================================

# ----- DIMENSION Fields (Groupable) -----

# Company Code patterns (BUKRS)
is_dimension_field(Column, "CompanyCode") :-
    fn:contains(fn:lower(Column), "bukrs").
is_dimension_field(Column, "CompanyCode") :-
    fn:contains(fn:lower(Column), "companycode").
is_dimension_field(Column, "CompanyCode") :-
    fn:contains(fn:lower(Column), "company_code").

# Fiscal Year patterns (GJAHR)
is_dimension_field(Column, "FiscalYear") :-
    fn:contains(fn:lower(Column), "gjahr").
is_dimension_field(Column, "FiscalYear") :-
    fn:contains(fn:lower(Column), "fiscalyear").
is_dimension_field(Column, "FiscalYear") :-
    fn:contains(fn:lower(Column), "fiscal_year").

# Fiscal Period patterns (MONAT)
is_dimension_field(Column, "FiscalPeriod") :-
    fn:contains(fn:lower(Column), "monat").
is_dimension_field(Column, "FiscalPeriod") :-
    fn:contains(fn:lower(Column), "fiscalperiod").
is_dimension_field(Column, "FiscalPeriod") :-
    fn:contains(fn:lower(Column), "fiscal_period").
is_dimension_field(Column, "FiscalPeriod") :-
    fn:contains(fn:lower(Column), "postingperiod").

# GL Account patterns (HKONT/RACCT)
is_dimension_field(Column, "GLAccount") :-
    fn:contains(fn:lower(Column), "hkont").
is_dimension_field(Column, "GLAccount") :-
    fn:contains(fn:lower(Column), "racct").
is_dimension_field(Column, "GLAccount") :-
    fn:contains(fn:lower(Column), "glaccount").
is_dimension_field(Column, "GLAccount") :-
    fn:contains(fn:lower(Column), "gl_account").
is_dimension_field(Column, "GLAccount") :-
    fn:contains(fn:lower(Column), "sachkonto").

# Cost Center patterns (KOSTL/RCNTR)
is_dimension_field(Column, "CostCenter") :-
    fn:contains(fn:lower(Column), "kostl").
is_dimension_field(Column, "CostCenter") :-
    fn:contains(fn:lower(Column), "rcntr").
is_dimension_field(Column, "CostCenter") :-
    fn:contains(fn:lower(Column), "costcenter").
is_dimension_field(Column, "CostCenter") :-
    fn:contains(fn:lower(Column), "cost_center").
is_dimension_field(Column, "CostCenter") :-
    fn:contains(fn:lower(Column), "kostenstelle").

# Profit Center patterns (PRCTR)
is_dimension_field(Column, "ProfitCenter") :-
    fn:contains(fn:lower(Column), "prctr").
is_dimension_field(Column, "ProfitCenter") :-
    fn:contains(fn:lower(Column), "profitcenter").
is_dimension_field(Column, "ProfitCenter") :-
    fn:contains(fn:lower(Column), "profit_center").

# Segment patterns
is_dimension_field(Column, "Segment") :-
    fn:contains(fn:lower(Column), "segment").

# Business Area patterns (GSBER)
is_dimension_field(Column, "BusinessArea") :-
    fn:contains(fn:lower(Column), "gsber").
is_dimension_field(Column, "BusinessArea") :-
    fn:contains(fn:lower(Column), "businessarea").
is_dimension_field(Column, "BusinessArea") :-
    fn:contains(fn:lower(Column), "business_area").

# Controlling Area (KOKRS)
is_dimension_field(Column, "ControllingArea") :-
    fn:contains(fn:lower(Column), "kokrs").
is_dimension_field(Column, "ControllingArea") :-
    fn:contains(fn:lower(Column), "controllingarea").

# Ledger patterns (RLDNR)
is_dimension_field(Column, "Ledger") :-
    fn:contains(fn:lower(Column), "rldnr").
is_dimension_field(Column, "Ledger") :-
    fn:contains(fn:lower(Column), "ledger").

# Document Type patterns (BLART)
is_dimension_field(Column, "AccountingDocumentType") :-
    fn:contains(fn:lower(Column), "blart").
is_dimension_field(Column, "AccountingDocumentType") :-
    fn:contains(fn:lower(Column), "documenttype").
is_dimension_field(Column, "AccountingDocumentType") :-
    fn:contains(fn:lower(Column), "doc_type").

# Posting Date patterns (BUDAT)
is_dimension_field(Column, "PostingDate") :-
    fn:contains(fn:lower(Column), "budat").
is_dimension_field(Column, "PostingDate") :-
    fn:contains(fn:lower(Column), "postingdate").
is_dimension_field(Column, "PostingDate") :-
    fn:contains(fn:lower(Column), "posting_date").

# ----- MEASURE Fields (Aggregatable) -----

# Amount in Company Code Currency (HSL)
is_measure_field(Column, "AmountInCompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "hsl").
is_measure_field(Column, "AmountInCompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "amountincompanycodecurrency").
is_measure_field(Column, "AmountInCompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "amount_lc").
is_measure_field(Column, "AmountInCompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "localamount").

# Amount in Transaction Currency (WSL)
is_measure_field(Column, "AmountInTransactionCurrency") :-
    fn:contains(fn:lower(Column), "wsl").
is_measure_field(Column, "AmountInTransactionCurrency") :-
    fn:contains(fn:lower(Column), "amountintransactioncurrency").
is_measure_field(Column, "AmountInTransactionCurrency") :-
    fn:contains(fn:lower(Column), "amount_tc").
is_measure_field(Column, "AmountInTransactionCurrency") :-
    fn:contains(fn:lower(Column), "transactionamount").

# Amount in Global Currency (KSL)
is_measure_field(Column, "AmountInGlobalCurrency") :-
    fn:contains(fn:lower(Column), "ksl").
is_measure_field(Column, "AmountInGlobalCurrency") :-
    fn:contains(fn:lower(Column), "amountinglobalcurrency").
is_measure_field(Column, "AmountInGlobalCurrency") :-
    fn:contains(fn:lower(Column), "amount_gc").
is_measure_field(Column, "AmountInGlobalCurrency") :-
    fn:contains(fn:lower(Column), "globalamount").

# Quantity (MSL)
is_measure_field(Column, "Quantity") :-
    fn:contains(fn:lower(Column), "msl").
is_measure_field(Column, "Quantity") :-
    fn:contains(fn:lower(Column), "quantity").
is_measure_field(Column, "Quantity") :-
    fn:contains(fn:lower(Column), "menge").

# Debit/Credit amounts (DMBTR, WRBTR)
is_measure_field(Column, "DebitCreditAmount") :-
    fn:contains(fn:lower(Column), "dmbtr").
is_measure_field(Column, "DebitCreditAmount") :-
    fn:contains(fn:lower(Column), "wrbtr").

# ----- CURRENCY Reference Fields -----

# Company Code Currency (RHCUR)
is_currency_field(Column, "CompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "rhcur").
is_currency_field(Column, "CompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "companycodecurrency").
is_currency_field(Column, "CompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "currency_lc").
is_currency_field(Column, "CompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "localcurrency").
is_currency_field(Column, "CompanyCodeCurrency") :-
    fn:contains(fn:lower(Column), "waers").

# Transaction Currency (RWCUR)
is_currency_field(Column, "TransactionCurrency") :-
    fn:contains(fn:lower(Column), "rwcur").
is_currency_field(Column, "TransactionCurrency") :-
    fn:contains(fn:lower(Column), "transactioncurrency").
is_currency_field(Column, "TransactionCurrency") :-
    fn:contains(fn:lower(Column), "currency_tc").

# ----- KEY Fields (Semantic Keys) -----

# Document Number (BELNR)
is_key_field(Column, "AccountingDocument") :-
    fn:contains(fn:lower(Column), "belnr").
is_key_field(Column, "AccountingDocument") :-
    fn:contains(fn:lower(Column), "accountingdocument").
is_key_field(Column, "AccountingDocument") :-
    fn:contains(fn:lower(Column), "document_number").
is_key_field(Column, "AccountingDocument") :-
    fn:contains(fn:lower(Column), "docnumber").

# Line Item (BUZEI)
is_key_field(Column, "AccountingDocumentItem") :-
    fn:contains(fn:lower(Column), "buzei").
is_key_field(Column, "AccountingDocumentItem") :-
    fn:contains(fn:lower(Column), "lineitem").
is_key_field(Column, "AccountingDocumentItem") :-
    fn:contains(fn:lower(Column), "line_item").

# ----- SUBLEDGER Fields -----

# Customer (KUNNR) - Accounts Receivable
is_subledger_field(Column, "Customer") :-
    fn:contains(fn:lower(Column), "kunnr").
is_subledger_field(Column, "Customer") :-
    fn:contains(fn:lower(Column), "customer").

# Supplier/Vendor (LIFNR) - Accounts Payable
is_subledger_field(Column, "Supplier") :-
    fn:contains(fn:lower(Column), "lifnr").
is_subledger_field(Column, "Supplier") :-
    fn:contains(fn:lower(Column), "supplier").
is_subledger_field(Column, "Supplier") :-
    fn:contains(fn:lower(Column), "vendor").

# Fixed Asset (ANLN1) - Asset Accounting
is_subledger_field(Column, "FixedAsset") :-
    fn:contains(fn:lower(Column), "anln1").
is_subledger_field(Column, "FixedAsset") :-
    fn:contains(fn:lower(Column), "fixedasset").
is_subledger_field(Column, "FixedAsset") :-
    fn:contains(fn:lower(Column), "asset").

# ----- Classification Rules -----

# Suggest Analytics.dimension annotation
suggest_finance_annotation(Column, Annotation) :-
    is_dimension_field(Column, FieldType),
    Annotation = fn:format('@Analytics.dimension: true, @Aggregation.groupable: true // %s', FieldType).

# Suggest Analytics.measure annotation
suggest_finance_annotation(Column, Annotation) :-
    is_measure_field(Column, FieldType),
    Annotation = fn:format('@Analytics.measure: true, @Aggregation.aggregatable: true // %s', FieldType).

# Suggest Semantics.currencyCode annotation
suggest_finance_annotation(Column, Annotation) :-
    is_currency_field(Column, FieldType),
    Annotation = fn:format('@Semantics.currencyCode: true // %s', FieldType).

# Suggest Common.SemanticKey annotation
suggest_finance_annotation(Column, Annotation) :-
    is_key_field(Column, FieldType),
    Annotation = fn:format('@Common.SemanticKey // %s', FieldType).

# Suggest subledger dimension annotation
suggest_finance_annotation(Column, Annotation) :-
    is_subledger_field(Column, FieldType),
    Annotation = fn:format('@Analytics.dimension: true // Subledger: %s', FieldType).

# Check if field is part of ACDOCA schema
is_acdoca_field(Column) :-
    is_dimension_field(Column, _).
is_acdoca_field(Column) :-
    is_measure_field(Column, _).
is_acdoca_field(Column) :-
    is_currency_field(Column, _).
is_acdoca_field(Column) :-
    is_key_field(Column, _).
is_acdoca_field(Column) :-
    is_subledger_field(Column, _).