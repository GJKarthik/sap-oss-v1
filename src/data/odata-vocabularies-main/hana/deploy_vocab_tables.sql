-- ============================================================================
-- OData Vocabularies - HANA Cloud Native Integration
-- Deploy vocabulary tables for field classification and discovery
-- ============================================================================

-- Create schema for OData Vocabularies
CREATE SCHEMA IF NOT EXISTS "ODATA_VOCAB";

-- ============================================================================
-- 1. VOCABULARY_TERMS - OData vocabulary terms from Analytics, Common, etc.
-- ============================================================================
CREATE COLUMN TABLE "ODATA_VOCAB"."VOCABULARY_TERMS" (
    "VOCABULARY" NVARCHAR(50) NOT NULL,
    "TERM" NVARCHAR(100) NOT NULL,
    "TERM_TYPE" NVARCHAR(50),
    "APPLIES_TO" NVARCHAR(200),
    "BASE_TYPE" NVARCHAR(100),
    "DESCRIPTION" NVARCHAR(500),
    PRIMARY KEY ("VOCABULARY", "TERM")
);

-- Analytics vocabulary terms
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Analytics', 'dimension', 'Term', 'Property', 'Boolean', 'Marks a property as an analytical dimension');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Analytics', 'measure', 'Term', 'Property', 'Boolean', 'Marks a property as an analytical measure');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Analytics', 'dataCategory', 'Term', 'EntityType', 'String', 'Defines the data category (FACT, DIMENSION, etc.)');

-- Aggregation vocabulary terms
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Aggregation', 'groupable', 'Term', 'Property', 'Boolean', 'Property can be used for grouping');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Aggregation', 'aggregatable', 'Term', 'Property', 'Boolean', 'Property can be aggregated');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Aggregation', 'default', 'Term', 'Property', 'String', 'Default aggregation method');

-- Common vocabulary terms
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Common', 'SemanticKey', 'Term', 'EntityType', 'PropertyPath[]', 'Properties that form the semantic key');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Common', 'Label', 'Term', 'Property', 'String', 'Human-readable label');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Common', 'QuickInfo', 'Term', 'Property', 'String', 'Quick info tooltip text');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Common', 'Text', 'Term', 'Property', 'PropertyPath', 'Text property for a code');

-- Semantics vocabulary terms (for S/4HANA Finance)
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Semantics', 'currencyCode', 'Term', 'Property', 'Boolean', 'Marks property as currency code');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Semantics', 'amount.currencyCode', 'Term', 'Property', 'PropertyPath', 'Currency code for amount field');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Semantics', 'unitOfMeasure', 'Term', 'Property', 'Boolean', 'Marks property as unit of measure');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('Semantics', 'quantity.unitOfMeasure', 'Term', 'Property', 'PropertyPath', 'Unit for quantity field');

-- ============================================================================
-- 2. ENTITY_FIELDS - S/4HANA Finance field definitions
-- ============================================================================
CREATE COLUMN TABLE "ODATA_VOCAB"."ENTITY_FIELDS" (
    "ENTITY" NVARCHAR(100) NOT NULL,
    "FIELD_NAME" NVARCHAR(100) NOT NULL,
    "TECHNICAL_NAME" NVARCHAR(30) NOT NULL,
    "CATEGORY" NVARCHAR(20) NOT NULL,  -- dimension, measure, currency, key, subledger
    "FIELD_TYPE" NVARCHAR(100),
    "DATA_TYPE" NVARCHAR(50),
    "VOCABULARY" NVARCHAR(50),
    "ANNOTATIONS" NVARCHAR(500),
    "DESCRIPTION" NVARCHAR(500),
    "MODULE" NVARCHAR(20),
    "IS_KEY" BOOLEAN DEFAULT FALSE,
    "CURRENCY_REFERENCE" NVARCHAR(100),
    PRIMARY KEY ("ENTITY", "TECHNICAL_NAME")
);

-- Create text search on field names
CREATE FULLTEXT INDEX "ODATA_VOCAB"."FTI_ENTITY_FIELDS" 
ON "ODATA_VOCAB"."ENTITY_FIELDS" ("FIELD_NAME", "DESCRIPTION")
CONFIGURATION 'ODATA_VOCAB_SEARCH'
ASYNC;

-- ============================================================================
-- 3. FIELD_ALIASES - Alternative names for field matching
-- ============================================================================
CREATE COLUMN TABLE "ODATA_VOCAB"."FIELD_ALIASES" (
    "ENTITY" NVARCHAR(100) NOT NULL,
    "TECHNICAL_NAME" NVARCHAR(30) NOT NULL,
    "ALIAS" NVARCHAR(100) NOT NULL,
    PRIMARY KEY ("ENTITY", "TECHNICAL_NAME", "ALIAS"),
    FOREIGN KEY ("ENTITY", "TECHNICAL_NAME") 
        REFERENCES "ODATA_VOCAB"."ENTITY_FIELDS" ("ENTITY", "TECHNICAL_NAME")
);

