-- SPDX-License-Identifier: Apache-2.0
-- SPDX-FileCopyrightText: 2024 SAP SE
-- 
-- SAP OSS ai-core-pal - Production Domain Tables
-- 
-- These tables represent real SAP enterprise use cases for PAL algorithms:
--   - ESG emissions tracking (forecast scope 1/2/3 emissions)
--   - Financial revenue forecasting  
--   - Inventory demand planning
--   - Customer segmentation
--   - Equipment maintenance prediction
--
-- Run in SAP HANA Database Explorer

-- ============================================================================
-- ESG Sustainability - Carbon Emissions Tracking
-- Use cases: Forecast emissions, detect anomalies, target prediction
-- ============================================================================
CREATE TABLE IF NOT EXISTS "AINUCLEUS"."ESG_CARBON_EMISSIONS" (
    COMPANY_CODE        NVARCHAR(10) NOT NULL,
    REPORTING_PERIOD    DATE NOT NULL,
    SCOPE_1_EMISSIONS   DECIMAL(15,2),     -- Direct emissions (tCO2e)
    SCOPE_2_EMISSIONS   DECIMAL(15,2),     -- Electricity/energy (tCO2e)
    SCOPE_3_EMISSIONS   DECIMAL(15,2),     -- Value chain (tCO2e)
    TOTAL_EMISSIONS     DECIMAL(15,2),     -- Total carbon footprint
    ENERGY_CONSUMPTION  DECIMAL(15,2),     -- MWh
    RENEWABLE_PERCENT   DECIMAL(5,2),      -- % renewable energy
    CARBON_INTENSITY    DECIMAL(10,4),     -- tCO2e per unit revenue
    REDUCTION_TARGET    DECIMAL(5,2),      -- Target reduction %
    VERIFIED            BOOLEAN DEFAULT FALSE,
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (COMPANY_CODE, REPORTING_PERIOD)
);

-- ============================================================================
-- Financial Planning - Revenue & Cost Forecasting
-- Use cases: Revenue forecast, budget variance detection, trend analysis
-- ============================================================================
CREATE TABLE IF NOT EXISTS "AINUCLEUS"."FI_REVENUE_ACTUALS" (
    COMPANY_CODE        NVARCHAR(10) NOT NULL,
    FISCAL_PERIOD       DATE NOT NULL,
    PROFIT_CENTER       NVARCHAR(20),
    COST_CENTER         NVARCHAR(20),
    GL_ACCOUNT          NVARCHAR(20),
    REVENUE_ACTUAL      DECIMAL(18,2),     -- Actual revenue
    REVENUE_PLAN        DECIMAL(18,2),     -- Planned/budget
    COST_ACTUAL         DECIMAL(18,2),     -- Actual costs
    COST_PLAN           DECIMAL(18,2),     -- Planned costs
    GROSS_MARGIN        DECIMAL(18,2),     -- Revenue - Cost
    MARGIN_PERCENT      DECIMAL(5,2),      -- Margin %
    YOY_GROWTH          DECIMAL(5,2),      -- Year-over-year growth
    CURRENCY            NVARCHAR(3) DEFAULT 'USD',
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (COMPANY_CODE, FISCAL_PERIOD, PROFIT_CENTER)
);

-- ============================================================================
-- Supply Chain - Inventory & Demand Planning
-- Use cases: Demand forecasting, stock-out prediction, reorder optimization
-- ============================================================================
CREATE TABLE IF NOT EXISTS "AINUCLEUS"."MM_INVENTORY_HISTORY" (
    PLANT               NVARCHAR(10) NOT NULL,
    MATERIAL_NUMBER     NVARCHAR(40) NOT NULL,
    PERIOD_DATE         DATE NOT NULL,
    STOCK_QUANTITY      DECIMAL(15,3),     -- Current stock (units)
    SAFETY_STOCK        DECIMAL(15,3),     -- Safety stock level
    REORDER_POINT       DECIMAL(15,3),     -- Reorder trigger
    DEMAND_FORECAST     DECIMAL(15,3),     -- Forecasted demand
    ACTUAL_CONSUMPTION  DECIMAL(15,3),     -- Actual consumption
    LEAD_TIME_DAYS      INTEGER,           -- Supplier lead time
    STOCKOUT_DAYS       INTEGER DEFAULT 0, -- Days out of stock
    UNIT_COST           DECIMAL(15,2),     -- Cost per unit
    HOLDING_COST        DECIMAL(15,2),     -- Inventory holding cost
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (PLANT, MATERIAL_NUMBER, PERIOD_DATE)
);

