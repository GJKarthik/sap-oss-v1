-- ============================================================================
-- SAP HANA Cloud - Domain Tables DDL for Text-to-SQL Training
-- Generated from: src/training/data/specialist_training/
-- 
-- These tables support the following domains:
--   1. GL (General Ledger) - Balance Sheet queries
--   2. ESG - Environmental, Social, Governance metrics
--   3. BPC - Business Planning & Consolidation (Performance)
--   4. TREASURY - Treasury and liquidity management
-- ============================================================================

-- ============================================================================
-- SCHEMA 1: GL (General Ledger)
-- Source: train_balance_sheet.json
-- SAP Tables: FAGLFLEXT (GL Totals), SKA1 (GL Master)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "GL";

-- GL.FAGLFLEXT - General Ledger Line Items (Totals)
-- SAP S/4HANA equivalent: ACDOCA/FAGLFLEXT
CREATE COLUMN TABLE "GL"."FAGLFLEXT" (
    -- Key Fields
    "RBUKRS" NVARCHAR(4) NOT NULL,              -- Company Code (US, UK, HK, SG, UAE, Korea, etc.)
    "RACCT" NVARCHAR(10) NOT NULL,              -- GL Account Number
    "RYEAR" NVARCHAR(4) NOT NULL,               -- Fiscal Year (2023, 2024, 2025, 2026)
    "RPERIOD" NVARCHAR(3) NOT NULL,             -- Fiscal Period (001-012)
    "RUNIT" NVARCHAR(4) DEFAULT 'C001',         -- Ledger Unit
    
    -- Dimension Fields
    "SEGMENT" NVARCHAR(20),                     -- Business Segment (WRB, CIB, Group, Central)
    "PRODUCT" NVARCHAR(50),                     -- Product (CASA, TD, Loans, etc.)
    "ACCOUNT_TYPE" NVARCHAR(20),                -- Account Type (ASSET, LIABILITY, L_AND_A)
    "ACCOUNT_NAME" NVARCHAR(100),               -- Account Description
    
    -- Amount Fields (House Currency)
    "HSL" DECIMAL(23,2) NOT NULL DEFAULT 0,     -- Amount in Local Currency
    "TSL" DECIMAL(23,2) DEFAULT 0,              -- Transaction Currency Amount
    "KSL" DECIMAL(23,2) DEFAULT 0,              -- Group Currency Amount
    "OSL" DECIMAL(23,2) DEFAULT 0,              -- Object Currency Amount
    
    -- Currency Fields
    "RHCUR" NVARCHAR(5) DEFAULT 'USD',          -- Local Currency
    "RTCUR" NVARCHAR(5),                        -- Transaction Currency
    "RKCUR" NVARCHAR(5),                        -- Group Currency
    
    -- Audit Fields
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY ("RBUKRS", "RACCT", "RYEAR", "RPERIOD", "RUNIT")
);

-- GL.SKA1 - GL Account Master Data
-- SAP S/4HANA equivalent: SKA1/SKB1
CREATE COLUMN TABLE "GL"."SKA1" (
    "SAKNR" NVARCHAR(10) NOT NULL,              -- GL Account Number
    "KTOPL" NVARCHAR(4) DEFAULT 'INT',          -- Chart of Accounts
    "TXT20" NVARCHAR(20),                       -- Short Text
    "TXT50" NVARCHAR(50),                       -- Long Text
    "XBILK" NVARCHAR(1) DEFAULT ' ',            -- Balance Sheet Account Indicator (X = Balance Sheet)
    "GVTYP" NVARCHAR(2),                        -- P&L Statement Account Type
    "KTOKS" NVARCHAR(4),                        -- GL Account Group
    "XLOEV" NVARCHAR(1) DEFAULT ' ',            -- Deletion Flag
    "XSPEB" NVARCHAR(1) DEFAULT ' ',            -- Blocked for Posting
    
    -- Classification
    "BILKT" NVARCHAR(10),                       -- Group Account Number
    "ERDAT" DATE,                               -- Creation Date
    "ERNAM" NVARCHAR(12),                       -- Created By
    
    PRIMARY KEY ("SAKNR", "KTOPL")
);

