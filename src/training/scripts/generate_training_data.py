#!/usr/bin/env python3
"""
Generate Qwen 3.5 Training Data from ODPS 4.1 Data Products

Step 1: Generate SQL ground truth for all prompt samples
Step 2: Format as instruction-tuning JSONL
Step 3: Augment with synthetic examples
Step 4: Output ready for nvidia-modelopt LoRA fine-tuning

Uses field mappings from data_products/ YAML and real HANA metadata from data/ XLSX.
"""

import json
import os
import random
import hashlib
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from datetime import datetime

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "training_output"

# =============================================================================
# HANA Schema Context (from ODPS 4.1 data products)
# =============================================================================

TREASURY_SCHEMA = """-- Treasury Capital Markets (STG_BCRS)
-- Dimensions:
--   GLB_ASSET_CLASS_2       NVARCHAR  "Asset Class" (security product type)
--   GLB_COUPON_TYPE         NVARCHAR  "Coupon Type" (FIXED, FLOATING, ZERO COUPON, etc.)
--   GLB_CUSIP               NVARCHAR  "CUSIP" (security ID)
--   GLB_INSTRUMENT          NVARCHAR  "Instrument" (Bloomberg ticker)
--   GLB_ISIN                NVARCHAR  "ISIN" (International Securities ID)
--   GLB_FINAL_CCY           NVARCHAR  "Currency"
--   GLB_FINAL_COUNTRY_NAME  NVARCHAR  "Country" (booking country)
--   GLB_FV_HTC              NVARCHAR  "Accounting Treatment" (FVOCI or HTC)
--   GLB_GLOBAL_REGION       NVARCHAR  "Region"
--   GLB_HIGH_LVL_STRATEGY   NVARCHAR  "Strategy" (portfolio purpose)
--   GLB_HQLA                NVARCHAR  "HQLA" (High Quality Liquid Assets)
--   GLB_INDEX_NAME           NVARCHAR  "Reference Index" (benchmark)
--   GLB_ISSUE_RATING_SP     NVARCHAR  "S&P Rating"
--   GLB_ISSUER_NAME         NVARCHAR  "Issuer Name"
--   GLB_MAP_PORTFOLIO       NVARCHAR  "Portfolio"
--   GLB_PRODUCT_SUBTYPE     NVARCHAR  "Product Subtype" (BOND or ISSUANCE)
--   GLB_SOLO_SUB            NVARCHAR  "Solo/Sub"
-- Dates:
--   GLB_REPORT_DATE         DATE      "Report Date" (CoB date)
--   GLB_MATURITY_DATE       DATE      "Maturity Date"
--   GLB_LAST_RESET_DATE     DATE      "Last Reset Date" (floating bonds)
-- Measures (all DECIMAL, USD):
--   GLB_MTM_USD             "Mark-to-Market" (aliases: MtM, MTM)
--   GLB_NOTIONAL_USD        "Notional" (aliases: notional, nominal)
--   GLB_RWA                 "Risk-Weighted Assets"
--   GLB_BOOK_VALUE_USD      "Book Value"
--   GLB_MARKET_VALUE_USD    "Market Value"
--   GLB_MARKET_YIELD        "Market Yield"
--   GLB_IR_PV01_TOTAL       "PV01"
--   GLB_CR_DELTA_TOTAL      "CR Delta" (alias: CR01)
--   GLB_ASW_DM              "ASW/Discount Margin"
--   GLB_BOOK_PRICE          "Book Price"
--   GLB_MARKET_PRICE        "Market Price"
--   GLB_YIELD_IMPACT        "Holding Yield"
"""

TREASURY_TABLE = '"STG_BCRS"."TREASURY_POSITIONS"'

# Business term -> technical column mapping
METRIC_MAP = {
    "mtm": "GLB_MTM_USD", "MtM": "GLB_MTM_USD", "MTM": "GLB_MTM_USD",
    "mark to market": "GLB_MTM_USD", "Mark-to-Market": "GLB_MTM_USD",
    "notional": "GLB_NOTIONAL_USD", "Bond notional": "GLB_NOTIONAL_USD",
    "nominal": "GLB_NOTIONAL_USD",
    "rwa": "GLB_RWA", "RWA": "GLB_RWA", "risk weighted assets": "GLB_RWA",
    "book value": "GLB_BOOK_VALUE_USD", "Book Value": "GLB_BOOK_VALUE_USD",
    "market value": "GLB_MARKET_VALUE_USD",
    "pv01": "GLB_IR_PV01_TOTAL", "PV01": "GLB_IR_PV01_TOTAL",
    "cr delta": "GLB_CR_DELTA_TOTAL", "CR Delta": "GLB_CR_DELTA_TOTAL",
    "cr01": "GLB_CR_DELTA_TOTAL",
    "holding yield": "GLB_YIELD_IMPACT", "Holding Yield": "GLB_YIELD_IMPACT",
    "market yield": "GLB_MARKET_YIELD", "Market Yield": "GLB_MARKET_YIELD",
    "asw": "GLB_ASW_DM", "discount margin": "GLB_ASW_DM",
    "book price": "GLB_BOOK_PRICE", "market price": "GLB_MARKET_PRICE",
}