-- ============================================================================
-- 4. Insert ACDOCA (I_JournalEntryItem) fields
-- ============================================================================

-- Key Fields
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'CompanyCode', 'BUKRS', 'dimension', 'CompanyCode', 
    'CHAR(4)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable, @Common.SemanticKey',
    'Company Code', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUKRS', 'bukrs');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUKRS', 'companycode');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUKRS', 'company_code');

INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'FiscalYear', 'GJAHR', 'dimension', 'FiscalYear', 
    'NUMC(4)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable, @Common.SemanticKey',
    'Fiscal Year', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'GJAHR', 'gjahr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'GJAHR', 'fiscalyear');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'GJAHR', 'fiscal_year');

INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AccountingDocument', 'BELNR', 'key', 'AccountingDocument', 
    'CHAR(10)', 'Common', '@Common.SemanticKey',
    'Accounting Document Number', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BELNR', 'belnr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BELNR', 'accountingdocument');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BELNR', 'document_number');

-- GL Account
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'GLAccount', 'HKONT', 'dimension', 'GLAccount', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'General Ledger Account', 'FI-GL', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'hkont');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'racct');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'glaccount');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'gl_account');

-- Cost Center
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'CostCenter', 'KOSTL', 'dimension', 'CostCenter', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Cost Center', 'CO', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'kostl');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'rcntr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'costcenter');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'cost_center');

-- Profit Center
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'ProfitCenter', 'PRCTR', 'dimension', 'ProfitCenter', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Profit Center', 'CO', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'PRCTR', 'prctr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'PRCTR', 'profitcenter');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'PRCTR', 'profit_center');

-- Amount in Company Code Currency (Measure)
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AmountInCompanyCodeCurrency', 'HSL', 'measure', 
    'AmountInCompanyCodeCurrency', 'CURR(23,2)', 'Analytics', 
    '@Analytics.measure, @Aggregation.aggregatable, @Semantics.amount.currencyCode: CompanyCodeCurrency',
    'Amount in Company Code Currency', 'FI', FALSE, 'CompanyCodeCurrency'
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'hsl');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'amountincompanycodecurrency');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'amount_lc');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'localamount');

-- Amount in Transaction Currency (Measure)
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AmountInTransactionCurrency', 'WSL', 'measure', 
    'AmountInTransactionCurrency', 'CURR(23,2)', 'Analytics', 
    '@Analytics.measure, @Aggregation.aggregatable, @Semantics.amount.currencyCode: TransactionCurrency',
    'Amount in Transaction Currency', 'FI', FALSE, 'TransactionCurrency'
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'WSL', 'wsl');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'WSL', 'amountintransactioncurrency');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'WSL', 'amount_tc');

-- Company Code Currency (Reference)
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'CompanyCodeCurrency', 'RHCUR', 'currency', 
    'CompanyCodeCurrency', 'CUKY(5)', 'Semantics', '@Semantics.currencyCode',
    'Currency Key for Company Code Currency', 'FI', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'rhcur');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'companycodecurrency');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'waers');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'localcurrency');

-- Posting Date
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'PostingDate', 'BUDAT', 'dimension', 'PostingDate', 
    'DATS', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Posting Date in the Document', 'FI', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUDAT', 'budat');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUDAT', 'postingdate');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUDAT', 'posting_date');

-- Customer (Subledger - AR)
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'Customer', 'KUNNR', 'subledger', 'Customer', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Customer Number (Accounts Receivable)', 'FI-AR', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KUNNR', 'kunnr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KUNNR', 'customer');

-- Supplier (Subledger - AP)
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'Supplier', 'LIFNR', 'subledger', 'Supplier', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Supplier Number (Accounts Payable)', 'FI-AP', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'LIFNR', 'lifnr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'LIFNR', 'supplier');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'LIFNR', 'vendor');

-- ============================================================================
-- 5. Stored Procedures for Field Classification
-- ============================================================================

-- Classify a single field by name
CREATE OR REPLACE PROCEDURE "ODATA_VOCAB"."CLASSIFY_FIELD" (
    IN iv_field_name NVARCHAR(100),
    OUT ov_category NVARCHAR(20),
    OUT ov_field_type NVARCHAR(100),
    OUT ov_annotations NVARCHAR(500),
    OUT ov_entity NVARCHAR(100)
)
LANGUAGE SQLSCRIPT
SQL SECURITY INVOKER
AS
BEGIN
    DECLARE lv_field_lower NVARCHAR(100);
    
    -- Normalize to lowercase
    lv_field_lower := LOWER(iv_field_name);
    
    -- First try exact technical name match
    SELECT TOP 1 "CATEGORY", "FIELD_TYPE", "ANNOTATIONS", "ENTITY"
    INTO ov_category, ov_field_type, ov_annotations, ov_entity
    FROM "ODATA_VOCAB"."ENTITY_FIELDS"
    WHERE LOWER("TECHNICAL_NAME") = lv_field_lower;
    
    -- If not found, try alias match
    IF ov_category IS NULL THEN
        SELECT TOP 1 ef."CATEGORY", ef."FIELD_TYPE", ef."ANNOTATIONS", ef."ENTITY"
        INTO ov_category, ov_field_type, ov_annotations, ov_entity
        FROM "ODATA_VOCAB"."ENTITY_FIELDS" ef
        JOIN "ODATA_VOCAB"."FIELD_ALIASES" fa ON ef."ENTITY" = fa."ENTITY" AND ef."TECHNICAL_NAME" = fa."TECHNICAL_NAME"
        WHERE LOWER(fa."ALIAS") = lv_field_lower;
    END IF;
    
    -- If still not found, try fuzzy match on field name
    IF ov_category IS NULL THEN
        SELECT TOP 1 "CATEGORY", "FIELD_TYPE", "ANNOTATIONS", "ENTITY"
        INTO ov_category, ov_field_type, ov_annotations, ov_entity
        FROM "ODATA_VOCAB"."ENTITY_FIELDS"
        WHERE LOWER("FIELD_NAME") LIKE '%' || lv_field_lower || '%'
        ORDER BY LENGTH("FIELD_NAME");
    END IF;