-- Index for join performance
CREATE INDEX "GL"."IDX_FAGLFLEXT_RACCT" ON "GL"."FAGLFLEXT" ("RACCT");
CREATE INDEX "GL"."IDX_FAGLFLEXT_SEGMENT" ON "GL"."FAGLFLEXT" ("SEGMENT");
CREATE INDEX "GL"."IDX_FAGLFLEXT_YEAR" ON "GL"."FAGLFLEXT" ("RYEAR");

-- ============================================================================
-- SCHEMA 2: ESG (Environmental, Social, Governance)
-- Source: train_esg.json
-- Primary Table: SF_FLAT (Sustainable Finance Flat File)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "ESG";

-- ESG.SF_FLAT - Sustainable Finance Data
-- Denormalized structure for Net Zero reporting and financed emissions
CREATE COLUMN TABLE "ESG"."SF_FLAT" (
    "SF_ID" NVARCHAR(64) NOT NULL,              -- Record ID
    "PERIOD" NVARCHAR(20) NOT NULL,             -- Reporting Period (2024, 2025, Jan 2025, Q4 2024)
    
    -- Geographic Dimensions
    "BOOKING_LOCATION" NVARCHAR(100),           -- Booking Location (India, CHINA, UNITED KINGDOM, South Asia)
    "ULTIMATE_PARENT_LOCATION" NVARCHAR(100),   -- Parent Location (ASEAN, GCNA, South Asia)
    "COUNTRY" NVARCHAR(100),                    -- Country
    
    -- Client/Segment Dimensions
    "CLIENT_NAME" NVARCHAR(200),                -- Client Name
    "CLIENT_SEGMENT" NVARCHAR(100),             -- Client Segment (Financial Institution, Corporates, Global Subsidiaries GC)
    "NET_ZERO_SECTOR" NVARCHAR(100),            -- Net Zero Sector (OIL AND GAS, CEMENT, POWER, AUTOMOTIVE MANUFACTURERS)
    "MANAGEMENT_PRODUCT" NVARCHAR(100),         -- Management Product Hierarchy
    
    -- Financial Metrics
    "NFI_YTD" DECIMAL(23,2) DEFAULT 0,          -- Net Fee Income YTD
    "TOTAL_REVENUE_YTD" DECIMAL(23,2) DEFAULT 0, -- Total Revenue YTD
    "EXPOSURE" DECIMAL(23,2) DEFAULT 0,         -- Total Exposure
    "IN_SCOPE_EXPOSURE" DECIMAL(23,2) DEFAULT 0, -- In-Scope Exposure for Net Zero
    "RWA" DECIMAL(23,2) DEFAULT 0,              -- Risk Weighted Assets
    "CIB_PE_ASSET" DECIMAL(23,2) DEFAULT 0,     -- CIB Private Equity Asset
    
    -- ESG Metrics
    "FINANCED_EMISSION" DECIMAL(23,4) DEFAULT 0, -- Financed Emissions (tCO2e)
    "EMISSION_INTENSITY" DECIMAL(15,6) DEFAULT 0, -- Emission Intensity
    "TRANSITION_SCORE" DECIMAL(5,2) DEFAULT 0,   -- Transition Risk Score (0-100)
    "PHYSICAL_RISK_SCORE" DECIMAL(5,2) DEFAULT 0, -- Physical Risk Score (0-100)
    
    -- Audit Fields
    "DATA_SOURCE" NVARCHAR(50),                 -- Data Source System
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY ("SF_ID")
);

-- ESG Indexes for common query patterns
CREATE INDEX "ESG"."IDX_SF_FLAT_PERIOD" ON "ESG"."SF_FLAT" ("PERIOD");
CREATE INDEX "ESG"."IDX_SF_FLAT_SECTOR" ON "ESG"."SF_FLAT" ("NET_ZERO_SECTOR");
CREATE INDEX "ESG"."IDX_SF_FLAT_LOCATION" ON "ESG"."SF_FLAT" ("BOOKING_LOCATION");
CREATE INDEX "ESG"."IDX_SF_FLAT_SEGMENT" ON "ESG"."SF_FLAT" ("CLIENT_SEGMENT");

-- ============================================================================
-- SCHEMA 3: BPC (Business Planning & Consolidation)
-- Source: train_performance.json
-- Primary Table: ZFI_FIN_OVER_AFO_CP_FIN (Financial Overview)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "BPC";

