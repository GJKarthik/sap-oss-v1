-- SPDX-License-Identifier: Apache-2.0
-- SPDX-FileCopyrightText: 2024 SAP SE
-- 
-- SAP OSS ai-core-pal - Sample Production Data
-- 
-- Realistic sample data for SAP enterprise use cases:
--   - ESG carbon emissions (36 months history)
--   - Financial revenue actuals (24 months history)
--   - Inventory history (12 months history)
--   - Customer analytics (100 customers)
--   - Equipment telemetry (1000 readings)
--   - HR workforce analytics (50 employees)
--
-- Run in SAP HANA Database Explorer after create_tables.sql

-- ============================================================================
-- ESG Carbon Emissions - 3 years monthly data for forecasting
-- Use cases: Forecast emissions, detect anomalies, target prediction
-- ============================================================================
DELETE FROM "AINUCLEUS"."ESG_CARBON_EMISSIONS";

-- Insert 36 months of ESG data with realistic seasonal patterns
DO BEGIN
    DECLARE v_date DATE := ADD_MONTHS(CURRENT_DATE, -36);
    DECLARE v_month INTEGER;
    DECLARE v_base_scope1 DECIMAL(15,2) := 1250.00;
    DECLARE v_base_scope2 DECIMAL(15,2) := 850.00;
    DECLARE v_base_scope3 DECIMAL(15,2) := 4500.00;
    
    FOR i IN 1..36 DO
        v_month := MONTH(v_date);
        
        -- Seasonal variation (higher in winter, lower in summer)
        INSERT INTO "AINUCLEUS"."ESG_CARBON_EMISSIONS" (
            COMPANY_CODE, REPORTING_PERIOD, SCOPE_1_EMISSIONS, SCOPE_2_EMISSIONS,
            SCOPE_3_EMISSIONS, TOTAL_EMISSIONS, ENERGY_CONSUMPTION, RENEWABLE_PERCENT,
            CARBON_INTENSITY, REDUCTION_TARGET, VERIFIED
        ) VALUES (
            'SAP1000',
            v_date,
            v_base_scope1 * (1 + 0.15 * COS(3.14159 * v_month / 6)) * (1 - 0.02 * i/36) + RAND() * 50,
            v_base_scope2 * (1 + 0.20 * COS(3.14159 * v_month / 6)) * (1 - 0.03 * i/36) + RAND() * 30,
            v_base_scope3 * (1 + 0.10 * COS(3.14159 * v_month / 6)) * (1 - 0.01 * i/36) + RAND() * 200,
            NULL, -- Will calculate total
            8500 * (1 + 0.15 * COS(3.14159 * v_month / 6)),
            35 + (i * 1.5), -- Increasing renewable %
            0.012 - (i * 0.0001), -- Decreasing carbon intensity
            40.00, -- 40% reduction target by 2030
            TRUE
        );
        
        -- Update total emissions
        UPDATE "AINUCLEUS"."ESG_CARBON_EMISSIONS" 
        SET TOTAL_EMISSIONS = SCOPE_1_EMISSIONS + SCOPE_2_EMISSIONS + SCOPE_3_EMISSIONS
        WHERE COMPANY_CODE = 'SAP1000' AND REPORTING_PERIOD = v_date;
        
        v_date := ADD_MONTHS(v_date, 1);
    END FOR;
END;

-- ============================================================================
-- Financial Revenue Actuals - 24 months for revenue forecasting
-- Use cases: Revenue forecast, budget variance detection
-- ============================================================================
DELETE FROM "AINUCLEUS"."FI_REVENUE_ACTUALS";

