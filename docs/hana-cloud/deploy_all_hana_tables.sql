-- ============================================================================
-- SAP HANA Cloud - Complete Table Deployment Script
-- For OData Vocabularies & AI Training Pipeline
-- ============================================================================
-- 
-- Execute this script in SAP HANA Cloud to create all required tables
-- for the SAP AI Fabric deployment including:
-- - OData Vocabulary classification
-- - FinSight core data model
-- - RAG embeddings & chunks
-- - Governance & quality tracking
-- - Lineage graph
-- - LangChain vector store (PAL_STORE)
--
-- ============================================================================

-- ============================================================================
-- STEP 1: CREATE SCHEMAS
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "ODATA_VOCAB";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_CORE";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_RAG";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_GOV";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_GRAPH";
CREATE SCHEMA IF NOT EXISTS "PAL_STORE";

-- ============================================================================
-- STEP 2: ODATA_VOCAB SCHEMA TABLES
-- ============================================================================

-- Vocabulary Terms from OData specs (Analytics, Common, Semantics, etc.)
CREATE COLUMN TABLE "ODATA_VOCAB"."VOCABULARY_TERMS" (
    "VOCABULARY" NVARCHAR(50) NOT NULL,
    "TERM" NVARCHAR(100) NOT NULL,
    "TERM_TYPE" NVARCHAR(50),
    "APPLIES_TO" NVARCHAR(200),
    "BASE_TYPE" NVARCHAR(100),
    "DESCRIPTION" NVARCHAR(500),
    PRIMARY KEY ("VOCABULARY", "TERM")
);