-- BPC.ZFI_FIN_OVER_AFO_CP_FIN - Financial Performance Overview
-- SAP BPC/BW equivalent for P&L and performance metrics
CREATE COLUMN TABLE "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" (
    "BPC_ID" NVARCHAR(64) NOT NULL,             -- Record ID
    
    -- Time Dimensions
    "FISCYEAR" NVARCHAR(4) NOT NULL,            -- Fiscal Year (2023, 2024, 2025, 2026)
    "FISCPER" NVARCHAR(7) NOT NULL,             -- Fiscal Period (2024001, 2024012)
    "FISCPER_MONTH" NVARCHAR(2),                -- Month (01-12)
    "FISCPER_QUARTER" NVARCHAR(1),              -- Quarter (1-4)
    
    -- Organizational Dimensions
    "ENTITY" NVARCHAR(10),                      -- Legal Entity (US, UK, Korea, UAE, HK, SG)
    "SEGMENT" NVARCHAR(20),                     -- Business Segment (WRB, CIB, Group, Central)
    "PRODUCT" NVARCHAR(50),                     -- Product Line
    "COST_CENTER" NVARCHAR(10),                 -- Cost Center
    
    -- Account Dimension
    "ACCOUNT" NVARCHAR(100) NOT NULL,           -- P&L Account Name:
                                                 -- NII, NFI, Client Income, Service Charges
                                                 -- Operating Profit, Underlying PBT, PBT, PAT
                                                 -- Credit Impairment, Total Impairment, Other Impairment
                                                 -- Direct Controllable, TTO Recharges, Bonus
                                                 -- Avg Assets, GFGCR
    
    -- Data Type/Flow Dimension
    "FLOW" NVARCHAR(20) NOT NULL,               -- Data Flow (Actuals, Budget, Forecast, Prior)
    "VERSION" NVARCHAR(20) DEFAULT 'CURRENT',   -- Version
    
    -- Currency Dimensions
    "ZCURIDEN" NVARCHAR(5) NOT NULL,            -- Currency Identifier (RFX = Reporting, CFX = Constant)
    "CURRENCY" NVARCHAR(5) DEFAULT 'USD',       -- Currency Code
    
    -- Amount Fields
    "RTC_AMO" DECIMAL(23,2) NOT NULL DEFAULT 0, -- Amount in Reporting Currency
    "LTC_AMO" DECIMAL(23,2) DEFAULT 0,          -- Amount in Local Currency
    "QTY" DECIMAL(23,4) DEFAULT 0,              -- Quantity (for non-monetary)
    
    -- Audit Fields
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY ("BPC_ID")
);

-- BPC Indexes for common query patterns
CREATE INDEX "BPC"."IDX_ZFI_FISCPER" ON "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" ("FISCPER");
CREATE INDEX "BPC"."IDX_ZFI_SEGMENT" ON "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" ("SEGMENT");
CREATE INDEX "BPC"."IDX_ZFI_ACCOUNT" ON "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" ("ACCOUNT");
CREATE INDEX "BPC"."IDX_ZFI_ENTITY" ON "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" ("ENTITY");
CREATE INDEX "BPC"."IDX_ZFI_FLOW" ON "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" ("FLOW");

-- ============================================================================
-- SCHEMA 4: TREASURY
-- Source: train_treasury.json
-- Primary Table: POSITION (Treasury Position Management)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS "TREASURY";