DO BEGIN
    DECLARE v_date DATE := ADD_MONTHS(CURRENT_DATE, -24);
    DECLARE v_base_revenue DECIMAL(18,2) := 12500000.00;
    DECLARE v_month INTEGER;
    
    FOR i IN 1..24 DO
        v_month := MONTH(v_date);
        
        -- Q4 typically higher revenue, Q1 lower
        INSERT INTO "AINUCLEUS"."FI_REVENUE_ACTUALS" (
            COMPANY_CODE, FISCAL_PERIOD, PROFIT_CENTER, COST_CENTER, GL_ACCOUNT,
            REVENUE_ACTUAL, REVENUE_PLAN, COST_ACTUAL, COST_PLAN,
            GROSS_MARGIN, MARGIN_PERCENT, YOY_GROWTH, CURRENCY
        ) VALUES (
            'SAP1000',
            v_date,
            'PC-CLOUD',
            'CC-SALES',
            '8000000',
            v_base_revenue * (1 + 0.03 * i/24) * (1 + 0.15 * CASE WHEN v_month IN (10,11,12) THEN 1 WHEN v_month IN (1,2) THEN -0.5 ELSE 0 END) + RAND() * 500000,
            v_base_revenue * (1 + 0.02 * i/24),
            v_base_revenue * 0.65 * (1 + 0.02 * i/24) + RAND() * 200000,
            v_base_revenue * 0.63 * (1 + 0.02 * i/24),
            NULL, -- Calculate later
            NULL,
            CASE WHEN i > 12 THEN 5.5 + RAND() * 3 ELSE NULL END,
            'USD'
        );
        
        -- Update calculated fields
        UPDATE "AINUCLEUS"."FI_REVENUE_ACTUALS"
        SET GROSS_MARGIN = REVENUE_ACTUAL - COST_ACTUAL,
            MARGIN_PERCENT = (REVENUE_ACTUAL - COST_ACTUAL) / REVENUE_ACTUAL * 100
        WHERE COMPANY_CODE = 'SAP1000' AND FISCAL_PERIOD = v_date AND PROFIT_CENTER = 'PC-CLOUD';
        
        v_date := ADD_MONTHS(v_date, 1);
    END FOR;
END;

-- ============================================================================
-- Inventory History - 12 months for demand forecasting
-- Use cases: Demand forecasting, stock-out prediction
-- ============================================================================
DELETE FROM "AINUCLEUS"."MM_INVENTORY_HISTORY";

DO BEGIN
    DECLARE v_date DATE := ADD_MONTHS(CURRENT_DATE, -12);
    DECLARE v_materials NVARCHAR(40) ARRAY := ARRAY['MAT-SERVER-001', 'MAT-STORAGE-002', 'MAT-NETWORK-003', 'MAT-CABLE-004', 'MAT-RACK-005'];
    DECLARE v_base_demand DECIMAL(15,3);
    
    FOR mat_idx IN 1..5 DO
        v_date := ADD_MONTHS(CURRENT_DATE, -12);
        v_base_demand := 100 + mat_idx * 50;
        
        FOR i IN 1..12 DO
            INSERT INTO "AINUCLEUS"."MM_INVENTORY_HISTORY" (
                PLANT, MATERIAL_NUMBER, PERIOD_DATE, STOCK_QUANTITY, SAFETY_STOCK,
                REORDER_POINT, DEMAND_FORECAST, ACTUAL_CONSUMPTION, LEAD_TIME_DAYS,
                STOCKOUT_DAYS, UNIT_COST, HOLDING_COST
            ) VALUES (
                'PLANT-DE1',
                :v_materials[mat_idx],
                v_date,
                v_base_demand * 2 + RAND() * v_base_demand,
                v_base_demand * 0.5,
                v_base_demand * 0.75,
                v_base_demand * (1 + 0.05 * i/12),
                v_base_demand * (0.9 + RAND() * 0.3),
                14 + mat_idx * 2,
                CASE WHEN RAND() > 0.9 THEN FLOOR(RAND() * 3) ELSE 0 END,
                50.00 + mat_idx * 100,
                (50.00 + mat_idx * 100) * 0.02
            );
            
            v_date := ADD_MONTHS(v_date, 1);
        END FOR;
    END FOR;
END;

-- ============================================================================
-- Customer Analytics - 100 customers for segmentation
-- Use cases: Customer clustering, churn prediction
-- ============================================================================
DELETE FROM "AINUCLEUS"."SD_CUSTOMER_ANALYTICS";