-- Entity field definitions with OData annotations (S/4HANA Finance fields)
CREATE COLUMN TABLE "ODATA_VOCAB"."ENTITY_FIELDS" (
    "ENTITY" NVARCHAR(100) NOT NULL,
    "FIELD_NAME" NVARCHAR(100) NOT NULL,
    "TECHNICAL_NAME" NVARCHAR(30) NOT NULL,
    "CATEGORY" NVARCHAR(20) NOT NULL,
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

-- Field aliases for fuzzy matching
CREATE COLUMN TABLE "ODATA_VOCAB"."FIELD_ALIASES" (
    "ENTITY" NVARCHAR(100) NOT NULL,
    "TECHNICAL_NAME" NVARCHAR(30) NOT NULL,
    "ALIAS" NVARCHAR(100) NOT NULL,
    PRIMARY KEY ("ENTITY", "TECHNICAL_NAME", "ALIAS"),
    FOREIGN KEY ("ENTITY", "TECHNICAL_NAME") 
        REFERENCES "ODATA_VOCAB"."ENTITY_FIELDS" ("ENTITY", "TECHNICAL_NAME")
);

-- ============================================================================
-- STEP 3: FINSIGHT_CORE SCHEMA TABLES
-- ============================================================================

-- Master records table
CREATE COLUMN TABLE "FINSIGHT_CORE"."RECORDS" (
    "RECORD_ID" NVARCHAR(64) NOT NULL,
    "SOURCE_TABLE" NVARCHAR(100) NOT NULL,
    "SOURCE_FILE" NVARCHAR(255),
    "SOURCE_ROW_NUMBER" INTEGER,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("RECORD_ID")
);

-- Entity-Attribute-Value field storage
CREATE COLUMN TABLE "FINSIGHT_CORE"."FIELDS" (
    "RECORD_ID" NVARCHAR(64) NOT NULL,
    "FIELD_NAME" NVARCHAR(120) NOT NULL,
    "FIELD_VALUE" NVARCHAR(5000),
    "DATA_TYPE" NVARCHAR(50),
    "IS_NULL" BOOLEAN DEFAULT FALSE,
    PRIMARY KEY ("RECORD_ID", "FIELD_NAME"),
    FOREIGN KEY ("RECORD_ID") REFERENCES "FINSIGHT_CORE"."RECORDS" ("RECORD_ID")
);

-- Source file inventory
CREATE COLUMN TABLE "FINSIGHT_CORE"."SOURCE_FILES" (
    "SOURCE_FILE" NVARCHAR(255) NOT NULL,
    "SOURCE_TABLE" NVARCHAR(100) NOT NULL,
    "ROW_COUNT" INTEGER,
    "FIELD_COUNT" INTEGER,
    "FILE_SIZE_BYTES" BIGINT,
    "PROCESSED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("SOURCE_FILE")
);

-- ============================================================================
-- STEP 4: FINSIGHT_RAG SCHEMA TABLES
-- ============================================================================

-- RAG chunks table
CREATE COLUMN TABLE "FINSIGHT_RAG"."CHUNKS" (
    "CHUNK_ID" NVARCHAR(64) NOT NULL,
    "RECORD_ID" NVARCHAR(64),
    "CHUNK_INDEX" INTEGER NOT NULL,
    "CHUNK_TEXT" NCLOB,
    "CHUNK_SIZE" INTEGER,
    "SOURCE_TABLE" NVARCHAR(100),
    "METADATA" NCLOB,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("CHUNK_ID")
);

-- Embedding vectors table (using HANA Vector Engine)
CREATE COLUMN TABLE "FINSIGHT_RAG"."EMBEDDINGS" (
    "EMBEDDING_ID" NVARCHAR(64) NOT NULL,
    "CHUNK_ID" NVARCHAR(64) NOT NULL,
    "EMBEDDING_VECTOR" REAL_VECTOR(1536),
    "MODEL_NAME" NVARCHAR(100),
    "MODEL_VERSION" NVARCHAR(50),
    "DIMENSIONS" INTEGER,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("EMBEDDING_ID"),
    FOREIGN KEY ("CHUNK_ID") REFERENCES "FINSIGHT_RAG"."CHUNKS" ("CHUNK_ID")
);

-- Embedding generation manifest
CREATE COLUMN TABLE "FINSIGHT_RAG"."EMBEDDING_MANIFEST" (
    "RUN_ID" NVARCHAR(64) NOT NULL,
    "MODEL_NAME" NVARCHAR(100) NOT NULL,
    "MODEL_VERSION" NVARCHAR(50),
    "TOTAL_CHUNKS" INTEGER,
    "TOTAL_EMBEDDINGS" INTEGER,
    "STARTED_AT" TIMESTAMP,
    "COMPLETED_AT" TIMESTAMP,
    "STATUS" NVARCHAR(20),
    "PARAMETERS" NCLOB,
    PRIMARY KEY ("RUN_ID")
);

-- ============================================================================
-- STEP 5: FINSIGHT_GOV SCHEMA TABLES
-- ============================================================================

-- Row-level quality issues
CREATE COLUMN TABLE "FINSIGHT_GOV"."QUALITY_ISSUES" (
    "RECORD_ID" NVARCHAR(64) NOT NULL,
    "ISSUE_TYPE" NVARCHAR(50) NOT NULL,
    "FIELD" NVARCHAR(120) NOT NULL,
    "SOURCE_ROW_NUMBER" INTEGER NOT NULL,
    "SEVERITY" NVARCHAR(20),
    "MESSAGE" NVARCHAR(500),
    "EXPECTED_VALUE" NVARCHAR(500),
    "ACTUAL_VALUE" NVARCHAR(500),
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("RECORD_ID", "ISSUE_TYPE", "FIELD", "SOURCE_ROW_NUMBER")
);

-- Quality report snapshots
CREATE COLUMN TABLE "FINSIGHT_GOV"."QUALITY_REPORTS" (
    "REPORT_ID" NVARCHAR(64) NOT NULL,
    "REPORT_TYPE" NVARCHAR(50),
    "TOTAL_RECORDS" INTEGER,
    "VALID_RECORDS" INTEGER,
    "INVALID_RECORDS" INTEGER,
    "QUALITY_SCORE" DECIMAL(5,2),
    "GENERATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "REPORT_DATA" NCLOB,
    PRIMARY KEY ("REPORT_ID")
);

-- Table-level completeness metrics
CREATE COLUMN TABLE "FINSIGHT_GOV"."TABLE_PROFILE" (
    "TABLE_NAME" NVARCHAR(100) NOT NULL,
    "REPORT_ID" NVARCHAR(64) NOT NULL,
    "ROW_COUNT" INTEGER,
    "COLUMN_COUNT" INTEGER,
    "NULL_COUNT" INTEGER,
    "COMPLETENESS_PCT" DECIMAL(5,2),
    "MANDATORY_COVERAGE_PCT" DECIMAL(5,2),
    PRIMARY KEY ("TABLE_NAME", "REPORT_ID")
);

-- ODPS validation results
CREATE COLUMN TABLE "FINSIGHT_GOV"."ODPS_VALIDATION" (
    "VALIDATION_RUN_ID" NVARCHAR(64) NOT NULL,
    "SCHEMA_NAME" NVARCHAR(100),
    "TABLE_NAME" NVARCHAR(100),
    "FIELD_NAME" NVARCHAR(120),
    "VALIDATION_TYPE" NVARCHAR(50),
    "IS_VALID" BOOLEAN,
    "ERROR_MESSAGE" NVARCHAR(500),
    "VALIDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("VALIDATION_RUN_ID")
);

-- ============================================================================
-- STEP 6: FINSIGHT_GRAPH SCHEMA TABLES
-- ============================================================================

-- Graph vertices (nodes)
CREATE COLUMN TABLE "FINSIGHT_GRAPH"."VERTEX" (
    "VERTEX_ID" NVARCHAR(64) NOT NULL,
    "VERTEX_TYPE" NVARCHAR(50) NOT NULL,
    "NAME" NVARCHAR(255) NOT NULL,
    "PROPERTIES" NCLOB,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("VERTEX_ID")
);

-- Graph edges (relationships)
CREATE COLUMN TABLE "FINSIGHT_GRAPH"."EDGE" (
    "EDGE_ID" NVARCHAR(64) NOT NULL,
    "EDGE_TYPE" NVARCHAR(50) NOT NULL,
    "SOURCE_VERTEX_ID" NVARCHAR(64) NOT NULL,
    "TARGET_VERTEX_ID" NVARCHAR(64) NOT NULL,
    "WEIGHT" DECIMAL(5,2) DEFAULT 1.0,
    "PROPERTIES" NCLOB,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("EDGE_ID"),
    FOREIGN KEY ("SOURCE_VERTEX_ID") REFERENCES "FINSIGHT_GRAPH"."VERTEX" ("VERTEX_ID"),
    FOREIGN KEY ("TARGET_VERTEX_ID") REFERENCES "FINSIGHT_GRAPH"."VERTEX" ("VERTEX_ID")
);

-- Edge type reference
CREATE COLUMN TABLE "FINSIGHT_GRAPH"."EDGE_TYPE" (
    "EDGE_TYPE" NVARCHAR(50) NOT NULL,
    "DESCRIPTION" NVARCHAR(255),
    "INVERSE_TYPE" NVARCHAR(50),
    PRIMARY KEY ("EDGE_TYPE")
);

-- ============================================================================
-- STEP 7: PAL_STORE SCHEMA TABLES (LangChain Vector Store)
-- ============================================================================

-- Main embeddings table (LangChain compatible)
CREATE COLUMN TABLE "PAL_STORE"."EMBEDDINGS" (
    "ID" NVARCHAR(64) NOT NULL,
    "COLLECTION_ID" NVARCHAR(64),
    "CONTENT" NCLOB NOT NULL,
    "EMBEDDING" REAL_VECTOR(1536),
    "METADATA" NCLOB,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("ID")
);

-- Document metadata
CREATE COLUMN TABLE "PAL_STORE"."DOCUMENTS" (
    "DOC_ID" NVARCHAR(64) NOT NULL,
    "COLLECTION_ID" NVARCHAR(64),
    "TITLE" NVARCHAR(500),
    "SOURCE" NVARCHAR(500),
    "SOURCE_TYPE" NVARCHAR(50),
    "CONTENT_HASH" NVARCHAR(64),
    "CHUNK_COUNT" INTEGER,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP,
    PRIMARY KEY ("DOC_ID")
);

-- Embedding collections
CREATE COLUMN TABLE "PAL_STORE"."COLLECTIONS" (
    "COLLECTION_ID" NVARCHAR(64) NOT NULL,
    "NAME" NVARCHAR(255) NOT NULL,
    "DESCRIPTION" NVARCHAR(500),
    "EMBEDDING_MODEL" NVARCHAR(100),
    "DIMENSIONS" INTEGER DEFAULT 1536,
    "DISTANCE_METRIC" NVARCHAR(20) DEFAULT 'COSINE',
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("COLLECTION_ID")
);

-- ============================================================================
-- STEP 8: CREATE VECTOR INDEXES
-- ============================================================================

-- Vector index for FINSIGHT_RAG embeddings
CREATE VECTOR INDEX "FINSIGHT_RAG"."VI_EMBEDDINGS" 
ON "FINSIGHT_RAG"."EMBEDDINGS" ("EMBEDDING_VECTOR")
USING HNSW
WITH PARAMETERS ('M' = 16, 'EF_CONSTRUCTION' = 200);

-- Vector index for PAL_STORE embeddings
CREATE VECTOR INDEX "PAL_STORE"."VI_EMBEDDINGS" 
ON "PAL_STORE"."EMBEDDINGS" ("EMBEDDING")
USING HNSW
WITH PARAMETERS ('M' = 16, 'EF_CONSTRUCTION' = 200);

-- ============================================================================
-- STEP 9: CREATE FULL-TEXT SEARCH INDEXES
-- ============================================================================

-- Full-text search on entity fields
CREATE FULLTEXT INDEX "ODATA_VOCAB"."FTI_ENTITY_FIELDS" 
ON "ODATA_VOCAB"."ENTITY_FIELDS" ("FIELD_NAME", "DESCRIPTION")
ASYNC;

-- ============================================================================
-- STEP 10: INSERT REFERENCE DATA
-- ============================================================================

-- Insert standard edge types
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('SOURCE_OF', 'File is source of table', 'SOURCED_FROM');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('CONTAINS', 'Table contains field', 'BELONGS_TO');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('REFERENCES', 'Field references another field', 'REFERENCED_BY');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('TRANSFORMS_TO', 'Source transforms to target', 'TRANSFORMED_FROM');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('VALIDATES', 'Rule validates record', 'VALIDATED_BY');

-- Insert default embedding collection
INSERT INTO "PAL_STORE"."COLLECTIONS" VALUES (
    'default', 
    'Default Collection', 
    'Default embedding collection for LangChain integration',
    'text-embedding-ada-002',
    1536,
    'COSINE',
    CURRENT_TIMESTAMP
);

-- ============================================================================
-- STEP 11: INSERT ODATA VOCABULARY TERMS
-- ============================================================================

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

-- UI vocabulary terms
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('UI', 'LineItem', 'Term', 'EntityType', 'DataField[]', 'Collection of fields for list display');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('UI', 'FieldGroup', 'Term', 'EntityType', 'FieldGroupType', 'Group of fields');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('UI', 'SelectionFields', 'Term', 'EntityType', 'PropertyPath[]', 'Properties for filter bar');
INSERT INTO "ODATA_VOCAB"."VOCABULARY_TERMS" VALUES ('UI', 'HeaderInfo', 'Term', 'EntityType', 'HeaderInfoType', 'Header display information');

-- ============================================================================
-- STEP 12: INSERT S/4HANA FINANCE FIELD DEFINITIONS (I_JournalEntryItem/ACDOCA)
-- ============================================================================

-- Key Fields
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'CompanyCode', 'BUKRS', 'dimension', 'CompanyCode', 
    'CHAR(4)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable, @Common.SemanticKey',
    'Company Code', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'FiscalYear', 'GJAHR', 'dimension', 'FiscalYear', 
    'NUMC(4)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable, @Common.SemanticKey',
    'Fiscal Year', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AccountingDocument', 'BELNR', 'key', 'AccountingDocument', 
    'CHAR(10)', 'Common', '@Common.SemanticKey',
    'Accounting Document Number', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'LedgerGLLineItem', 'DOCLN', 'key', 'LedgerGLLineItem', 
    'NUMC(6)', 'Common', '@Common.SemanticKey',
    'Line Item Number', 'FI', TRUE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'Ledger', 'RLDNR', 'dimension', 'Ledger', 
    'CHAR(2)', 'Analytics', '@Analytics.dimension, @Common.SemanticKey',
    'Ledger', 'FI', TRUE, NULL
);

