-- =============================================================================
-- SAP HANA Cloud - Text-to-SQL Drift Detection Tables
-- DDL Script for TTS Drift Telemetry (Chapter 18 of Simula Spec)
-- =============================================================================
-- 
-- This script creates tables in the FINSIGHT_GOV schema for storing
-- Text-to-SQL drift metrics, alerts, baselines, and telemetry data.
--
-- Prerequisites:
--   - FINSIGHT_GOV schema must exist (see HANA_CLOUD_TABLES.md)
--   - User must have CREATE TABLE privileges on FINSIGHT_GOV
--
-- Usage:
--   Run this script after the main FINSIGHT_GOV schema is created
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: TTS_DRIFT_METRICS
-- Purpose: Store historical drift metric measurements
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_DRIFT_METRICS" (
    "METRIC_ID" NVARCHAR(64) NOT NULL,
    "REPORT_ID" NVARCHAR(64) NOT NULL,
    "TIMESTAMP" TIMESTAMP NOT NULL,
    "METRIC_CODE" NVARCHAR(20) NOT NULL,
    "METRIC_NAME" NVARCHAR(100),
    "VALUE" DECIMAL(10,6),
    "THRESHOLD" DECIMAL(10,6),
    "CONFIDENCE_BOUND" DECIMAL(10,6),
    "DIRECTION" NVARCHAR(20),
    "PASSED" BOOLEAN,
    "BASELINE_VALUE" DECIMAL(10,6),
    "DELTA" DECIMAL(10,6),
    "DELTA_PERCENT" DECIMAL(10,4),
    "USER_SEGMENT" NVARCHAR(50),
    "BATCH_ID" NVARCHAR(64),
    "EVALUATION_CONTEXT" NVARCHAR(20),
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("METRIC_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_DRIFT_METRICS" IS 
    'Text-to-SQL drift metric measurements (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_METRICS"."METRIC_CODE" IS 
    'Metric identifier: TTS-M01 to TTS-M12';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_METRICS"."DIRECTION" IS 
    'Optimization direction: higher_better or lower_better';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_METRICS"."EVALUATION_CONTEXT" IS 
    'Context: training, ci_cd, production, adhoc';

-- Create index for time-series queries
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_METRICS_TIME" 
ON "FINSIGHT_GOV"."TTS_DRIFT_METRICS" ("TIMESTAMP", "METRIC_CODE");

-- Create index for report queries
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_METRICS_REPORT" 
ON "FINSIGHT_GOV"."TTS_DRIFT_METRICS" ("REPORT_ID");

-- -----------------------------------------------------------------------------
-- Table: TTS_DRIFT_REPORTS
-- Purpose: Store complete drift metric reports
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_DRIFT_REPORTS" (
    "REPORT_ID" NVARCHAR(64) NOT NULL,
    "EVALUATED_AT" TIMESTAMP NOT NULL,
    "SAMPLE_SIZE" INTEGER NOT NULL,
    "CONFIDENCE_LEVEL" DECIMAL(4,3) DEFAULT 0.95,
    "EVALUATION_CONTEXT" NVARCHAR(20),
    "BASELINE_ID" NVARCHAR(64),
    "TTS_EVAL" DECIMAL(6,2),
    "TTS_EVAL_STATUS" NVARCHAR(10),
    "SCHEMA_DRIFT_METRICS" NCLOB,
    "SEMANTIC_DRIFT_METRICS" NCLOB,
    "GENERATION_QUALITY_METRICS" NCLOB,
    "USER_SEGMENT_BREAKDOWN" NCLOB,
    "DRIFT_ALERT_COUNT" INTEGER DEFAULT 0,
    "CREATED_BY" NVARCHAR(100),
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("REPORT_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_DRIFT_REPORTS" IS 
    'Complete TTS drift metric reports (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_REPORTS"."TTS_EVAL_STATUS" IS 
    'Traffic-light status: GREEN, AMBER, RED';

-- Create index for time-series queries
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_REPORTS_TIME" 
ON "FINSIGHT_GOV"."TTS_DRIFT_REPORTS" ("EVALUATED_AT");

-- -----------------------------------------------------------------------------
-- Table: TTS_DRIFT_ALERTS
-- Purpose: Store drift alerts with lifecycle tracking
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_DRIFT_ALERTS" (
    "ALERT_ID" NVARCHAR(64) NOT NULL,
    "SEVERITY" NVARCHAR(20) NOT NULL,
    "DRIFT_TYPE" NVARCHAR(20) NOT NULL,
    "DRIFT_TYPE_NAME" NVARCHAR(50),
    "METRIC_CODE" NVARCHAR(20) NOT NULL,
    "METRIC_NAME" NVARCHAR(100),
    "CURRENT_VALUE" DECIMAL(10,6),
    "THRESHOLD" DECIMAL(10,6),
    "BASELINE_VALUE" DECIMAL(10,6),
    "DELTA" DECIMAL(10,6),
    "DELTA_PERCENT" DECIMAL(10,4),
    "TIMESTAMP" TIMESTAMP NOT NULL,
    "USER_SEGMENT" NVARCHAR(50),
    "SAMPLE_QUERIES" NCLOB,
    "RECOMMENDED_ACTION" NVARCHAR(500),
    "ACTION_TIMELINE" NVARCHAR(50),
    "TTS_EVAL_IMPACT" DECIMAL(6,2),
    "RELATED_SCHEMA_CHANGES" NCLOB,
    "ACKNOWLEDGED" BOOLEAN DEFAULT FALSE,
    "ACKNOWLEDGED_BY" NVARCHAR(100),
    "ACKNOWLEDGED_AT" TIMESTAMP,
    "RESOLVED" BOOLEAN DEFAULT FALSE,
    "RESOLVED_BY" NVARCHAR(100),
    "RESOLVED_AT" TIMESTAMP,
    "RESOLUTION_NOTES" NVARCHAR(1000),
    "TRACKING_ISSUE" NVARCHAR(500),
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("ALERT_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_DRIFT_ALERTS" IS 
    'Text-to-SQL drift alerts with lifecycle tracking (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_ALERTS"."DRIFT_TYPE" IS 
    'Drift type: TTS-DRIFT-001 to TTS-DRIFT-006';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_ALERTS"."SEVERITY" IS 
    'Alert severity: LOW, MEDIUM, HIGH, CRITICAL';

-- Create index for open alerts
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_ALERTS_OPEN" 
ON "FINSIGHT_GOV"."TTS_DRIFT_ALERTS" ("RESOLVED", "SEVERITY", "TIMESTAMP");

-- Create index for alert queries by type
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_ALERTS_TYPE" 
ON "FINSIGHT_GOV"."TTS_DRIFT_ALERTS" ("DRIFT_TYPE", "METRIC_CODE");

-- -----------------------------------------------------------------------------
-- Table: TTS_DRIFT_BASELINES
-- Purpose: Store drift baselines for comparison
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_DRIFT_BASELINES" (
    "BASELINE_ID" NVARCHAR(64) NOT NULL,
    "BASELINE_VERSION" NVARCHAR(20),
    "CREATED_AT" TIMESTAMP NOT NULL,
    "CREATED_BY" NVARCHAR(100),
    "DESCRIPTION" NVARCHAR(500),
    "SCHEMA_SNAPSHOT" NCLOB,
    "METRIC_BASELINES" NCLOB NOT NULL,
    "TRAINING_DATA_VERSION" NVARCHAR(100) NOT NULL,
    "TRAINING_DATA_STATS" NCLOB,
    "MODEL_VERSION" NVARCHAR(100),
    "COMPLEXITY_DISTRIBUTION" NCLOB,
    "TAXONOMY_COVERAGE" NCLOB,
    "VOCABULARY_SNAPSHOT" NCLOB,
    "THRESHOLDS" NCLOB,
    "IS_ACTIVE" BOOLEAN DEFAULT TRUE,
    "SUPERSEDED_BY" NVARCHAR(64),
    "SUPERSEDED_AT" TIMESTAMP,
    "APPROVAL_STATUS" NVARCHAR(20) DEFAULT 'draft',
    "APPROVED_BY" NVARCHAR(100),
    "APPROVED_AT" TIMESTAMP,
    PRIMARY KEY ("BASELINE_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_DRIFT_BASELINES" IS 
    'Text-to-SQL drift baselines for comparison (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_DRIFT_BASELINES"."APPROVAL_STATUS" IS 
    'Status: draft, pending_review, approved, rejected, deprecated';

-- Create index for active baseline lookup
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_BASELINES_ACTIVE" 
ON "FINSIGHT_GOV"."TTS_DRIFT_BASELINES" ("IS_ACTIVE", "APPROVAL_STATUS");

-- -----------------------------------------------------------------------------
-- Table: TTS_SCHEMA_SNAPSHOTS
-- Purpose: Track HANA schema changes for staleness calculation
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS" (
    "SNAPSHOT_ID" NVARCHAR(64) NOT NULL,
    "SCHEMA_NAME" NVARCHAR(100) NOT NULL,
    "TABLE_NAME" NVARCHAR(100) NOT NULL,
    "COLUMN_HASH" NVARCHAR(64) NOT NULL,
    "COLUMN_COUNT" INTEGER,
    "SNAPSHOT_AT" TIMESTAMP NOT NULL,
    "TRAINING_SYNC_AT" TIMESTAMP,
    "DAYS_SINCE_SYNC" INTEGER GENERATED ALWAYS AS (
        DAYS_BETWEEN("TRAINING_SYNC_AT", CURRENT_TIMESTAMP)
    ),
    "SCHEMA_DETAILS" NCLOB,
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("SNAPSHOT_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS" IS 
    'HANA schema snapshots for staleness tracking (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS"."COLUMN_HASH" IS 
    'SHA-256 hash of column definitions for change detection';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS"."TRAINING_SYNC_AT" IS 
    'Timestamp when training data was last synced with this schema version';

-- Create index for schema change detection
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_SNAPSHOTS_SCHEMA" 
ON "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS" ("SCHEMA_NAME", "TABLE_NAME", "SNAPSHOT_AT");

-- -----------------------------------------------------------------------------
-- Table: TTS_SCHEMA_CHANGES
-- Purpose: Track individual schema changes for drift analysis
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES" (
    "CHANGE_ID" NVARCHAR(64) NOT NULL,
    "CHANGE_TYPE" NVARCHAR(30) NOT NULL,
    "SCHEMA_NAME" NVARCHAR(100) NOT NULL,
    "TABLE_NAME" NVARCHAR(100) NOT NULL,
    "COLUMN_NAME" NVARCHAR(100),
    "OLD_VALUE" NVARCHAR(500),
    "NEW_VALUE" NVARCHAR(500),
    "CHANGE_WEIGHT" DECIMAL(3,2) NOT NULL,
    "CHANGED_AT" TIMESTAMP NOT NULL,
    "DETECTED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "TRAINING_SYNCED" BOOLEAN DEFAULT FALSE,
    "TRAINING_SYNCED_AT" TIMESTAMP,
    "ALERT_ID" NVARCHAR(64),
    PRIMARY KEY ("CHANGE_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES" IS 
    'Individual schema changes for drift analysis (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES"."CHANGE_TYPE" IS 
    'Type: column_added, column_dropped, column_renamed, type_changed, table_added, table_dropped';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES"."CHANGE_WEIGHT" IS 
    'Importance weight for SSS calculation: 1.0 drop, 0.5 type, 0.3 rename';

-- Create index for unsynced changes
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_CHANGES_UNSYNCED" 
ON "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES" ("TRAINING_SYNCED", "CHANGED_AT");

-- -----------------------------------------------------------------------------
-- Table: TTS_QUERY_SAMPLES
-- Purpose: Store sampled queries for drift analysis
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" (
    "QUERY_ID" NVARCHAR(64) NOT NULL,
    "PROMPT" NCLOB NOT NULL,
    "GENERATED_SQL" NCLOB NOT NULL,
    "EXECUTION_SUCCESS" BOOLEAN,
    "ERROR_MESSAGE" NVARCHAR(1000),
    "EXECUTION_TIME_MS" INTEGER,
    "USER_ID" NVARCHAR(100),
    "USER_SEGMENT" NVARCHAR(50),
    "TIMESTAMP" TIMESTAMP NOT NULL,
    "COMPLEXITY_SCORE" DECIMAL(4,3),
    "SEMANTIC_ALIGNMENT" DECIMAL(4,3),
    "TABLES_REFERENCED" NVARCHAR(1000),
    "INCLUDED_IN_ALERT" BOOLEAN DEFAULT FALSE,
    "ALERT_ID" NVARCHAR(64),
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("QUERY_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" IS 
    'Sampled queries for drift analysis (Chapter 18)';

-- Create index for time-based queries
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_SAMPLES_TIME" 
ON "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" ("TIMESTAMP", "USER_SEGMENT");

-- Create index for failed queries
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_SAMPLES_FAILED" 
ON "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" ("EXECUTION_SUCCESS", "TIMESTAMP");

-- -----------------------------------------------------------------------------
-- Table: TTS_USER_SEGMENTS
-- Purpose: Track user segmentation for stratified sampling
-- -----------------------------------------------------------------------------

CREATE COLUMN TABLE "FINSIGHT_GOV"."TTS_USER_SEGMENTS" (
    "USER_ID" NVARCHAR(100) NOT NULL,
    "SEGMENT" NVARCHAR(50) NOT NULL,
    "FIRST_SEEN_AT" TIMESTAMP NOT NULL,
    "LAST_QUERY_AT" TIMESTAMP,
    "QUERY_COUNT_TOTAL" INTEGER DEFAULT 0,
    "QUERY_COUNT_TODAY" INTEGER DEFAULT 0,
    "QUERY_COUNT_7D" INTEGER DEFAULT 0,
    "AVG_DAILY_QUERIES" DECIMAL(8,2),
    "SAMPLE_RATE" DECIMAL(4,3),
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("USER_ID")
);

COMMENT ON TABLE "FINSIGHT_GOV"."TTS_USER_SEGMENTS" IS 
    'User segmentation for stratified drift sampling (Chapter 18)';

COMMENT ON COLUMN "FINSIGHT_GOV"."TTS_USER_SEGMENTS"."SEGMENT" IS 
    'Segment: power_user, regular_user, occasional_user, new_user';

-- Create index for segment queries
CREATE INDEX "FINSIGHT_GOV"."IDX_TTS_USERS_SEGMENT" 
ON "FINSIGHT_GOV"."TTS_USER_SEGMENTS" ("SEGMENT", "LAST_QUERY_AT");

-- -----------------------------------------------------------------------------
-- Views for Drift Monitoring Dashboard
-- -----------------------------------------------------------------------------

-- View: Current drift status summary
CREATE VIEW "FINSIGHT_GOV"."V_TTS_DRIFT_STATUS" AS
SELECT 
    r."REPORT_ID",
    r."EVALUATED_AT",
    r."TTS_EVAL",
    r."TTS_EVAL_STATUS",
    r."SAMPLE_SIZE",
    r."DRIFT_ALERT_COUNT",
    b."BASELINE_ID",
    b."TRAINING_DATA_VERSION",
    (SELECT COUNT(*) FROM "FINSIGHT_GOV"."TTS_DRIFT_ALERTS" a 
     WHERE a."RESOLVED" = FALSE AND a."SEVERITY" IN ('CRITICAL', 'HIGH')) AS "OPEN_CRITICAL_ALERTS"
FROM "FINSIGHT_GOV"."TTS_DRIFT_REPORTS" r
LEFT JOIN "FINSIGHT_GOV"."TTS_DRIFT_BASELINES" b 
    ON r."BASELINE_ID" = b."BASELINE_ID"
WHERE r."EVALUATED_AT" = (
    SELECT MAX("EVALUATED_AT") FROM "FINSIGHT_GOV"."TTS_DRIFT_REPORTS"
);

-- View: Schema staleness by table
CREATE VIEW "FINSIGHT_GOV"."V_TTS_SCHEMA_STALENESS" AS
SELECT 
    s."SCHEMA_NAME",
    s."TABLE_NAME",
    s."COLUMN_HASH",
    s."SNAPSHOT_AT",
    s."TRAINING_SYNC_AT",
    DAYS_BETWEEN(s."TRAINING_SYNC_AT", CURRENT_TIMESTAMP) AS "DAYS_STALE",
    (SELECT COUNT(*) FROM "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES" c 
     WHERE c."SCHEMA_NAME" = s."SCHEMA_NAME" 
       AND c."TABLE_NAME" = s."TABLE_NAME" 
       AND c."TRAINING_SYNCED" = FALSE) AS "UNSYNCED_CHANGES"
FROM "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS" s
WHERE s."SNAPSHOT_AT" = (
    SELECT MAX(s2."SNAPSHOT_AT") 
    FROM "FINSIGHT_GOV"."TTS_SCHEMA_SNAPSHOTS" s2 
    WHERE s2."SCHEMA_NAME" = s."SCHEMA_NAME" 
      AND s2."TABLE_NAME" = s."TABLE_NAME"
);

-- View: Metric trend over time
CREATE VIEW "FINSIGHT_GOV"."V_TTS_METRIC_TREND" AS
SELECT 
    DATE("TIMESTAMP") AS "DATE",
    "METRIC_CODE",
    "METRIC_NAME",
    AVG("VALUE") AS "AVG_VALUE",
    MIN("VALUE") AS "MIN_VALUE",
    MAX("VALUE") AS "MAX_VALUE",
    AVG("THRESHOLD") AS "THRESHOLD",
    SUM(CASE WHEN "PASSED" = TRUE THEN 1 ELSE 0 END) AS "PASS_COUNT",
    COUNT(*) AS "TOTAL_COUNT",
    CAST(SUM(CASE WHEN "PASSED" = TRUE THEN 1 ELSE 0 END) AS DECIMAL) / COUNT(*) AS "PASS_RATE"
FROM "FINSIGHT_GOV"."TTS_DRIFT_METRICS"
WHERE "TIMESTAMP" >= ADD_DAYS(CURRENT_TIMESTAMP, -30)
GROUP BY DATE("TIMESTAMP"), "METRIC_CODE", "METRIC_NAME"
ORDER BY "DATE" DESC, "METRIC_CODE";

-- -----------------------------------------------------------------------------
-- Stored Procedures for Drift Detection
-- -----------------------------------------------------------------------------

-- Procedure: Calculate Schema Staleness Score (SSS)
CREATE PROCEDURE "FINSIGHT_GOV"."SP_CALCULATE_SSS"(
    OUT "SSS_SCORE" DECIMAL(10,4)
)
LANGUAGE SQLSCRIPT
SQL SECURITY INVOKER
AS
BEGIN
    SELECT SUM(c."CHANGE_WEIGHT" * DAYS_BETWEEN(c."CHANGED_AT", CURRENT_TIMESTAMP))
    INTO "SSS_SCORE"
    FROM "FINSIGHT_GOV"."TTS_SCHEMA_CHANGES" c
    WHERE c."TRAINING_SYNCED" = FALSE;
    
    IF "SSS_SCORE" IS NULL THEN
        "SSS_SCORE" := 0;
    END IF;
END;

-- Procedure: Update user segment classification
CREATE PROCEDURE "FINSIGHT_GOV"."SP_UPDATE_USER_SEGMENTS"()
LANGUAGE SQLSCRIPT
SQL SECURITY INVOKER
AS
BEGIN
    -- Update query counts
    UPDATE "FINSIGHT_GOV"."TTS_USER_SEGMENTS" u
    SET 
        "QUERY_COUNT_TODAY" = (
            SELECT COUNT(*) FROM "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" q
            WHERE q."USER_ID" = u."USER_ID" 
              AND DATE(q."TIMESTAMP") = CURRENT_DATE
        ),
        "QUERY_COUNT_7D" = (
            SELECT COUNT(*) FROM "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" q
            WHERE q."USER_ID" = u."USER_ID" 
              AND q."TIMESTAMP" >= ADD_DAYS(CURRENT_TIMESTAMP, -7)
        ),
        "AVG_DAILY_QUERIES" = (
            SELECT CAST(COUNT(*) AS DECIMAL) / 7 FROM "FINSIGHT_GOV"."TTS_QUERY_SAMPLES" q
            WHERE q."USER_ID" = u."USER_ID" 
              AND q."TIMESTAMP" >= ADD_DAYS(CURRENT_TIMESTAMP, -7)
        ),
        "UPDATED_AT" = CURRENT_TIMESTAMP;
    
    -- Reclassify segments
    UPDATE "FINSIGHT_GOV"."TTS_USER_SEGMENTS"
    SET "SEGMENT" = CASE
        WHEN DAYS_BETWEEN("FIRST_SEEN_AT", CURRENT_TIMESTAMP) < 30 THEN 'new_user'
        WHEN "AVG_DAILY_QUERIES" > 100 THEN 'power_user'
        WHEN "AVG_DAILY_QUERIES" >= 10 THEN 'regular_user'
        ELSE 'occasional_user'
    END,
    "SAMPLE_RATE" = CASE
        WHEN DAYS_BETWEEN("FIRST_SEEN_AT", CURRENT_TIMESTAMP) < 30 THEN 0.5
        WHEN "AVG_DAILY_QUERIES" > 100 THEN 1.0
        WHEN "AVG_DAILY_QUERIES" >= 10 THEN 0.2
        ELSE 0.05
    END;
END;

-- -----------------------------------------------------------------------------
-- Grants (uncomment and modify for your environment)
-- -----------------------------------------------------------------------------

-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "FINSIGHT_GOV" TO <TTS_SERVICE_USER>;
-- GRANT EXECUTE ON PROCEDURE "FINSIGHT_GOV"."SP_CALCULATE_SSS" TO <TTS_SERVICE_USER>;
-- GRANT EXECUTE ON PROCEDURE "FINSIGHT_GOV"."SP_UPDATE_USER_SEGMENTS" TO <TTS_SERVICE_USER>;

-- =============================================================================
-- End of TTS Drift Tables DDL
-- =============================================================================