DO BEGIN
    DECLARE v_segments NVARCHAR(20) ARRAY := ARRAY['Enterprise', 'SMB', 'Consumer'];
    DECLARE v_industries NVARCHAR(50) ARRAY := ARRAY['Technology', 'Manufacturing', 'Retail', 'Finance', 'Healthcare'];
    DECLARE v_regions NVARCHAR(30) ARRAY := ARRAY['EMEA', 'Americas', 'APJ'];
    
    FOR i IN 1..100 DO
        INSERT INTO "AINUCLEUS"."SD_CUSTOMER_ANALYTICS" (
            CUSTOMER_ID, CUSTOMER_SEGMENT, INDUSTRY, REGION, TENURE_MONTHS,
            TOTAL_REVENUE, ORDERS_COUNT, AVG_ORDER_VALUE, LAST_ORDER_DAYS,
            SUPPORT_TICKETS, NPS_SCORE, SATISFACTION_SCORE, CHURN_RISK_SCORE,
            PREDICTED_LTV, CLUSTER_ID, SNAPSHOT_DATE
        ) VALUES (
            'CUST-' || LPAD(TO_VARCHAR(i), 5, '0'),
            :v_segments[1 + MOD(i, 3)],
            :v_industries[1 + MOD(i, 5)],
            :v_regions[1 + MOD(i, 3)],
            FLOOR(6 + RAND() * 60),  -- 6-66 months tenure
            CASE MOD(i, 3) 
                WHEN 0 THEN 500000 + RAND() * 2000000  -- Enterprise
                WHEN 1 THEN 50000 + RAND() * 200000    -- SMB
                ELSE 1000 + RAND() * 20000             -- Consumer
            END,
            FLOOR(5 + RAND() * 50),  -- 5-55 orders
            NULL, -- Calculate later
            FLOOR(RAND() * 180),  -- 0-180 days since last order
            FLOOR(RAND() * 15),   -- 0-15 support tickets
            FLOOR(-50 + RAND() * 100),  -- NPS -50 to 50
            1.0 + RAND() * 4,     -- 1-5 satisfaction
            0.05 + RAND() * 0.4,  -- 5-45% churn risk
            NULL, -- Calculate later
            1 + MOD(i, 5),        -- Cluster 1-5
            CURRENT_DATE
        );
    END FOR;
    
    -- Calculate AVG_ORDER_VALUE and PREDICTED_LTV
    UPDATE "AINUCLEUS"."SD_CUSTOMER_ANALYTICS"
    SET AVG_ORDER_VALUE = TOTAL_REVENUE / ORDERS_COUNT,
        PREDICTED_LTV = TOTAL_REVENUE * (1 + (1 - CHURN_RISK_SCORE) * 2);
END;

-- ============================================================================
-- Equipment Telemetry - 1000 readings for anomaly detection
-- Use cases: Failure prediction, anomaly detection
-- ============================================================================
DELETE FROM "AINUCLEUS"."PM_EQUIPMENT_TELEMETRY";

DO BEGIN
    DECLARE v_equipment_ids NVARCHAR(20) ARRAY := ARRAY['EQ-PUMP-001', 'EQ-MOTOR-002', 'EQ-COMP-003', 'EQ-TURB-004', 'EQ-GEN-005'];
    DECLARE v_types NVARCHAR(30) ARRAY := ARRAY['Pump', 'Motor', 'Compressor', 'Turbine', 'Generator'];
    DECLARE v_timestamp TIMESTAMP;
    DECLARE v_temp_base DECIMAL(8,2);
    DECLARE v_is_anomaly BOOLEAN;
    
    FOR eq_idx IN 1..5 DO
        v_timestamp := ADD_SECONDS(CURRENT_TIMESTAMP, -200 * 3600);  -- Start 200 hours ago
        v_temp_base := 45 + eq_idx * 5;
        
        FOR i IN 1..200 DO
            v_is_anomaly := RAND() > 0.95;  -- 5% anomaly rate
            
            INSERT INTO "AINUCLEUS"."PM_EQUIPMENT_TELEMETRY" (
                EQUIPMENT_ID, READING_TIMESTAMP, PLANT, EQUIPMENT_TYPE,
                TEMPERATURE_C, VIBRATION_MM_S, PRESSURE_BAR, POWER_KW, RPM,
                RUNTIME_HOURS, LAST_MAINTENANCE, MAINTENANCE_DUE,
                ANOMALY_SCORE, FAILURE_PROBABILITY, HEALTH_STATUS
            ) VALUES (
                :v_equipment_ids[eq_idx],
                v_timestamp,
                'PLANT-DE1',
                :v_types[eq_idx],
                CASE WHEN v_is_anomaly THEN v_temp_base + 30 + RAND() * 20 
                     ELSE v_temp_base + RAND() * 8 END,
                CASE WHEN v_is_anomaly THEN 5 + RAND() * 3 
                     ELSE 0.5 + RAND() * 1.5 END,
                CASE WHEN v_is_anomaly THEN 8 + RAND() * 4 
                     ELSE 4 + RAND() * 2 END,
                100 + eq_idx * 20 + RAND() * 20,
                1500 + FLOOR(RAND() * 500),
                10000 + i * 5,
                ADD_DAYS(CURRENT_DATE, -30 - FLOOR(RAND() * 60)),
                ADD_DAYS(CURRENT_DATE, 30 + FLOOR(RAND() * 60)),
                CASE WHEN v_is_anomaly THEN 0.85 + RAND() * 0.15 
                     ELSE 0.05 + RAND() * 0.15 END,
                CASE WHEN v_is_anomaly THEN 0.4 + RAND() * 0.4 
                     ELSE 0.02 + RAND() * 0.1 END,
                CASE WHEN v_is_anomaly THEN 'CRITICAL' 
                     WHEN RAND() > 0.8 THEN 'WARNING' 
                     ELSE 'GOOD' END
            );
            
            v_timestamp := ADD_SECONDS(v_timestamp, 3600);  -- 1 hour intervals
        END FOR;
    END FOR;