-- Dimension Fields
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'GLAccount', 'HKONT', 'dimension', 'GLAccount', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'General Ledger Account', 'FI-GL', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'CostCenter', 'KOSTL', 'dimension', 'CostCenter', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Cost Center', 'CO', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'ProfitCenter', 'PRCTR', 'dimension', 'ProfitCenter', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Profit Center', 'CO', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'PostingDate', 'BUDAT', 'dimension', 'PostingDate', 
    'DATS', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Posting Date in the Document', 'FI', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'FiscalPeriod', 'POPER', 'dimension', 'FiscalPeriod', 
    'NUMC(3)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Fiscal Period', 'FI', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'Segment', 'SEGMENT', 'dimension', 'Segment', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Segment', 'CO', FALSE, NULL
);

-- Measure Fields
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AmountInCompanyCodeCurrency', 'HSL', 'measure', 
    'AmountInCompanyCodeCurrency', 'CURR(23,2)', 'Analytics', 
    '@Analytics.measure, @Aggregation.aggregatable, @Semantics.amount.currencyCode: CompanyCodeCurrency',
    'Amount in Company Code Currency', 'FI', FALSE, 'CompanyCodeCurrency'
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AmountInTransactionCurrency', 'WSL', 'measure', 
    'AmountInTransactionCurrency', 'CURR(23,2)', 'Analytics', 
    '@Analytics.measure, @Aggregation.aggregatable, @Semantics.amount.currencyCode: TransactionCurrency',
    'Amount in Transaction Currency', 'FI', FALSE, 'TransactionCurrency'
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'AmountInGlobalCurrency', 'KSL', 'measure', 
    'AmountInGlobalCurrency', 'CURR(23,2)', 'Analytics', 
    '@Analytics.measure, @Aggregation.aggregatable, @Semantics.amount.currencyCode: GlobalCurrency',
    'Amount in Global Currency', 'FI', FALSE, 'GlobalCurrency'
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'DebitCreditCode', 'DRCRK', 'dimension', 
    'DebitCreditCode', 'CHAR(1)', 'Analytics', '@Analytics.dimension',
    'Debit/Credit Indicator', 'FI', FALSE, NULL
);