-- ============================================================================
-- Customer Analytics - Segmentation & Churn
-- Use cases: Customer clustering, churn prediction, lifetime value
-- ============================================================================
CREATE TABLE IF NOT EXISTS "AINUCLEUS"."SD_CUSTOMER_ANALYTICS" (
    CUSTOMER_ID         NVARCHAR(20) NOT NULL,
    CUSTOMER_SEGMENT    NVARCHAR(20),      -- Enterprise/SMB/Consumer
    INDUSTRY            NVARCHAR(50),
    REGION              NVARCHAR(30),
    TENURE_MONTHS       INTEGER,           -- Customer tenure
    TOTAL_REVENUE       DECIMAL(18,2),     -- Lifetime revenue
    ORDERS_COUNT        INTEGER,           -- Total orders
    AVG_ORDER_VALUE     DECIMAL(15,2),     -- Average order size
    LAST_ORDER_DAYS     INTEGER,           -- Days since last order
    SUPPORT_TICKETS     INTEGER,           -- Support interactions
    NPS_SCORE           INTEGER,           -- Net Promoter Score (-100 to 100)
    SATISFACTION_SCORE  DECIMAL(3,1),      -- 1-5 rating
    CHURN_RISK_SCORE    DECIMAL(5,4),      -- ML-predicted churn probability
    PREDICTED_LTV       DECIMAL(18,2),     -- Predicted lifetime value
    CLUSTER_ID          INTEGER,           -- Customer segment cluster
    SNAPSHOT_DATE       DATE NOT NULL,
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (CUSTOMER_ID, SNAPSHOT_DATE)
);

-- ============================================================================
-- Equipment Maintenance - Predictive Maintenance
-- Use cases: Failure prediction, anomaly detection, maintenance scheduling
-- ============================================================================
CREATE TABLE IF NOT EXISTS "AINUCLEUS"."PM_EQUIPMENT_TELEMETRY" (
    EQUIPMENT_ID        NVARCHAR(20) NOT NULL,
    READING_TIMESTAMP   TIMESTAMP NOT NULL,
    PLANT               NVARCHAR(10),
    EQUIPMENT_TYPE      NVARCHAR(30),
    TEMPERATURE_C       DECIMAL(8,2),      -- Operating temperature
    VIBRATION_MM_S      DECIMAL(8,3),      -- Vibration level
    PRESSURE_BAR        DECIMAL(8,2),      -- Pressure reading
    POWER_KW            DECIMAL(10,2),     -- Power consumption
    RPM                 INTEGER,           -- Rotations per minute
    RUNTIME_HOURS       INTEGER,           -- Total runtime
    LAST_MAINTENANCE    DATE,              -- Last maintenance date
    MAINTENANCE_DUE     DATE,              -- Next scheduled maintenance
    ANOMALY_SCORE       DECIMAL(5,4),      -- Anomaly detection score (0-1)
    FAILURE_PROBABILITY DECIMAL(5,4),      -- Predicted failure prob
    HEALTH_STATUS       NVARCHAR(20),      -- GOOD/WARNING/CRITICAL
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (EQUIPMENT_ID, READING_TIMESTAMP)
);

-- ============================================================================
-- HR Analytics - Workforce Planning
-- Use cases: Attrition prediction, workforce clustering, skill gap analysis
-- ============================================================================
CREATE TABLE IF NOT EXISTS "AINUCLEUS"."HR_WORKFORCE_ANALYTICS" (
    EMPLOYEE_ID         NVARCHAR(20) NOT NULL,
    SNAPSHOT_DATE       DATE NOT NULL,
    DEPARTMENT          NVARCHAR(30),
    JOB_FAMILY          NVARCHAR(30),
    TENURE_YEARS        DECIMAL(4,1),
    AGE_RANGE           NVARCHAR(10),      -- 20-29, 30-39, etc.
    PERFORMANCE_RATING  INTEGER,           -- 1-5 scale
    ENGAGEMENT_SCORE    DECIMAL(3,1),      -- Survey score 1-5
    TRAINING_HOURS      INTEGER,           -- Training completed
    PROMOTION_COUNT     INTEGER,           -- Historical promotions
    SALARY_BAND         INTEGER,           -- Anonymized salary band
    MANAGER_RATING      DECIMAL(3,1),      -- Manager feedback
    ATTRITION_RISK      DECIMAL(5,4),      -- Predicted attrition probability
    FLIGHT_RISK_TIER    NVARCHAR(10),      -- HIGH/MEDIUM/LOW
    CLUSTER_ID          INTEGER,           -- Employee segment
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (EMPLOYEE_ID, SNAPSHOT_DATE)
);

-- ============================================================================
-- Create indexes for common query patterns
-- ============================================================================
CREATE INDEX IF NOT EXISTS "IDX_ESG_PERIOD" ON "AINUCLEUS"."ESG_CARBON_EMISSIONS" (REPORTING_PERIOD);
CREATE INDEX IF NOT EXISTS "IDX_FI_PERIOD" ON "AINUCLEUS"."FI_REVENUE_ACTUALS" (FISCAL_PERIOD);
CREATE INDEX IF NOT EXISTS "IDX_MM_DATE" ON "AINUCLEUS"."MM_INVENTORY_HISTORY" (PERIOD_DATE);
CREATE INDEX IF NOT EXISTS "IDX_SD_DATE" ON "AINUCLEUS"."SD_CUSTOMER_ANALYTICS" (SNAPSHOT_DATE);
CREATE INDEX IF NOT EXISTS "IDX_PM_TIME" ON "AINUCLEUS"."PM_EQUIPMENT_TELEMETRY" (READING_TIMESTAMP);
CREATE INDEX IF NOT EXISTS "IDX_HR_DATE" ON "AINUCLEUS"."HR_WORKFORCE_ANALYTICS" (SNAPSHOT_DATE);

-- ============================================================================
-- Grant permissions (adjust as needed)
-- ============================================================================
-- GRANT SELECT, INSERT, UPDATE ON "AINUCLEUS".* TO <service_user>;