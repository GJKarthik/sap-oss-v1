-- ============================================================================
-- BTP schema registry DDL extracted from hana-btp.ts and hana_client.py
-- Reconstructs the registry table plus the wide-table catalogue used in code.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "BTP";

-- Core metadata table queried by the BTP registry helpers.
-- Column lengths/types are reconstructed from the registry interface and
-- corroborated by the BTP schema emitter helpers in the source tree.
CREATE COLUMN TABLE "BTP"."SCHEMA_REGISTRY" (
    "REGISTRY_ID" NVARCHAR(64) NOT NULL,
    "DOMAIN" NVARCHAR(64) NOT NULL,
    "SOURCE_TABLE" NVARCHAR(256) NOT NULL,
    "FIELD_NAME" NVARCHAR(256) NOT NULL,
    "HANA_TYPE" NVARCHAR(64),
    "DESCRIPTION" NCLOB,
    "WIDE_TABLE" NVARCHAR(64),
    PRIMARY KEY ("REGISTRY_ID")
);

-- Lookup table for the consolidated BTP wide-table names referenced by the
-- HANA client, registry utilities, and static catalogue seeders.
CREATE COLUMN TABLE "BTP"."WIDE_TABLE_CATALOGUE" (
    "WIDE_TABLE" NVARCHAR(64) NOT NULL,
    "TABLE_KIND" NVARCHAR(16) NOT NULL,
    "DEFAULT_DOMAIN" NVARCHAR(64),
    "TABLE_NAME" NVARCHAR(256) NOT NULL,
    "DESCRIPTION" NVARCHAR(500),
    PRIMARY KEY ("WIDE_TABLE")
);

-- Seed the well-known consolidated BTP table catalogue.
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('FACT', 'WIDE', 'STAGING', 'BTP.FACT', 'Transactional and measurable rows used for staging, GLA, analytics, and time-series PAL workloads');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('RECON', 'WIDE', 'RECON', 'BTP.RECON', 'Reconciliation and control rows');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('ESG_METRIC', 'WIDE', 'ESG', 'BTP.ESG_METRIC', 'ESG and sustainability metrics');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('TREASURY_POSITION', 'WIDE', 'TREASURY', 'BTP.TREASURY_POSITION', 'Treasury positions and valuations');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('CLIENT_MI', 'WIDE', 'CLIENT', 'BTP.CLIENT_MI', 'Client management information');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_ENTITY', 'DIM', 'STAGING', 'BTP.DIM_ENTITY', 'Entity, counterparty, and client master data');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_PRODUCT', 'DIM', 'STAGING', 'BTP.DIM_PRODUCT', 'Product hierarchy data');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_LOCATION', 'DIM', 'STAGING', 'BTP.DIM_LOCATION', 'Geography and location hierarchy data');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_ACCOUNT', 'DIM', 'PERFORMANCE', 'BTP.DIM_ACCOUNT', 'Chart of accounts hierarchy');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_COST_CLUSTER', 'DIM', 'PERFORMANCE', 'BTP.DIM_COST_CLUSTER', 'Cost-cluster hierarchy');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_TIME', 'DIM', 'STAGING', 'BTP.DIM_TIME', 'Date, period, and COB calendar data');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('TERM_MAPPING', 'LOOKUP', 'STAGING', 'BTP.TERM_MAPPING', 'Technical-to-business term glossary');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('DIM_DEFINITION', 'LOOKUP', 'STAGING', 'BTP.DIM_DEFINITION', 'Narrative attribute definitions');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('FILTER_VALUE', 'LOOKUP', 'STAGING', 'BTP.FILTER_VALUE', 'Filter-dimension lookup values');
INSERT INTO "BTP"."WIDE_TABLE_CATALOGUE" VALUES
    ('SCHEMA_REGISTRY', 'META', 'STAGING', 'BTP.SCHEMA_REGISTRY', 'Metadata catalogue of every source table and field');