-- Currency Fields
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'CompanyCodeCurrency', 'RHCUR', 'currency', 
    'CompanyCodeCurrency', 'CUKY(5)', 'Semantics', '@Semantics.currencyCode',
    'Currency Key for Company Code Currency', 'FI', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'TransactionCurrency', 'RWCUR', 'currency', 
    'TransactionCurrency', 'CUKY(5)', 'Semantics', '@Semantics.currencyCode',
    'Transaction Currency', 'FI', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'GlobalCurrency', 'RKCUR', 'currency', 
    'GlobalCurrency', 'CUKY(5)', 'Semantics', '@Semantics.currencyCode',
    'Global Currency', 'FI', FALSE, NULL
);

-- Subledger Fields
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'Customer', 'KUNNR', 'subledger', 'Customer', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Customer Number (Accounts Receivable)', 'FI-AR', FALSE, NULL
);
INSERT INTO "ODATA_VOCAB"."ENTITY_FIELDS" VALUES (
    'I_JournalEntryItem', 'Supplier', 'LIFNR', 'subledger', 'Supplier', 
    'CHAR(10)', 'Analytics', '@Analytics.dimension, @Aggregation.groupable',
    'Supplier Number (Accounts Payable)', 'FI-AP', FALSE, NULL
);

-- ============================================================================
-- STEP 13: INSERT FIELD ALIASES
-- ============================================================================