-- TREASURY.POSITION - Treasury Position Data
-- Treasury management including bonds, IRS, and other instruments
CREATE COLUMN TABLE "TREASURY"."POSITION" (
    "POSITION_ID" NVARCHAR(64) NOT NULL,        -- Position ID
    
    -- Time Dimensions
    "COB_DATE" NVARCHAR(20) NOT NULL,           -- Close of Business Date (March 2025, Q4 2024)
    "TRADE_DATE" DATE,                          -- Trade Date
    "MATURITY_DATE" DATE,                       -- Maturity Date
    "VALUE_DATE" DATE,                          -- Value Date
    
    -- Instrument Classification
    "PRODUCT_TYPE" NVARCHAR(50),                -- Product Type (Bonds, IRS, Issuances, FX)
    "MODEL" NVARCHAR(50),                       -- Accounting Model (HTC, FVTPL, Amortised Cost, FVOCI)
    "PORTFOLIO" NVARCHAR(50),                   -- Portfolio (UKBONDIM, etc.)
    
    -- Geographic Dimensions
    "COUNTRY" NVARCHAR(50),                     -- Country (KENYA, CHINA, UK, etc.)
    "REGION" NVARCHAR(50),                      -- Region
    "ENTITY" NVARCHAR(10),                      -- Legal Entity
    
    -- Position Amounts
    "NOTIONAL" DECIMAL(23,2) DEFAULT 0,         -- Notional Amount
    "BOOK_VALUE" DECIMAL(23,2) DEFAULT 0,       -- Book Value
    "MTM" DECIMAL(23,2) DEFAULT 0,              -- Mark-to-Market Value
    "RWA" DECIMAL(23,2) DEFAULT 0,              -- Risk Weighted Assets
    
    -- Yield & Risk Metrics
    "HOLDING_YIELD" DECIMAL(15,8) DEFAULT 0,    -- Holding Yield
    "WEIGHTED_AVERAGE_HOLDING_YIELD" DECIMAL(15,8) DEFAULT 0, -- Weighted Avg Holding Yield
    "PV01" DECIMAL(23,4) DEFAULT 0,             -- PV01 (Interest Rate Sensitivity)
    "CR_DELTA" DECIMAL(23,4) DEFAULT 0,         -- Credit Delta
    "DURATION" DECIMAL(15,4) DEFAULT 0,         -- Modified Duration
    "DV01" DECIMAL(23,4) DEFAULT 0,             -- DV01 (Dollar Value of 1bp)
    
    -- Currency
    "CURRENCY" NVARCHAR(5) DEFAULT 'USD',       -- Currency Code
    "FX_RATE" DECIMAL(15,6) DEFAULT 1.0,        -- FX Rate to Reporting Currency
    
    -- Counterparty
    "COUNTERPARTY_ID" NVARCHAR(50),             -- Counterparty ID
    "COUNTERPARTY_NAME" NVARCHAR(200),          -- Counterparty Name
    
    -- Audit Fields
    "CREATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "UPDATED_AT" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY ("POSITION_ID")
);

-- Treasury Indexes
CREATE INDEX "TREASURY"."IDX_POSITION_COB" ON "TREASURY"."POSITION" ("COB_DATE");
CREATE INDEX "TREASURY"."IDX_POSITION_MODEL" ON "TREASURY"."POSITION" ("MODEL");
CREATE INDEX "TREASURY"."IDX_POSITION_COUNTRY" ON "TREASURY"."POSITION" ("COUNTRY");
CREATE INDEX "TREASURY"."IDX_POSITION_PRODUCT" ON "TREASURY"."POSITION" ("PRODUCT_TYPE");
CREATE INDEX "TREASURY"."IDX_POSITION_PORTFOLIO" ON "TREASURY"."POSITION" ("PORTFOLIO");

-- ============================================================================
-- REFERENCE DATA TABLES
-- Supporting lookup tables for the domain schemas
-- ============================================================================

-- GL Reference: Account Types
CREATE COLUMN TABLE "GL"."ACCOUNT_TYPES" (
    "ACCOUNT_TYPE" NVARCHAR(20) NOT NULL,
    "DESCRIPTION" NVARCHAR(100),
    "BS_PL_FLAG" NVARCHAR(2),  -- BS = Balance Sheet, PL = P&L
    PRIMARY KEY ("ACCOUNT_TYPE")
);

INSERT INTO "GL"."ACCOUNT_TYPES" VALUES ('ASSET', 'Asset Account', 'BS');
INSERT INTO "GL"."ACCOUNT_TYPES" VALUES ('LIABILITY', 'Liability Account', 'BS');
INSERT INTO "GL"."ACCOUNT_TYPES" VALUES ('EQUITY', 'Equity Account', 'BS');
INSERT INTO "GL"."ACCOUNT_TYPES" VALUES ('REVENUE', 'Revenue Account', 'PL');
INSERT INTO "GL"."ACCOUNT_TYPES" VALUES ('EXPENSE', 'Expense Account', 'PL');
INSERT INTO "GL"."ACCOUNT_TYPES" VALUES ('L_AND_A', 'Loans and Advances', 'BS');