COUNTRY_MAP = {
    "US": "UNITED STATES OF AMERICA", "UK": "UNITED KINGDOM",
    "UAE": "UNITED ARAB EMIRATES", "HK": "HONG KONG",
    "HONG KONG": "HONG KONG", "INDIA": "INDIA", "CHINA": "CHINA",
    "SINGAPORE": "SINGAPORE", "TAIWAN": "TAIWAN", "KENYA": "KENYA",
    "GERMANY": "GERMANY", "NIGERIA": "NIGERIA",
    "UNITED STATES OF AMERICA": "UNITED STATES OF AMERICA",
    "UNITED KINGDOM": "UNITED KINGDOM",
    "UNITED ARAB EMIRATES": "UNITED ARAB EMIRATES",
}

ATTRIBUTE_MAP = {
    "securities type": "GLB_ASSET_CLASS_2",
    "asset class": "GLB_ASSET_CLASS_2",
    "currency": "GLB_FINAL_CCY",
    "issuer name": "GLB_ISSUER_NAME",
    "issuer": "GLB_ISSUER_NAME",
    "portfolio": "GLB_MAP_PORTFOLIO",
    "rating": "GLB_ISSUE_RATING_SP",
    "HQLA category": "GLB_HQLA",
    "coupon type": "GLB_COUPON_TYPE",
    "strategy": "GLB_HIGH_LVL_STRATEGY",
    "region": "GLB_GLOBAL_REGION",
}