-- CompanyCode aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUKRS', 'bukrs');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUKRS', 'companycode');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUKRS', 'company_code');

-- FiscalYear aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'GJAHR', 'gjahr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'GJAHR', 'fiscalyear');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'GJAHR', 'fiscal_year');

-- AccountingDocument aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BELNR', 'belnr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BELNR', 'accountingdocument');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BELNR', 'document_number');

-- GLAccount aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'hkont');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'racct');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'glaccount');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HKONT', 'gl_account');

-- CostCenter aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'kostl');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'rcntr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'costcenter');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KOSTL', 'cost_center');

-- ProfitCenter aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'PRCTR', 'prctr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'PRCTR', 'profitcenter');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'PRCTR', 'profit_center');

-- Amount aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'hsl');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'amountincompanycodecurrency');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'amount_lc');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'HSL', 'localamount');

INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'WSL', 'wsl');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'WSL', 'amountintransactioncurrency');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'WSL', 'amount_tc');

-- Currency aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'rhcur');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'companycodecurrency');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'waers');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'RHCUR', 'localcurrency');

-- PostingDate aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUDAT', 'budat');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUDAT', 'postingdate');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'BUDAT', 'posting_date');

-- Customer/Supplier aliases
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KUNNR', 'kunnr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'KUNNR', 'customer');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'LIFNR', 'lifnr');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'LIFNR', 'supplier');
INSERT INTO "ODATA_VOCAB"."FIELD_ALIASES" VALUES ('I_JournalEntryItem', 'LIFNR', 'vendor');