END;

-- Get all fields for an entity
CREATE OR REPLACE PROCEDURE "ODATA_VOCAB"."GET_ENTITY_FIELDS" (
    IN iv_entity NVARCHAR(100),
    OUT ot_fields TABLE (
        "FIELD_NAME" NVARCHAR(100),
        "TECHNICAL_NAME" NVARCHAR(30),
        "CATEGORY" NVARCHAR(20),
        "FIELD_TYPE" NVARCHAR(100),
        "DATA_TYPE" NVARCHAR(50),
        "ANNOTATIONS" NVARCHAR(500),
        "DESCRIPTION" NVARCHAR(500),
        "IS_KEY" BOOLEAN
    )
)
LANGUAGE SQLSCRIPT
SQL SECURITY INVOKER
AS
BEGIN
    ot_fields = SELECT 
        "FIELD_NAME", "TECHNICAL_NAME", "CATEGORY", "FIELD_TYPE",
        "DATA_TYPE", "ANNOTATIONS", "DESCRIPTION", "IS_KEY"
    FROM "ODATA_VOCAB"."ENTITY_FIELDS"
    WHERE "ENTITY" = iv_entity
    ORDER BY "IS_KEY" DESC, "FIELD_NAME";
END;

-- Search vocabulary terms
CREATE OR REPLACE PROCEDURE "ODATA_VOCAB"."SEARCH_TERMS" (
    IN iv_query NVARCHAR(200),
    OUT ot_terms TABLE (
        "VOCABULARY" NVARCHAR(50),
        "TERM" NVARCHAR(100),
        "TERM_TYPE" NVARCHAR(50),
        "APPLIES_TO" NVARCHAR(200),
        "DESCRIPTION" NVARCHAR(500)
    )
)
LANGUAGE SQLSCRIPT
SQL SECURITY INVOKER
AS
BEGIN
    DECLARE lv_query_lower NVARCHAR(200);
    lv_query_lower := LOWER(iv_query);
    
    ot_terms = SELECT 
        "VOCABULARY", "TERM", "TERM_TYPE", "APPLIES_TO", "DESCRIPTION"
    FROM "ODATA_VOCAB"."VOCABULARY_TERMS"
    WHERE LOWER("VOCABULARY") LIKE '%' || lv_query_lower || '%'
       OR LOWER("TERM") LIKE '%' || lv_query_lower || '%'
       OR LOWER("DESCRIPTION") LIKE '%' || lv_query_lower || '%'
    ORDER BY "VOCABULARY", "TERM";
END;

-- ============================================================================
-- 6. Views for easy querying
-- ============================================================================

-- Dimension fields view
CREATE OR REPLACE VIEW "ODATA_VOCAB"."V_DIMENSION_FIELDS" AS
SELECT * FROM "ODATA_VOCAB"."ENTITY_FIELDS" WHERE "CATEGORY" = 'dimension';

-- Measure fields view
CREATE OR REPLACE VIEW "ODATA_VOCAB"."V_MEASURE_FIELDS" AS
SELECT * FROM "ODATA_VOCAB"."ENTITY_FIELDS" WHERE "CATEGORY" = 'measure';

-- Key fields view
CREATE OR REPLACE VIEW "ODATA_VOCAB"."V_KEY_FIELDS" AS
SELECT * FROM "ODATA_VOCAB"."ENTITY_FIELDS" WHERE "IS_KEY" = TRUE;

-- Subledger fields view
CREATE OR REPLACE VIEW "ODATA_VOCAB"."V_SUBLEDGER_FIELDS" AS
SELECT * FROM "ODATA_VOCAB"."ENTITY_FIELDS" WHERE "CATEGORY" = 'subledger';

-- ============================================================================
-- Grant permissions
-- ============================================================================
-- GRANT SELECT ON SCHEMA "ODATA_VOCAB" TO <service_user>;
-- GRANT EXECUTE ON SCHEMA "ODATA_VOCAB" TO <service_user>;