END;

-- ============================================================================
-- HR Workforce Analytics - 50 employees for clustering & attrition
-- Use cases: Attrition prediction, workforce clustering
-- ============================================================================
DELETE FROM "AINUCLEUS"."HR_WORKFORCE_ANALYTICS";

DO BEGIN
    DECLARE v_departments NVARCHAR(30) ARRAY := ARRAY['Engineering', 'Sales', 'Marketing', 'Operations', 'Finance'];
    DECLARE v_job_families NVARCHAR(30) ARRAY := ARRAY['Technical', 'Sales', 'Marketing', 'Admin', 'Management'];
    DECLARE v_age_ranges NVARCHAR(10) ARRAY := ARRAY['20-29', '30-39', '40-49', '50-59', '60+'];
    DECLARE v_risk_tiers NVARCHAR(10) ARRAY := ARRAY['LOW', 'MEDIUM', 'HIGH'];
    
    FOR i IN 1..50 DO
        INSERT INTO "AINUCLEUS"."HR_WORKFORCE_ANALYTICS" (
            EMPLOYEE_ID, SNAPSHOT_DATE, DEPARTMENT, JOB_FAMILY, TENURE_YEARS,
            AGE_RANGE, PERFORMANCE_RATING, ENGAGEMENT_SCORE, TRAINING_HOURS,
            PROMOTION_COUNT, SALARY_BAND, MANAGER_RATING, ATTRITION_RISK,
            FLIGHT_RISK_TIER, CLUSTER_ID
        ) VALUES (
            'EMP-' || LPAD(TO_VARCHAR(i), 5, '0'),
            CURRENT_DATE,
            :v_departments[1 + MOD(i, 5)],
            :v_job_families[1 + MOD(i, 5)],
            0.5 + RAND() * 15,  -- 0.5-15.5 years tenure
            :v_age_ranges[1 + MOD(i, 5)],
            1 + FLOOR(RAND() * 5),  -- 1-5 rating
            1 + RAND() * 4,         -- 1-5 engagement
            FLOOR(10 + RAND() * 100),  -- 10-110 training hours
            FLOOR(RAND() * 4),      -- 0-3 promotions
            1 + FLOOR(RAND() * 10), -- Salary band 1-10
            1 + RAND() * 4,         -- Manager rating 1-5
            0.05 + RAND() * 0.35,   -- 5-40% attrition risk
            CASE 
                WHEN RAND() < 0.2 THEN 'HIGH'
                WHEN RAND() < 0.5 THEN 'MEDIUM'
                ELSE 'LOW'
            END,
            1 + MOD(i, 4)           -- Cluster 1-4
        );
    END FOR;
END;

-- ============================================================================
-- Verify data counts
-- ============================================================================
SELECT 'ESG_CARBON_EMISSIONS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM "AINUCLEUS"."ESG_CARBON_EMISSIONS"
UNION ALL
SELECT 'FI_REVENUE_ACTUALS', COUNT(*) FROM "AINUCLEUS"."FI_REVENUE_ACTUALS"
UNION ALL
SELECT 'MM_INVENTORY_HISTORY', COUNT(*) FROM "AINUCLEUS"."MM_INVENTORY_HISTORY"
UNION ALL
SELECT 'SD_CUSTOMER_ANALYTICS', COUNT(*) FROM "AINUCLEUS"."SD_CUSTOMER_ANALYTICS"
UNION ALL
SELECT 'PM_EQUIPMENT_TELEMETRY', COUNT(*) FROM "AINUCLEUS"."PM_EQUIPMENT_TELEMETRY"
UNION ALL
SELECT 'HR_WORKFORCE_ANALYTICS', COUNT(*) FROM "AINUCLEUS"."HR_WORKFORCE_ANALYTICS";