-- Business Segments Reference
CREATE COLUMN TABLE "GL"."SEGMENTS" (
    "SEGMENT" NVARCHAR(20) NOT NULL,
    "DESCRIPTION" NVARCHAR(100),
    "PARENT_SEGMENT" NVARCHAR(20),
    PRIMARY KEY ("SEGMENT")
);

INSERT INTO "GL"."SEGMENTS" VALUES ('Group', 'Group Total', NULL);
INSERT INTO "GL"."SEGMENTS" VALUES ('WRB', 'Wealth & Retail Banking', 'Group');
INSERT INTO "GL"."SEGMENTS" VALUES ('CIB', 'Corporate & Investment Banking', 'Group');
INSERT INTO "GL"."SEGMENTS" VALUES ('Central', 'Central Functions', 'Group');

-- Entity (Country/Region) Reference
CREATE COLUMN TABLE "GL"."ENTITIES" (
    "ENTITY" NVARCHAR(10) NOT NULL,
    "DESCRIPTION" NVARCHAR(100),
    "REGION" NVARCHAR(50),
    "CURRENCY" NVARCHAR(5),
    PRIMARY KEY ("ENTITY")
);

INSERT INTO "GL"."ENTITIES" VALUES ('US', 'United States', 'Americas', 'USD');
INSERT INTO "GL"."ENTITIES" VALUES ('UK', 'United Kingdom', 'Europe', 'GBP');
INSERT INTO "GL"."ENTITIES" VALUES ('HK', 'Hong Kong', 'Asia', 'HKD');
INSERT INTO "GL"."ENTITIES" VALUES ('SG', 'Singapore', 'Asia', 'SGD');
INSERT INTO "GL"."ENTITIES" VALUES ('UAE', 'United Arab Emirates', 'Middle East', 'AED');
INSERT INTO "GL"."ENTITIES" VALUES ('Korea', 'South Korea', 'Asia', 'KRW');
INSERT INTO "GL"."ENTITIES" VALUES ('Group', 'Group Consolidated', 'Global', 'USD');

-- ESG Net Zero Sectors Reference
CREATE COLUMN TABLE "ESG"."NET_ZERO_SECTORS" (
    "SECTOR_CODE" NVARCHAR(50) NOT NULL,
    "SECTOR_NAME" NVARCHAR(100),
    "SECTOR_CATEGORY" NVARCHAR(50),
    "PRIORITY" INTEGER,
    PRIMARY KEY ("SECTOR_CODE")
);

INSERT INTO "ESG"."NET_ZERO_SECTORS" VALUES ('OIL AND GAS', 'Oil and Gas', 'Energy', 1);
INSERT INTO "ESG"."NET_ZERO_SECTORS" VALUES ('POWER', 'Power Generation', 'Energy', 2);
INSERT INTO "ESG"."NET_ZERO_SECTORS" VALUES ('CEMENT', 'Cement', 'Materials', 3);
INSERT INTO "ESG"."NET_ZERO_SECTORS" VALUES ('AUTOMOTIVE MANUFACTURERS', 'Automotive Manufacturers', 'Transport', 4);

-- BPC Account Hierarchy Reference
CREATE COLUMN TABLE "BPC"."ACCOUNTS" (
    "ACCOUNT" NVARCHAR(100) NOT NULL,
    "ACCOUNT_TYPE" NVARCHAR(20),
    "PARENT_ACCOUNT" NVARCHAR(100),
    "DISPLAY_ORDER" INTEGER,
    PRIMARY KEY ("ACCOUNT")
);

INSERT INTO "BPC"."ACCOUNTS" VALUES ('NII', 'REVENUE', 'Total Income', 1);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('NFI', 'REVENUE', 'Total Income', 2);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Client Income', 'REVENUE', 'Total Income', 3);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Service Charges', 'REVENUE', 'NFI', 4);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Operating Profit', 'PROFIT', 'PBT', 10);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Underlying PBT', 'PROFIT', 'PBT', 11);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('PBT', 'PROFIT', 'PAT', 12);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('PAT', 'PROFIT', NULL, 13);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Credit Impairment', 'EXPENSE', 'Total Impairment', 20);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Other Impairment', 'EXPENSE', 'Total Impairment', 21);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Total Impairment', 'EXPENSE', 'Operating Profit', 22);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Direct Controllable', 'EXPENSE', 'Operating Expenses', 30);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('TTO Recharges', 'EXPENSE', 'Operating Expenses', 31);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Bonus', 'EXPENSE', 'Operating Expenses', 32);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('Avg Assets', 'BALANCE', NULL, 40);
INSERT INTO "BPC"."ACCOUNTS" VALUES ('GFGCR', 'RATIO', NULL, 50);