-- ============================================================================
-- STEP 14: CREATE VIEWS
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

-- Currency fields view
CREATE OR REPLACE VIEW "ODATA_VOCAB"."V_CURRENCY_FIELDS" AS
SELECT * FROM "ODATA_VOCAB"."ENTITY_FIELDS" WHERE "CATEGORY" = 'currency';

-- ============================================================================
-- STEP 15: GRANT PERMISSIONS (Uncomment and customize)
-- ============================================================================

-- Replace <SERVICE_USER> with your actual service user name
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "ODATA_VOCAB" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_CORE" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_RAG" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_GOV" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_GRAPH" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "PAL_STORE" TO <SERVICE_USER>;

-- ============================================================================
-- DEPLOYMENT COMPLETE
-- ============================================================================
-- 
-- Tables Created:
-- ----------------
-- ODATA_VOCAB.VOCABULARY_TERMS
-- ODATA_VOCAB.ENTITY_FIELDS  
-- ODATA_VOCAB.FIELD_ALIASES
-- FINSIGHT_CORE.RECORDS
-- FINSIGHT_CORE.FIELDS
-- FINSIGHT_CORE.SOURCE_FILES
-- FINSIGHT_RAG.CHUNKS
-- FINSIGHT_RAG.EMBEDDINGS
-- FINSIGHT_RAG.EMBEDDING_MANIFEST
-- FINSIGHT_GOV.QUALITY_ISSUES
-- FINSIGHT_GOV.QUALITY_REPORTS
-- FINSIGHT_GOV.TABLE_PROFILE
-- FINSIGHT_GOV.ODPS_VALIDATION
-- FINSIGHT_GRAPH.VERTEX
-- FINSIGHT_GRAPH.EDGE
-- FINSIGHT_GRAPH.EDGE_TYPE
-- PAL_STORE.EMBEDDINGS
-- PAL_STORE.DOCUMENTS
-- PAL_STORE.COLLECTIONS
--
-- Views Created:
-- ---------------
-- ODATA_VOCAB.V_DIMENSION_FIELDS
-- ODATA_VOCAB.V_MEASURE_FIELDS
-- ODATA_VOCAB.V_KEY_FIELDS
-- ODATA_VOCAB.V_SUBLEDGER_FIELDS
-- ODATA_VOCAB.V_CURRENCY_FIELDS
--
-- ============================================================================