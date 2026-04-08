-- =============================================================================
-- Team Context Tables — Country × Domain scoping for data products
-- =============================================================================

-- 1. Team Configuration
CREATE COLUMN TABLE "FINSIGHT_CORE"."TEAM_CONFIG" (
    "TEAM_ID"       NVARCHAR(64)  NOT NULL PRIMARY KEY,   -- e.g. 'AE:treasury'
    "COUNTRY"       NVARCHAR(8)   NOT NULL DEFAULT '',     -- ISO code: AE, GB, US …
    "DOMAIN"        NVARCHAR(32)  NOT NULL DEFAULT '',     -- treasury, esg, performance
    "DISPLAY_NAME"  NVARCHAR(128) NOT NULL,
    "LOCALE"        NVARCHAR(8)   NOT NULL DEFAULT 'en',   -- primary locale (en, ar)
    "IS_ACTIVE"     BOOLEAN       NOT NULL DEFAULT TRUE,
    "CREATED_AT"    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT"    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX "IDX_TEAM_CONFIG_COUNTRY" ON "FINSIGHT_CORE"."TEAM_CONFIG" ("COUNTRY");
CREATE INDEX "IDX_TEAM_CONFIG_DOMAIN"  ON "FINSIGHT_CORE"."TEAM_CONFIG" ("DOMAIN");


-- 2. Team-Scoped Glossary Overrides
CREATE COLUMN TABLE "FINSIGHT_CORE"."TEAM_GLOSSARY" (
    "ID"            NVARCHAR(64)  NOT NULL PRIMARY KEY,
    "TEAM_ID"       NVARCHAR(64)  NOT NULL,                -- FK to TEAM_CONFIG or 'global'
    "SCOPE_LEVEL"   NVARCHAR(16)  NOT NULL DEFAULT 'team', -- global|domain|country|team
    "SOURCE_TEXT"   NVARCHAR(512) NOT NULL,
    "TARGET_TEXT"   NVARCHAR(512) NOT NULL,
    "SOURCE_LANG"   NVARCHAR(8)   NOT NULL DEFAULT 'en',
    "TARGET_LANG"   NVARCHAR(8)   NOT NULL DEFAULT 'ar',
    "CATEGORY"      NVARCHAR(64)  NOT NULL DEFAULT 'financial',
    "PAIR_TYPE"     NVARCHAR(32)  NOT NULL DEFAULT 'translation', -- translation|alias|db_field_mapping
    "IS_APPROVED"   BOOLEAN       NOT NULL DEFAULT FALSE,
    "CREATED_AT"    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT"    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX "IDX_TEAM_GLOSSARY_TEAM"  ON "FINSIGHT_CORE"."TEAM_GLOSSARY" ("TEAM_ID");
CREATE INDEX "IDX_TEAM_GLOSSARY_SCOPE" ON "FINSIGHT_CORE"."TEAM_GLOSSARY" ("SCOPE_LEVEL");


-- 3. Team ↔ Data Product Access Control
CREATE COLUMN TABLE "FINSIGHT_CORE"."TEAM_PRODUCT_ACCESS" (
    "TEAM_ID"       NVARCHAR(64)  NOT NULL,
    "PRODUCT_ID"    NVARCHAR(128) NOT NULL,                -- e.g. 'treasury-capital-markets-v1'
    "ACCESS_LEVEL"  NVARCHAR(16)  NOT NULL DEFAULT 'read', -- read|write|admin
    "GRANTED_AT"    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY ("TEAM_ID", "PRODUCT_ID")
);


-- 4. Per-Team LLM Prompt Overrides
CREATE COLUMN TABLE "FINSIGHT_CORE"."TEAM_PROMPT_OVERRIDE" (
    "ID"                   NVARCHAR(64)  NOT NULL PRIMARY KEY,
    "TEAM_ID"              NVARCHAR(64)  NOT NULL,
    "PRODUCT_ID"           NVARCHAR(128) NOT NULL DEFAULT '*', -- '*' = all products
    "SYSTEM_PROMPT_APPEND" NCLOB,                              -- appended to base prompt
    "TEMPERATURE"          DECIMAL(3,2),                       -- NULL = use default
    "MAX_TOKENS"           INTEGER,                            -- NULL = use default
    "CREATED_AT"           TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT"           TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE ("TEAM_ID", "PRODUCT_ID")
);


-- 5. Team-Specific Training Configuration
CREATE COLUMN TABLE "FINSIGHT_CORE"."TEAM_TRAINING_CONFIG" (
    "TEAM_ID"              NVARCHAR(64)  NOT NULL PRIMARY KEY,
    "DOMAIN"               NVARCHAR(32)  NOT NULL DEFAULT '',
    "INCLUDE_PATTERNS"     NCLOB,          -- JSON array of glob patterns
    "EXCLUDE_PATTERNS"     NCLOB,          -- JSON array of glob patterns
    "CUSTOM_TEMPLATES_PATH" NVARCHAR(512),
    "ENABLE_BILINGUAL"     BOOLEAN        NOT NULL DEFAULT FALSE,
    "COUNTRY_FILTER"       NVARCHAR(128),  -- value for GLB_FINAL_COUNTRY_NAME
    "CREATED_AT"           TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT"           TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);