-- Treasury Accounting Models Reference
CREATE COLUMN TABLE "TREASURY"."ACCOUNTING_MODELS" (
    "MODEL" NVARCHAR(50) NOT NULL,
    "DESCRIPTION" NVARCHAR(200),
    "MEASUREMENT_BASIS" NVARCHAR(50),
    PRIMARY KEY ("MODEL")
);

INSERT INTO "TREASURY"."ACCOUNTING_MODELS" VALUES ('HTC', 'Held to Collect', 'Amortised Cost');
INSERT INTO "TREASURY"."ACCOUNTING_MODELS" VALUES ('FVTPL', 'Fair Value Through P&L', 'Fair Value');
INSERT INTO "TREASURY"."ACCOUNTING_MODELS" VALUES ('FVOCI', 'Fair Value Through OCI', 'Fair Value');
INSERT INTO "TREASURY"."ACCOUNTING_MODELS" VALUES ('Amortised Cost', 'Amortised Cost', 'Amortised Cost');

-- ============================================================================
-- GRANTS (Update <SERVICE_USER> with actual user)
-- ============================================================================

-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "GL" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "ESG" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "BPC" TO <SERVICE_USER>;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA "TREASURY" TO <SERVICE_USER>;

-- ============================================================================
-- SAMPLE DATA INSERTION (for testing)
-- ============================================================================

-- Sample GL data
INSERT INTO "GL"."FAGLFLEXT" ("RBUKRS", "RACCT", "RYEAR", "RPERIOD", "SEGMENT", "PRODUCT", "ACCOUNT_TYPE", "HSL")
VALUES ('US', '1000010', '2024', '012', 'CIB', 'CASA', 'ASSET', 1500000000.00);

INSERT INTO "GL"."FAGLFLEXT" ("RBUKRS", "RACCT", "RYEAR", "RPERIOD", "SEGMENT", "PRODUCT", "ACCOUNT_TYPE", "HSL")
VALUES ('US', '1000020', '2024', '012', 'CIB', 'TD', 'LIABILITY', 800000000.00);

-- Sample GL Master
INSERT INTO "GL"."SKA1" ("SAKNR", "TXT20", "TXT50", "XBILK")
VALUES ('1000010', 'Cash & Equiv', 'Cash and Cash Equivalents', 'X');

INSERT INTO "GL"."SKA1" ("SAKNR", "TXT20", "TXT50", "XBILK")
VALUES ('1000020', 'Customer Deps', 'Customer Deposits', 'X');

-- Sample ESG data
INSERT INTO "ESG"."SF_FLAT" ("SF_ID", "PERIOD", "BOOKING_LOCATION", "NET_ZERO_SECTOR", "NFI_YTD", "FINANCED_EMISSION")
VALUES ('ESG001', '2024', 'India', 'OIL AND GAS', 5000000.00, 125000.5000);

-- Sample BPC data
INSERT INTO "BPC"."ZFI_FIN_OVER_AFO_CP_FIN" ("BPC_ID", "FISCYEAR", "FISCPER", "ENTITY", "SEGMENT", "ACCOUNT", "FLOW", "ZCURIDEN", "RTC_AMO")
VALUES ('BPC001', '2024', '2024012', 'US', 'CIB', 'NII', 'Actuals', 'RFX', 250000000.00);

-- Sample Treasury data
INSERT INTO "TREASURY"."POSITION" ("POSITION_ID", "COB_DATE", "PRODUCT_TYPE", "MODEL", "COUNTRY", "BOOK_VALUE", "MTM")
VALUES ('TREAS001', 'March 2025', 'Bonds', 'HTC', 'UK', 50000000.00, 51500000.00);

-- ============================================================================
-- END OF DDL SCRIPT
-- ============================================================================