TREASURY_COUNTRIES = [
    "CHINA", "HONG KONG", "INDIA", "SINGAPORE", "TAIWAN",
    "UNITED ARAB EMIRATES", "UNITED KINGDOM", "UNITED STATES OF AMERICA"

# =============================================================================
# ESG Schema Context
# =============================================================================

ESG_SCHEMA = """-- ESG & Sustainability Models
-- Net Zero Model:
--   ASSID           "Asset ID"           | ASSNAME        "Asset Name"
--   ASSTY           "Asset Type"         | DD_SEC         "Net Zero Sector"
--   CALMONTH        "Period"             | CLGRD          "NZ Alignment Grading"
--   BEBOOKINGLOCID  "Booking Location"   | C_SSEG_ID      "Client Segment Hierarchy"
--   FoL_Location    "Revised FAM Location"
--   Management_Prod_Hier "Management Product Hierarchy"
--   VAL_CH          "Value Chain Sector"  | VCSCOPE        "Value Chain Client Level"
--   ATT_EMI  DECIMAL "Financed Emission"  (aliases: financed emission, emission)
--   PE_ASS   DECIMAL "Exposure"           (aliases: cib pe asset, exposure)
--   EMIINTAL DECIMAL "Asset Intensity"
--   RWAASSTR DECIMAL "RWA"               | TRYTDTR DECIMAL "Revenue"
--   RAHDR    DECIMAL "Risk Appetite Headroom"
--   PCAF_S12_SC     "PCAF Score S1&2"    | PCAFS3SC       "PCAF Score S3"
--   EMI_INTENSITY   "Physical Intensity"  | EVIC           "EVIC"
--   ATTR_FACTOR     "Attribution Factor"
--   ATT_PROD        "Attributed Production"
--   FEMISSSION_S12  "Financed Emission S1&2"
--   F_EMISSION_S3   "Financed Emission S3"
-- Integrated Client Model:
--   CIB_PE_ASSETS       "CIB PE Asset"
--   CIB_TOTAL_REVENUE_YTD "CIB Total Revenue YTD"
--   CIB_RWA             "CIB RWA"
--   CARB_IMP_PE_ASSETS  "In-scope Exposure for Net Zero"
--   FIN_EMISSIONS       "Financed Emission"
--   NET_ZERO_SEC        "Net-Zero Sector"
--   FBE_Location        "Booking Location"
--   CLIENT_SUB_SEGEMNT_ID "Client Segment Hierarchy"
--   Period_Date         "Period"
-- Sustainable Finance Model:
--   PE_Assets           "SF PE Asset"
--   Total_Revenue_YTD   "Total Revenue YTD"
--   RWA                 "RWA"
--   PUREPLAY            "Pureplay"
--   SF_Category         "SF Category"
--   SUSTAINABLE_FLAG    "Sustainable Flag"
--   Strategic_Pillar    "Strategic Pillar"
--   Industry            "Industry"
"""

ESG_NZ_TABLE = '"ESG"."NET_ZERO_MODEL"'
ESG_CLIENT_TABLE = '"ESG"."INTEGRATED_CLIENT"'
ESG_SF_TABLE = '"ESG"."SUSTAINABLE_FINANCE"'

ESG_MEASURE_MAP = {
    "financed emission": "ATT_EMI", "emission": "ATT_EMI",
    "cib pe asset": "CIB_PE_ASSETS", "cib assets": "CIB_PE_ASSETS",
    "exposure": "PE_ASS", "in-scope exposure for net zero": "CARB_IMP_PE_ASSETS",
    "in-scope exposure": "CARB_IMP_PE_ASSETS",
    "cib total revenue ytd": "CIB_TOTAL_REVENUE_YTD",
    "rwa": "RWAASSTR", "RWA": "RWAASSTR",
    "total revenue ytd": "Total_Revenue_YTD",
    "total revenue mtd": "Total_Revenue_MTD",
    "pe assets": "PE_Assets", "PE assets": "PE_Assets",
    "nii ytd": "NII_YTD", "nfi ytd": "NFI_YTD",
    "nii mtd": "NII_MTD", "nfi mtd": "NFI_MTD",
}

ESG_DIM_MAP = {
    "net-zero sector": "DD_SEC", "net zero sector": "DD_SEC",
    "booking location": "BEBOOKINGLOCID",
    "revised fam location": "FoL_Location",
    "ultimate parent location": "UPL_Location",
    "client segment hierarchy": "C_SSEG_ID",
    "management product hierarchy": "Management_Prod_Hier",
    "industry": "Industry",
    "client group name": "Client_Group_Name",
    "client name": "Client_Name",
}

ESG_LOCATIONS = ["ASEAN", "GCNA", "CHINA", "SOUTH ASIA", "INDIA", "UNITED KINGDOM"]
ESG_SECTORS = ["OIL AND GAS", "POWER", "AUTOMOTIVE MANUFACTURERS", "STEEL", "CEMENT"]
ESG_PERIODS = ["dec 2024", "dec 2023", "sep 2025", "april 2024", "feb 2025"]

# =============================================================================
# BPC/Performance Schema Context
# =============================================================================

BPC_SCHEMA = """-- Performance BPC (Star Schema)
-- Fact Table: CRD_FACT
--   PERIOD_DATE     DATE    "Reporting Date"
--   MEMO_FLAG       NVARCHAR "Memo/Balance indicator"
--   REPORTING       NVARCHAR "Business view" (Corporate, CIB, WRB, FPNA)
--   VERSION         NVARCHAR "MTD or YTD"
--   SOLOSUB         NVARCHAR "Solo/Subsidiaries"
--   BOOKS           NVARCHAR "Actual, Budget, Forecast, AOP"
--   ACCOUNT         FK → NFRP_Account_AM  (L0→L5 hierarchy)
--   PRODUCT         FK → NFRP_Product_AM  (L0→L4 hierarchy)
--   SEGMENT         FK → NFRP_Segment_AM  (M_SEGMENT_0→4)
--   LOCATION_PK     FK → NFRP_Location_AM (L0→L6 hierarchy)
--   COST_CLUSTER_PK FK → NFRP_Cost_AM     (L0→L5 hierarchy)
--   MONTH, YEAR, MONTH_ABR, MONTH_NUM  (temporal)
--   "Respective Currency"  DECIMAL (measures at spot FX)
--   "Constant Currency"    DECIMAL (historical at reported FX)
--   "Forward Currency"     DECIMAL (projected at forward FX)
-- Dimension: NFRP_Account_AM (1090 rows, L0-L5)
--   L0: Income, Total Cost, Capital, Non-Group Assets...
--   L1: Funded Assets, Incurred Cost, Staff Bonus...
--   ACCOUNT_CRD_INDICATOR: CIB, WRB, FPNA, MOH
-- Dimension: NFRP_Location_AM (1605 rows, L0-L6)
--   L0: AFRICA, ASEAN, CHINA, GCNA, EUROPE...
-- Dimension: NFRP_Product_AM (877 rows, L0-L4)
--   L0: Wealth, Markets, Trade...
-- Dimension: NFRP_Segment_AM (44 rows, M_SEGMENT_0-4)
--   M_SEGMENT_0: CIB, WRB, MOH, FPNA
-- Dimension: NFRP_Cost_AM (1509 rows, L0-L5)
"""

BPC_FACT_TABLE = '"PERFORMANCE"."CRD_FACT"'

BPC_ACCOUNT_MAP = {
    "income": ("NFRP_Account_AM", "L0", "Income"),
    "total cost": ("NFRP_Account_AM", "L0", "Total Cost"),
    "credit impairment": ("NFRP_Account_AM", "L2", "Credit Impairment"),
    "other impairment": ("NFRP_Account_AM", "L2", "Other Impairment"),
    "operating income": ("NFRP_Account_AM", "L1", "Operating Income"),
    "operating profit": ("NFRP_Account_AM", "L1", "Operating Profit"),
    "deposits": ("NFRP_Account_AM", "L1", "Deposits"),
    "loans and advances": ("NFRP_Account_AM", "L1", "Loans and Advances"),
    "l&a": ("NFRP_Account_AM", "L1", "Loans and Advances"),
    "assets": ("NFRP_Account_AM", "L0", "Assets"),
    "liabilities": ("NFRP_Account_AM", "L0", "Liabilities"),
    "market rwa": ("NFRP_Account_AM", "L2", "Market RWA"),
    "mrwa": ("NFRP_Account_AM", "L2", "Market RWA"),
    "headcount": ("NFRP_Account_AM", "L2", "Headcount"),
    "rote": ("NFRP_Account_AM", "L2", "RoTE"),
    "nim": ("NFRP_Account_AM", "L2", "NIM"),
    "funded assets": ("NFRP_Account_AM", "L1", "Funded Assets"),
    "funding gap": ("NFRP_Account_AM", "L2", "Funding Gap"),
    "tax": ("NFRP_Account_AM", "L2", "Tax"),
    "pbt": ("NFRP_Account_AM", "L2", "PBT"),
}

BPC_PRODUCT_MAP = {
    "wealth": ("NFRP_Product_AM", "L0", "Wealth"),
    "markets": ("NFRP_Product_AM", "L0", "Markets"),
    "trade": ("NFRP_Product_AM", "L0", "Trade"),
    "cash": ("NFRP_Product_AM", "L1", "Cash"),
    "casa": ("NFRP_Product_AM", "L1", "CASA"),
    "td": ("NFRP_Product_AM", "L1", "TD"),
}

BPC_SEGMENT_MAP = {
    "cib": ("NFRP_Segment_AM", "M_SEGMENT_0", "CIB"),
    "wrb": ("NFRP_Segment_AM", "M_SEGMENT_0", "WRB"),
    "group": ("NFRP_Segment_AM", "M_SEGMENT_0", None),  # all
    "corporates": ("NFRP_Segment_AM", "M_SEGMENT_1", "Corporates"),
    "fi": ("NFRP_Segment_AM", "M_SEGMENT_1", "Financial Institutions"),
    "local corporates": ("NFRP_Segment_AM", "M_SEGMENT_2", "Local Corporates"),
    "middle markets": ("NFRP_Segment_AM", "M_SEGMENT_2", "Middle Markets"),
    "affluent": ("NFRP_Segment_AM", "M_SEGMENT_1", "Affluent"),
}

BPC_LOCATIONS = {
    "india": "India", "china": "China", "korea": "Korea",
    "singapore": "Singapore", "hk": "Hong Kong", "sg": "Singapore",
    "uae": "UAE", "uk": "United Kingdom", "us": "United States",
    "nigeria": "Nigeria", "kenya": "Kenya",
}

]

TREASURY_DATES = ["2024-12-31", "2025-01-31", "2025-02-28", "2025-03-31", "2025-04-22"]

SAMPLE_ISINS = [
    "US91282CGB19", "HK000109253", "XS2345678901", "UST10Y2025",
    "SG1234567890", "IN0987654321", "TW2468013579", "AE1357924680",
]

