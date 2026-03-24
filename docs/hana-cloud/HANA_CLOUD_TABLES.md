# SAP HANA Cloud Tables for OData Vocabularies & AI Training

This document provides the complete list of tables required in SAP HANA Cloud for the OData Vocabularies integration and AI training pipeline.

## Overview

The tables are organized into the following schemas:

| Schema | Purpose |
|--------|---------|
| `ODATA_VOCAB` | OData vocabulary terms, field classification, and S/4HANA metadata |
| `FINSIGHT_CORE` | Machine-readable onboarding master model |
| `FINSIGHT_RAG` | RAG chunks, embeddings, and retrieval layer |
| `FINSIGHT_GOV` | Quality metrics and governance evidence |
| `FINSIGHT_GRAPH` | Lineage and semantic graph relationships |
| `PAL_STORE` | LangChain HANA Cloud vector store for AI embeddings |

---

## Quick Start

```sql
-- Run all DDL scripts in order:
-- 1. Create schemas
-- 2. Create ODATA_VOCAB tables
-- 3. Create FINSIGHT tables
-- 4. Create PAL_STORE tables
```

---

## Schema 1: ODATA_VOCAB (OData Vocabularies)

### Table Summary

| Table | Description | Primary Key |
|-------|-------------|-------------|
| `VOCABULARY_TERMS` | OData vocabulary terms (Analytics, Common, etc.) | VOCABULARY, TERM |
| `ENTITY_FIELDS` | S/4HANA Finance field definitions | ENTITY, TECHNICAL_NAME |
| `FIELD_ALIASES` | Alternative names for field matching | ENTITY, TECHNICAL_NAME, ALIAS |

### DDL Script

```sql
-- ============================================================================
-- Schema: ODATA_VOCAB - OData Vocabulary Classification
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "ODATA_VOCAB";

-- Vocabulary Terms from OData specs
CREATE COLUMN TABLE "ODATA_VOCAB"."VOCABULARY_TERMS" (
    "VOCABULARY" NVARCHAR(50) NOT NULL,
    "TERM" NVARCHAR(100) NOT NULL,
    "TERM_TYPE" NVARCHAR(50),
    "APPLIES_TO" NVARCHAR(200),
    "BASE_TYPE" NVARCHAR(100),
    "DESCRIPTION" NVARCHAR(500),
    PRIMARY KEY ("VOCABULARY", "TERM")
);

-- Entity field definitions with OData annotations
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

-- Create full-text search index
CREATE FULLTEXT INDEX "ODATA_VOCAB"."FTI_ENTITY_FIELDS" 
ON "ODATA_VOCAB"."ENTITY_FIELDS" ("FIELD_NAME", "DESCRIPTION")
ASYNC;
```

---

## Schema 2: FINSIGHT_CORE (Core Data Model)

### Table Summary

| Table | Description | Primary Key |
|-------|-------------|-------------|
| `RECORDS` | One row per source record | RECORD_ID |
| `FIELDS` | EAV projection of normalized fields | RECORD_ID, FIELD_NAME |
| `SOURCE_FILES` | Source file inventory | SOURCE_FILE |

### DDL Script

```sql
-- ============================================================================
-- Schema: FINSIGHT_CORE - Machine-Readable Onboarding Model
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "FINSIGHT_CORE";

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
```

---

## Schema 3: FINSIGHT_RAG (RAG & Embeddings)

### Table Summary

| Table | Description | Primary Key |
|-------|-------------|-------------|
| `CHUNKS` | RAG chunks aligned to records | CHUNK_ID |
| `EMBEDDINGS` | Embedding vectors and metadata | EMBEDDING_ID |
| `EMBEDDING_MANIFEST` | Embedding generation metadata | RUN_ID |

### DDL Script

```sql
-- ============================================================================
-- Schema: FINSIGHT_RAG - Retrieval Augmented Generation Layer
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "FINSIGHT_RAG";

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

-- Create vector index for similarity search
CREATE VECTOR INDEX "FINSIGHT_RAG"."VI_EMBEDDINGS" 
ON "FINSIGHT_RAG"."EMBEDDINGS" ("EMBEDDING_VECTOR")
USING HNSW
WITH PARAMETERS ('M' = 16, 'EF_CONSTRUCTION' = 200);
```

---

## Schema 4: FINSIGHT_GOV (Governance & Quality)

### Table Summary

| Table | Description | Primary Key |
|-------|-------------|-------------|
| `QUALITY_ISSUES` | Row-level quality issues | RECORD_ID, ISSUE_TYPE, FIELD, SOURCE_ROW_NUMBER |
| `QUALITY_REPORTS` | Run-level quality reports | REPORT_ID |
| `TABLE_PROFILE` | Table completeness metrics | TABLE_NAME, REPORT_ID |
| `ODPS_VALIDATION` | ODPS schema validation | VALIDATION_RUN_ID |

### DDL Script

```sql
-- ============================================================================
-- Schema: FINSIGHT_GOV - Quality & Governance
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "FINSIGHT_GOV";

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
```

---

## Schema 5: FINSIGHT_GRAPH (Lineage Graph)

### Table Summary

| Table | Description | Primary Key |
|-------|-------------|-------------|
| `VERTEX` | Graph nodes (sources, tables, fields, etc.) | VERTEX_ID |
| `EDGE` | Graph relationships | EDGE_ID |
| `EDGE_TYPE` | Reference catalog of relationship types | EDGE_TYPE |

### DDL Script

```sql
-- ============================================================================
-- Schema: FINSIGHT_GRAPH - Lineage & Semantic Graph
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "FINSIGHT_GRAPH";

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

-- Insert standard edge types
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('SOURCE_OF', 'File is source of table', 'SOURCED_FROM');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('CONTAINS', 'Table contains field', 'BELONGS_TO');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('REFERENCES', 'Field references another field', 'REFERENCED_BY');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('TRANSFORMS_TO', 'Source transforms to target', 'TRANSFORMED_FROM');
INSERT INTO "FINSIGHT_GRAPH"."EDGE_TYPE" VALUES ('VALIDATES', 'Rule validates record', 'VALIDATED_BY');
```

---

## Schema 6: PAL_STORE (LangChain HANA Vector Store)

### Table Summary

| Table | Description | Primary Key |
|-------|-------------|-------------|
| `EMBEDDINGS` | LangChain vector embeddings | ID |
| `DOCUMENTS` | Source document metadata | DOC_ID |
| `COLLECTIONS` | Embedding collections | COLLECTION_ID |

### DDL Script

```sql
-- ============================================================================
-- Schema: PAL_STORE - LangChain HANA Cloud Vector Store
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "PAL_STORE";

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

-- Create vector index for similarity search
CREATE VECTOR INDEX "PAL_STORE"."VI_EMBEDDINGS" 
ON "PAL_STORE"."EMBEDDINGS" ("EMBEDDING")
USING HNSW
WITH PARAMETERS ('M' = 16, 'EF_CONSTRUCTION' = 200);

-- Insert default collection
INSERT INTO "PAL_STORE"."COLLECTIONS" VALUES (
    'default', 
    'Default Collection', 
    'Default embedding collection for LangChain integration',
    'text-embedding-ada-002',
    1536,
    'COSINE',
    CURRENT_TIMESTAMP
);
```

---

## Complete DDL Script

Save this as `deploy_all_tables.sql` and run in HANA Cloud:

```sql
-- ============================================================================
-- SAP HANA Cloud - Complete Table Deployment Script
-- Run this script to create all required tables for AI Fabric
-- ============================================================================

-- Create all schemas
CREATE SCHEMA IF NOT EXISTS "ODATA_VOCAB";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_CORE";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_RAG";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_GOV";
CREATE SCHEMA IF NOT EXISTS "FINSIGHT_GRAPH";
CREATE SCHEMA IF NOT EXISTS "PAL_STORE";

-- Run individual schema DDLs from sections above...
-- (Copy each CREATE TABLE statement from the sections above)

-- Grant permissions (update <SERVICE_USER> with actual user)
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "ODATA_VOCAB" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_CORE" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_RAG" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_GOV" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_GRAPH" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "PAL_STORE" TO <SERVICE_USER>;
```

---

## Table Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           HANA Cloud Schemas                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ODATA_VOCAB                    FINSIGHT_CORE                               │
│  ┌────────────────────┐         ┌────────────────────┐                      │
│  │ VOCABULARY_TERMS   │         │ RECORDS            │◄──────┐              │
│  │ ENTITY_FIELDS      │         │ FIELDS             │───────┤              │
│  │ FIELD_ALIASES      │         │ SOURCE_FILES       │       │              │
│  └────────────────────┘         └────────────────────┘       │              │
│                                                               │              │
│  FINSIGHT_RAG                   FINSIGHT_GOV                 │              │
│  ┌────────────────────┐         ┌────────────────────┐       │              │
│  │ CHUNKS             │◄────────│ QUALITY_ISSUES     │───────┘              │
│  │ EMBEDDINGS         │         │ QUALITY_REPORTS    │                      │
│  │ EMBEDDING_MANIFEST │         │ TABLE_PROFILE      │                      │
│  └────────────────────┘         │ ODPS_VALIDATION    │                      │
│                                 └────────────────────┘                      │
│                                                                              │
│  FINSIGHT_GRAPH                 PAL_STORE                                   │
│  ┌────────────────────┐         ┌────────────────────┐                      │
│  │ VERTEX             │         │ EMBEDDINGS         │◄── LangChain         │
│  │ EDGE               │         │ DOCUMENTS          │                      │
│  │ EDGE_TYPE          │         │ COLLECTIONS        │                      │
│  └────────────────────┘         └────────────────────┘                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Environment Configuration

Set these in your `.env` file:

```bash
# HANA Cloud Connection
HANA_HOST=your-hana-instance.hanacloud.ondemand.com
HANA_PORT=443
HANA_USER=your-hana-user
HANA_PASSWORD=your-hana-password
HANA_SCHEMA=PAL_STORE  # Default schema for LangChain

# Vector Configuration
EMBEDDING_DIMENSIONS=1536
EMBEDDING_MODEL=text-embedding-ada-002
```

---

## Notes

1. **Vector Index**: HANA Cloud's vector index (HNSW) is used for efficient similarity search
2. **REAL_VECTOR**: Uses HANA's native vector type for embeddings (1536 dimensions for OpenAI ada-002)
3. **NCLOB**: Used for large text fields (chunks, metadata JSON)
4. **Full-Text Search**: Enabled on ENTITY_FIELDS for fuzzy field matching