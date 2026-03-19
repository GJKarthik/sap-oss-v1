#!/usr/bin/env python3
"""
specialist_data_generator.py

Generates 100K+ training examples for each specialist model:
1. Performance/P&L Specialist (Income Statement)
2. Balance Sheet Specialist (Assets/Liabilities) 
3. Treasury/ALM Specialist (Trade-level)
4. ESG/Carbon Credits Specialist

Based on actual prompt patterns from training data.
"""
from __future__ import annotations

import json
import random
from dataclasses import dataclass, field
from typing import Iterator
from pathlib import Path

from schema_pipeline.massive_term_generator import MassiveTermGenerator
from schema_pipeline.sql_validator import HANASQLValidator


# =============================================================================
# Domain-Specific Schemas
# =============================================================================

# Performance/P&L Domain (BPC)
PERFORMANCE_SCHEMA = {
    "tables": {
        "ZFI_FIN_OVER_AFO_CP_FIN": {
            "description": "BPC Standard Finance Report",
            "columns": ["FISCPER", "FISCYEAR", "ENTITY", "SEGMENT", "PRODUCT", "ACCOUNT", 
                       "FLOW", "ZCUSTOM1", "ZCUSTOM2", "ZCURIDEN", "ZLEDGER", "RTC_AMO"],
        },
        "ZFI_REP01": {
            "description": "BPC Composite Provider for Actuals",
            "columns": ["FISCPER", "ENTITY", "GL_ACCT", "RGROUP", "ZVIEW", "ZCUSTOM6", "RTC_AMO"],
        },
    },
    "dimensions": {
        "period": ["YTD", "QTD", "MTD", "FY", "Q1", "Q2", "Q3", "Q4", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        "years": ["2024", "2025", "2026"],
        "segment": ["CIB", "WRB", "Group", "Ventures", "Central"],
        "sub_segment": ["Corporates", "FI", "Middle Markets", "Local Corporates", "Affluent", "Mass Retail"],
        "product": ["Trade", "Cash", "Markets", "Wealth", "Mortgages", "CASA", "TD", "Cards", "Loans", "Deposits"],
        "entity": ["UK", "HK", "SG", "India", "China", "Korea", "UAE", "US", "Taiwan", "Indonesia", "Malaysia", "Group"],
        "version": ["Actuals", "Budget", "Outlook", "Prior Year"],
        "currency": ["RFX", "CFX", "USD", "LCY"],
    },
    "accounts": {
        "income": ["Total Income", "NII", "NFI", "Trading Income", "Client Income", "Operating Income"],
        "costs": ["Total Costs", "Direct Controllable", "Bonus", "Investments", "TTO Recharges", "GFGCR", "Service Charges"],
        "impairment": ["Credit Impairment", "Other Impairment", "Total Impairment"],
        "profit": ["Operating Profit", "PBT", "Tax", "PAT", "Underlying PBT"],
        "ratios": ["NIM%", "RoTE%", "CIR%", "ETR%", "RoRWA%", "Asset Yield%"],
    },
}

# Balance Sheet Domain
BALANCE_SHEET_SCHEMA = {
    "tables": {
        "FAGLFLEXT": {
            "description": "GL Totals Table",
            "columns": ["RCLNT", "RLDNR", "RBUKRS", "RACCT", "RYEAR", "RPMAX", "HSL", "KSL", "TSL"],
        },
        "SKA1": {
            "description": "GL Account Master",
            "columns": ["KTOPL", "SAKNR", "XBILK", "KTOKS"],
        },
    },
    "dimensions": {
        "period": ["YTD", "QTD", "MTD", "Q1", "Q2", "Q3", "Q4"],
        "entity": ["UK", "HK", "SG", "India", "China", "Korea", "UAE", "US", "Group"],
        "segment": ["CIB", "WRB", "Group"],
    },
    "accounts": {
        "assets": ["Total Assets", "Funded Assets", "Loans & Advances", "L&A to Customers", "PE RWA", "Avg RWA", "Market RWA"],
        "liabilities": ["Total Liabilities", "Customer Deposits", "CASA", "Term Deposits", "Cash Liabilities", "Funding Liabilities"],
        "equity": ["Total Equity", "Retained Earnings", "Reserves"],
        "ratios": ["CASA/TD Ratio", "L&A %", "Leverage", "Funding Gap"],
    },
}

# Treasury/ALM Domain
TREASURY_SCHEMA = {
    "tables": {
        "TREASURY_POSITION": {
            "description": "Treasury positions fact table",
            "columns": ["COB_DATE", "ISIN", "PORTFOLIO", "COUNTRY", "PRODUCT_TYPE", "MODEL", 
                       "NOTIONAL", "MTM", "PV01", "RWA", "CR_DELTA", "BOOK_VALUE",
                       "MATURITY_DATE", "HOLDING_YIELD", "MARKET_YIELD", "COUPON_TYPE"],
        },
        "FX_RATE": {
            "description": "FX rates",
            "columns": ["RATE_DATE", "BASE_CCY", "QUOTE_CCY", "SPOT_RATE"],
        },
    },
    "dimensions": {
        "cob_date": ["most recent", "December 2024", "January 2025", "February 2025", "March 2025", "Q1 2025", "Q4 2024"],
        "country": ["HONG KONG", "UNITED KINGDOM", "SINGAPORE", "INDIA", "CHINA", "KENYA", "NIGERIA", 
                   "UNITED ARAB EMIRATES", "TAIWAN", "GERMANY", "UNITED STATES OF AMERICA"],
        "product": ["Bonds", "IRS", "Issuances"],
        "model": ["FVOCI", "FVTPL", "Amortised Cost", "HTC"],
        "coupon_type": ["Fixed", "Floating"],
        "portfolio": ["UKEHTC", "HKALMSSA", "UKBONDIM", "SGALM"],
    },
    "metrics": ["notional", "MtM", "PV01", "RWA", "CR Delta", "Book Value", 
               "holding yield", "market yield", "weighted average maturity", "weighted average holding yield"],
}

# ESG Domain
ESG_SCHEMA = {
    "tables": {
        "ESG_SF_FLAT": {
            "description": "ESG Sustainable Finance data",
            "columns": ["PERIOD", "BOOKING_LOCATION", "NET_ZERO_SECTOR", "CLIENT_SEGMENT", 
                       "MANAGEMENT_PRODUCT", "FINANCED_EMISSION", "CIB_PE_ASSET", "TOTAL_REVENUE_YTD",
                       "NII_YTD", "NFI_YTD", "EXPOSURE", "RWA"],
        },
        "ZSUS_PAPM_ACTUALS": {
            "description": "Carbon/PAPM Actuals",
            "columns": ["PERIOD", "SCOPE1", "SCOPE2", "SCOPE3", "TOTAL_EMISSION", "INTENSITY"],
        },
    },
    "dimensions": {
        "period": ["Dec 2024", "Jan 2025", "Feb 2025", "Mar 2025", "Sep 2025", "2024", "2025"],
        "booking_location": ["ASEAN", "GCNA", "South Asia", "CHINA", "UNITED KINGDOM", "India"],
        "net_zero_sector": ["OIL AND GAS", "POWER", "AUTOMOTIVE MANUFACTURERS", "CEMENT", "STEEL", "AVIATION"],
        "client_segment": ["Financial Institution", "Global Subsidiaries GC", "Corporates"],
        "management_product": ["Financing Solutions", "Transaction Banking", "Markets"],
        "ultimate_parent_location": ["UNITED KINGDOM", "ASEAN", "GCNA", "India", "China"],
    },
    "metrics": ["financed emission", "CIB PE asset", "total revenue YTD", "NII YTD", "NFI YTD",
               "in-scope exposure", "exposure", "RWA"],
}


# =============================================================================
# Prompt Templates by Specialist
# =============================================================================

PERFORMANCE_TEMPLATES = [
    # Income queries
    {"q": "What is the {period} {year} {account} for {segment}?", "pattern": "simple_metric"},
    {"q": "Show {account} by {dimension} for {period} {year}", "pattern": "group_by"},
    {"q": "What is the YoY% change in {account} for {entity} {segment}?", "pattern": "yoy_comparison"},
    {"q": "Compare {account} {period} {year} vs Budget", "pattern": "vs_budget"},
    {"q": "What percentage does {product} contribute to overall {account}?", "pattern": "contribution"},
    {"q": "Which {dimension} had the highest {account} in {period} {year}?", "pattern": "top_performer"},
    {"q": "Show {account} trend from {year1} to {year2}", "pattern": "trend"},
    {"q": "What is the {segment} {account} split by {dimension} for {period} {year}?", "pattern": "segment_split"},
    {"q": "Calculate {ratio} for {segment} for {period} {year}", "pattern": "ratio"},
    {"q": "What is the {version} {account} for {entity} {period} {year} on {currency} basis?", "pattern": "version_currency"},
    {"q": "Show {account} by Product for {period} {year} with YoY% and vs Budget", "pattern": "multi_comparison"},
    {"q": "What is the run rate for {account} based on {period} {year}?", "pattern": "run_rate"},
]

BALANCE_SHEET_TEMPLATES = [
    {"q": "What is the {period} {year} {account} for {segment}?", "pattern": "simple_metric"},
    {"q": "Show {account} by {entity} for {period} {year}", "pattern": "group_by_entity"},
    {"q": "What is the CASA to TD ratio for {segment} for {period} {year}?", "pattern": "casa_td_ratio"},
    {"q": "Show {period} {year} Balance Sheet for {entity}", "pattern": "full_bs"},
    {"q": "What is the {segment} L&A % for {entity} for {period} {year}?", "pattern": "la_percent"},
    {"q": "Show {account} with YoY% and QoQ% comparison for {period} {year}", "pattern": "yoy_qoq"},
    {"q": "What is the Funding Gap for {segment} for {period} {year}?", "pattern": "funding_gap"},
    {"q": "Compare {account} {period} {year} vs Prior Year", "pattern": "vs_prior_year"},
    {"q": "What is the {account} movement at {entity} level for {period} {year}?", "pattern": "movement"},
]

TREASURY_TEMPLATES = [
    {"q": "Provide total {metric} for ISIN {isin} in {country} country.", "pattern": "isin_metric"},
    {"q": "For {country} country, provide {metric} amount for {product}.", "pattern": "country_product"},
    {"q": "For {country} country, provide {product} with the most negative {metric} for {cob_date} COB date.", "pattern": "extreme_value"},
    {"q": "Provide a list of countries where ISIN {isin} was held.", "pattern": "isin_countries"},
    {"q": "Provide {metric} of {coupon_type} rate {product} in {country} country maturing in {maturity_period}, for {cob_date} COB date.", "pattern": "maturity_filter"},
    {"q": "For {country} country, calculate weighted average {metric} for {product}.", "pattern": "weighted_avg"},
    {"q": "For {product} in {country} country, provide over the period trend of {metric}.", "pattern": "trend"},
    {"q": "What is the month on month {metric} change in {product} held in {country} country for COB {cob_date}?", "pattern": "mom_change"},
    {"q": "For portfolio {portfolio}, calculate weighted average maturity for {product}.", "pattern": "portfolio_wam"},
    {"q": "Provide {metric} and {metric2} amounts for {model} portfolios for COB {cob_date}", "pattern": "model_metrics"},
    {"q": "For {country} country, list {model} {product} {metric} by maturity year and month", "pattern": "maturity_split"},
]

ESG_TEMPLATES = [
    {"q": "{metric} for booking location {location} for {period}", "pattern": "simple_metric"},
    {"q": "{metric} by net zero sector for {location} for {period}", "pattern": "by_sector"},
    {"q": "In-scope exposure for net zero by net-zero sector for {location} for {period}", "pattern": "exposure_by_sector"},
    {"q": "Show Top 10 {dimension} by {metric} for Net Zero Sector {sector} for {period}", "pattern": "top_10"},
    {"q": "Compare {metric} by net zero sector in {period1} versus {period2}", "pattern": "period_compare"},
    {"q": "{metric} for ultimate parent location {location} for net-zero sector {sector} for {period}", "pattern": "parent_location"},
    {"q": "Total revenue YTD by industry and booking location {location} for {period}", "pattern": "revenue_by_industry"},
    {"q": "CIB PE asset for client segment hierarchy {segment} for {period}", "pattern": "client_segment"},
    {"q": "{metric} for net zero by management product hierarchy for {period}", "pattern": "by_product"},
]


# =============================================================================
# SQL Generation Functions
# =============================================================================

def generate_performance_sql(template: dict, params: dict) -> str:
    """Generate Performance/P&L SQL"""
    pattern = template["pattern"]
    
    if pattern == "simple_metric":
        return f"""SELECT SUM(RTC_AMO) AS {params['account'].replace(' ', '_')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND SEGMENT = '{params['segment']}'
  AND ACCOUNT = '{params['account']}'
  AND ZCURIDEN = 'RFX'"""
    
    elif pattern == "group_by":
        return f"""SELECT {params['dimension']}, SUM(RTC_AMO) AS {params['account'].replace(' ', '_')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND ACCOUNT = '{params['account']}'
GROUP BY {params['dimension']}
ORDER BY {params['account'].replace(' ', '_')} DESC"""
    
    elif pattern == "yoy_comparison":
        return f"""SELECT 
    ENTITY,
    SUM(CASE WHEN FISCYEAR = '{params['year']}' THEN RTC_AMO ELSE 0 END) AS current_year,
    SUM(CASE WHEN FISCYEAR = '{int(params['year'])-1}' THEN RTC_AMO ELSE 0 END) AS prior_year,
    ROUND(100.0 * (SUM(CASE WHEN FISCYEAR = '{params['year']}' THEN RTC_AMO ELSE 0 END) - 
                   SUM(CASE WHEN FISCYEAR = '{int(params['year'])-1}' THEN RTC_AMO ELSE 0 END)) / 
          NULLIF(SUM(CASE WHEN FISCYEAR = '{int(params['year'])-1}' THEN RTC_AMO ELSE 0 END), 0), 2) AS yoy_pct
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE ENTITY = '{params['entity']}' 
  AND SEGMENT = '{params['segment']}'
  AND ACCOUNT = '{params['account']}'
GROUP BY ENTITY"""
    
    elif pattern == "contribution":
        return f"""SELECT 
    PRODUCT,
    SUM(RTC_AMO) AS product_amount,
    ROUND(100.0 * SUM(RTC_AMO) / SUM(SUM(RTC_AMO)) OVER(), 2) AS contribution_pct
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND ACCOUNT = '{params['account']}'
GROUP BY PRODUCT
ORDER BY contribution_pct DESC"""
    
    elif pattern == "ratio":
        return f"""SELECT 
    SEGMENT,
    ROUND(100.0 * SUM(CASE WHEN ACCOUNT = 'NII' THEN RTC_AMO ELSE 0 END) / 
          NULLIF(SUM(CASE WHEN ACCOUNT = 'Avg Assets' THEN RTC_AMO ELSE 0 END), 0), 2) AS {params['ratio'].replace('%', '_pct')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND SEGMENT = '{params['segment']}'
GROUP BY SEGMENT"""
    
    elif pattern == "vs_budget":
        return f"""SELECT
    SEGMENT,
    SUM(CASE WHEN FLOW = 'Actuals' THEN RTC_AMO ELSE 0 END) AS actuals,
    SUM(CASE WHEN FLOW = 'Budget' THEN RTC_AMO ELSE 0 END) AS budget,
    SUM(CASE WHEN FLOW = 'Actuals' THEN RTC_AMO ELSE 0 END) - SUM(CASE WHEN FLOW = 'Budget' THEN RTC_AMO ELSE 0 END) AS variance
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND ACCOUNT = '{params['account']}'
  AND SEGMENT = '{params.get('segment', 'CIB')}'
GROUP BY SEGMENT"""

    elif pattern == "top_performer":
        return f"""SELECT TOP 1 {params['dimension']}, SUM(RTC_AMO) AS {params['account'].replace(' ', '_')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND ACCOUNT = '{params['account']}'
GROUP BY {params['dimension']}
ORDER BY {params['account'].replace(' ', '_')} DESC"""

    elif pattern == "trend":
        return f"""SELECT FISCYEAR, SUM(RTC_AMO) AS {params['account'].replace(' ', '_')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCYEAR BETWEEN '{params.get('year1', '2023')}' AND '{params.get('year2', '2025')}'
  AND ACCOUNT = '{params['account']}'
GROUP BY FISCYEAR
ORDER BY FISCYEAR"""

    elif pattern == "segment_split":
        return f"""SELECT {params['dimension']}, SUM(RTC_AMO) AS {params['account'].replace(' ', '_')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND SEGMENT = '{params['segment']}'
  AND ACCOUNT = '{params['account']}'
GROUP BY {params['dimension']}
ORDER BY {params['account'].replace(' ', '_')} DESC"""

    elif pattern == "version_currency":
        return f"""SELECT ENTITY, SUM(RTC_AMO) AS {params['account'].replace(' ', '_')}
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND ENTITY = '{params['entity']}'
  AND ACCOUNT = '{params['account']}'
  AND FLOW = '{params.get('version', 'Actuals')}'
  AND ZCURIDEN = '{params.get('currency', 'RFX')}'
GROUP BY ENTITY"""

    elif pattern == "multi_comparison":
        return f"""SELECT
    PRODUCT,
    SUM(CASE WHEN FLOW = 'Actuals' AND FISCYEAR = '{params['year']}' THEN RTC_AMO ELSE 0 END) AS current_actuals,
    SUM(CASE WHEN FLOW = 'Budget' AND FISCYEAR = '{params['year']}' THEN RTC_AMO ELSE 0 END) AS budget,
    SUM(CASE WHEN FLOW = 'Actuals' AND FISCYEAR = '{int(params['year'])-1}' THEN RTC_AMO ELSE 0 END) AS prior_year
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE ACCOUNT = '{params['account']}'
GROUP BY PRODUCT
ORDER BY current_actuals DESC"""

    elif pattern == "run_rate":
        return f"""SELECT
    SEGMENT,
    SUM(RTC_AMO) AS ytd_amount,
    ROUND(12.0 * SUM(RTC_AMO) / NULLIF(CAST(SUBSTRING('{params['period']}', 2, 1) AS INT) * 3, 0), 2) AS annualized_run_rate
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE FISCPER LIKE '{params['year']}%'
  AND ACCOUNT = '{params['account']}'
GROUP BY SEGMENT"""

    else:
        return f"""SELECT TOP 100 SEGMENT, ACCOUNT, SUM(RTC_AMO) AS total_amount
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE SEGMENT = '{params.get('segment', 'CIB')}'
  AND FISCPER LIKE '{params.get('year', '2025')}%'
GROUP BY SEGMENT, ACCOUNT
ORDER BY total_amount DESC"""


def generate_balance_sheet_sql(template: dict, params: dict) -> str:
    """Generate Balance Sheet SQL"""
    pattern = template["pattern"]
    
    if pattern == "simple_metric":
        return f"""SELECT SUM(HSL) AS {params['account'].replace(' ', '_').replace('&', 'and')}
FROM GL.FAGLFLEXT f
JOIN GL.SKA1 s ON f.RACCT = s.SAKNR
WHERE f.RYEAR = '{params['year']}'
  AND s.XBILK = 'X'
  AND f.SEGMENT = '{params['segment']}'"""
    
    elif pattern == "casa_td_ratio":
        return f"""SELECT 
    SEGMENT,
    SUM(CASE WHEN PRODUCT = 'CASA' THEN HSL ELSE 0 END) AS CASA,
    SUM(CASE WHEN PRODUCT = 'TD' THEN HSL ELSE 0 END) AS TD,
    ROUND(SUM(CASE WHEN PRODUCT = 'CASA' THEN HSL ELSE 0 END) / 
          NULLIF(SUM(CASE WHEN PRODUCT = 'TD' THEN HSL ELSE 0 END), 0), 2) AS CASA_TD_Ratio
FROM GL.FAGLFLEXT
WHERE RYEAR = '{params['year']}'
  AND SEGMENT = '{params['segment']}'
  AND PRODUCT IN ('CASA', 'TD')
GROUP BY SEGMENT"""
    
    elif pattern == "full_bs":
        return f"""SELECT 
    ACCOUNT_TYPE,
    ACCOUNT_NAME,
    SUM(HSL) AS Balance
FROM GL.FAGLFLEXT f
JOIN GL.SKA1 s ON f.RACCT = s.SAKNR
WHERE f.RYEAR = '{params['year']}'
  AND f.RBUKRS = '{params['entity']}'
  AND s.XBILK = 'X'
GROUP BY ACCOUNT_TYPE, ACCOUNT_NAME
ORDER BY ACCOUNT_TYPE, ACCOUNT_NAME"""
    
    elif pattern == "group_by_entity":
        return f"""SELECT f.RBUKRS AS entity, SUM(f.HSL) AS {params['account'].replace(' ', '_').replace('&', 'and')}
FROM GL.FAGLFLEXT f
JOIN GL.SKA1 s ON f.RACCT = s.SAKNR
WHERE f.RYEAR = '{params['year']}'
  AND s.XBILK = 'X'
GROUP BY f.RBUKRS
ORDER BY {params['account'].replace(' ', '_').replace('&', 'and')} DESC"""

    elif pattern == "yoy_qoq":
        return f"""SELECT
    f.RYEAR,
    SUM(f.HSL) AS {params['account'].replace(' ', '_').replace('&', 'and')}
FROM GL.FAGLFLEXT f
JOIN GL.SKA1 s ON f.RACCT = s.SAKNR
WHERE f.RYEAR IN ('{params['year']}', '{int(params['year'])-1}')
  AND s.XBILK = 'X'
GROUP BY f.RYEAR
ORDER BY f.RYEAR"""

    elif pattern == "funding_gap":
        return f"""SELECT
    SEGMENT,
    SUM(CASE WHEN ACCOUNT_TYPE = 'ASSET' THEN HSL ELSE 0 END) AS total_assets,
    SUM(CASE WHEN ACCOUNT_TYPE = 'LIABILITY' THEN HSL ELSE 0 END) AS total_liabilities,
    SUM(CASE WHEN ACCOUNT_TYPE = 'ASSET' THEN HSL ELSE 0 END) - SUM(CASE WHEN ACCOUNT_TYPE = 'LIABILITY' THEN HSL ELSE 0 END) AS funding_gap
FROM GL.FAGLFLEXT
WHERE RYEAR = '{params['year']}'
  AND SEGMENT = '{params['segment']}'
GROUP BY SEGMENT"""

    elif pattern == "vs_prior_year":
        return f"""SELECT
    RYEAR,
    SUM(HSL) AS {params['account'].replace(' ', '_').replace('&', 'and')}
FROM GL.FAGLFLEXT
WHERE RYEAR IN ('{params['year']}', '{int(params['year'])-1}')
  AND SEGMENT = '{params.get('segment', 'Group')}'
GROUP BY RYEAR
ORDER BY RYEAR"""

    elif pattern == "movement":
        return f"""SELECT
    RBUKRS AS entity,
    SUM(CASE WHEN RYEAR = '{params['year']}' THEN HSL ELSE 0 END) AS current_year,
    SUM(CASE WHEN RYEAR = '{int(params['year'])-1}' THEN HSL ELSE 0 END) AS prior_year,
    SUM(CASE WHEN RYEAR = '{params['year']}' THEN HSL ELSE 0 END) - SUM(CASE WHEN RYEAR = '{int(params['year'])-1}' THEN HSL ELSE 0 END) AS movement
FROM GL.FAGLFLEXT
WHERE RBUKRS = '{params.get('entity', 'UK')}'
GROUP BY RBUKRS"""

    elif pattern == "la_percent":
        return f"""SELECT
    SEGMENT,
    SUM(CASE WHEN ACCOUNT_TYPE = 'L_AND_A' THEN HSL ELSE 0 END) AS la_amount,
    SUM(HSL) AS total,
    ROUND(100.0 * SUM(CASE WHEN ACCOUNT_TYPE = 'L_AND_A' THEN HSL ELSE 0 END) / NULLIF(SUM(HSL), 0), 2) AS la_pct
FROM GL.FAGLFLEXT
WHERE RYEAR = '{params['year']}'
  AND SEGMENT = '{params['segment']}'
  AND RBUKRS = '{params.get('entity', 'UK')}'
GROUP BY SEGMENT"""

    else:
        return f"""SELECT TOP 100 SEGMENT, RACCT, SUM(HSL) AS balance
FROM GL.FAGLFLEXT
WHERE SEGMENT = '{params.get('segment', 'Group')}'
  AND RYEAR = '{params.get('year', '2025')}'
GROUP BY SEGMENT, RACCT
ORDER BY balance DESC"""


def generate_treasury_sql(template: dict, params: dict) -> str:
    """Generate Treasury/ALM SQL"""
    pattern = template["pattern"]
    
    if pattern == "isin_metric":
        return f"""SELECT ISIN, COUNTRY, SUM({params['metric'].upper().replace(' ', '_')}) AS total_{params['metric'].replace(' ', '_')}
FROM TREASURY.POSITION
WHERE ISIN = '{params['isin']}'
  AND COUNTRY = '{params['country']}'
  AND COB_DATE = (SELECT MAX(COB_DATE) FROM TREASURY.POSITION)
GROUP BY ISIN, COUNTRY"""
    
    elif pattern == "country_product":
        return f"""SELECT COUNTRY, PRODUCT_TYPE, SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND PRODUCT_TYPE = '{params['product']}'
  AND COB_DATE = (SELECT MAX(COB_DATE) FROM TREASURY.POSITION)
GROUP BY COUNTRY, PRODUCT_TYPE"""
    
    elif pattern == "weighted_avg":
        return f"""SELECT 
    COUNTRY,
    SUM(NOTIONAL) AS total_notional,
    SUM({params['metric'].upper().replace(' ', '_')} * NOTIONAL) / NULLIF(SUM(NOTIONAL), 0) AS weighted_avg_{params['metric'].replace(' ', '_')}
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND PRODUCT_TYPE = '{params['product']}'
GROUP BY COUNTRY"""
    
    elif pattern == "maturity_split":
        return f"""SELECT 
    EXTRACT(YEAR FROM MATURITY_DATE) AS maturity_year,
    EXTRACT(MONTH FROM MATURITY_DATE) AS maturity_month,
    SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND MODEL = '{params['model']}'
  AND PRODUCT_TYPE = '{params['product']}'
GROUP BY EXTRACT(YEAR FROM MATURITY_DATE), EXTRACT(MONTH FROM MATURITY_DATE)
ORDER BY maturity_year, maturity_month"""
    
    elif pattern == "extreme_value":
        return f"""SELECT TOP 1 PRODUCT_TYPE, {params['metric'].upper().replace(' ', '_')}
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND COB_DATE = '{params.get('cob_date', 'most recent')}'
ORDER BY {params['metric'].upper().replace(' ', '_')} ASC"""

    elif pattern == "trend":
        return f"""SELECT COB_DATE, SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND PRODUCT_TYPE = '{params['product']}'
GROUP BY COB_DATE
ORDER BY COB_DATE"""

    elif pattern == "mom_change":
        return f"""SELECT
    COB_DATE,
    SUM({params['metric'].upper().replace(' ', '_')}) AS current_value,
    LAG(SUM({params['metric'].upper().replace(' ', '_')})) OVER (ORDER BY COB_DATE) AS prior_value,
    SUM({params['metric'].upper().replace(' ', '_')}) - LAG(SUM({params['metric'].upper().replace(' ', '_')})) OVER (ORDER BY COB_DATE) AS mom_change
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND PRODUCT_TYPE = '{params['product']}'
GROUP BY COB_DATE
ORDER BY COB_DATE"""

    elif pattern == "portfolio_wam":
        return f"""SELECT
    PORTFOLIO,
    SUM(NOTIONAL) AS total_notional,
    SUM(DAYS_BETWEEN(CURRENT_DATE, MATURITY_DATE) * NOTIONAL) / NULLIF(SUM(NOTIONAL), 0) AS weighted_avg_maturity_days
FROM TREASURY.POSITION
WHERE PORTFOLIO = '{params.get('portfolio', 'UKEHTC')}'
  AND PRODUCT_TYPE = '{params['product']}'
GROUP BY PORTFOLIO"""

    elif pattern == "model_metrics":
        return f"""SELECT MODEL, SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}, SUM({params.get('metric2', 'MTM').upper().replace(' ', '_')}) AS {params.get('metric2', 'MTM').replace(' ', '_')}
FROM TREASURY.POSITION
WHERE MODEL = '{params['model']}'
  AND COB_DATE = '{params.get('cob_date', 'most recent')}'
GROUP BY MODEL"""

    elif pattern == "isin_countries":
        return f"""SELECT DISTINCT COUNTRY
FROM TREASURY.POSITION
WHERE ISIN = '{params['isin']}'
ORDER BY COUNTRY"""

    elif pattern == "maturity_filter":
        return f"""SELECT SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM TREASURY.POSITION
WHERE COUNTRY = '{params['country']}'
  AND COUPON_TYPE = '{params.get('coupon_type', 'Fixed')}'
  AND PRODUCT_TYPE = '{params['product']}'
  AND COB_DATE = '{params.get('cob_date', 'most recent')}'"""

    else:
        return f"""SELECT TOP 100 COUNTRY, PRODUCT_TYPE, SUM(NOTIONAL) AS total_notional
FROM TREASURY.POSITION
WHERE COUNTRY = '{params.get('country', 'HONG KONG')}'
GROUP BY COUNTRY, PRODUCT_TYPE
ORDER BY total_notional DESC"""


def generate_esg_sql(template: dict, params: dict) -> str:
    """Generate ESG SQL"""
    pattern = template["pattern"]
    
    if pattern == "simple_metric":
        return f"""SELECT SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM ESG.SF_FLAT
WHERE BOOKING_LOCATION = '{params['location']}'
  AND PERIOD = '{params['period']}'"""
    
    elif pattern == "by_sector":
        return f"""SELECT NET_ZERO_SECTOR, SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM ESG.SF_FLAT
WHERE BOOKING_LOCATION = '{params['location']}'
  AND PERIOD = '{params['period']}'
GROUP BY NET_ZERO_SECTOR
ORDER BY {params['metric'].replace(' ', '_')} DESC"""
    
    elif pattern == "top_10":
        return f"""SELECT {params['dimension']}, SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM ESG.SF_FLAT
WHERE NET_ZERO_SECTOR = '{params['sector']}'
  AND PERIOD = '{params['period']}'
GROUP BY {params['dimension']}
ORDER BY {params['metric'].replace(' ', '_')} DESC
LIMIT 10"""
    
    elif pattern == "period_compare":
        return f"""SELECT 
    NET_ZERO_SECTOR,
    SUM(CASE WHEN PERIOD = '{params['period1']}' THEN {params['metric'].upper().replace(' ', '_')} ELSE 0 END) AS period1,
    SUM(CASE WHEN PERIOD = '{params['period2']}' THEN {params['metric'].upper().replace(' ', '_')} ELSE 0 END) AS period2,
    SUM(CASE WHEN PERIOD = '{params['period1']}' THEN {params['metric'].upper().replace(' ', '_')} ELSE 0 END) - 
    SUM(CASE WHEN PERIOD = '{params['period2']}' THEN {params['metric'].upper().replace(' ', '_')} ELSE 0 END) AS change
FROM ESG.SF_FLAT
WHERE PERIOD IN ('{params['period1']}', '{params['period2']}')
GROUP BY NET_ZERO_SECTOR"""
    
    elif pattern == "exposure_by_sector":
        return f"""SELECT NET_ZERO_SECTOR, SUM(EXPOSURE) AS in_scope_exposure
FROM ESG.SF_FLAT
WHERE BOOKING_LOCATION = '{params['location']}'
  AND PERIOD = '{params['period']}'
GROUP BY NET_ZERO_SECTOR
ORDER BY in_scope_exposure DESC"""

    elif pattern == "parent_location":
        return f"""SELECT SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM ESG.SF_FLAT
WHERE ULTIMATE_PARENT_LOCATION = '{params.get('location', 'UNITED KINGDOM')}'
  AND NET_ZERO_SECTOR = '{params.get('sector', 'OIL AND GAS')}'
  AND PERIOD = '{params['period']}'"""

    elif pattern == "revenue_by_industry":
        return f"""SELECT NET_ZERO_SECTOR, SUM(TOTAL_REVENUE_YTD) AS total_revenue_ytd
FROM ESG.SF_FLAT
WHERE BOOKING_LOCATION = '{params['location']}'
  AND PERIOD = '{params['period']}'
GROUP BY NET_ZERO_SECTOR
ORDER BY total_revenue_ytd DESC"""

    elif pattern == "client_segment":
        return f"""SELECT CLIENT_SEGMENT, SUM(CIB_PE_ASSET) AS cib_pe_asset
FROM ESG.SF_FLAT
WHERE CLIENT_SEGMENT = '{params.get('segment', 'Financial Institution')}'
  AND PERIOD = '{params['period']}'
GROUP BY CLIENT_SEGMENT"""

    elif pattern == "by_product":
        return f"""SELECT MANAGEMENT_PRODUCT, SUM({params['metric'].upper().replace(' ', '_')}) AS {params['metric'].replace(' ', '_')}
FROM ESG.SF_FLAT
WHERE PERIOD = '{params['period']}'
GROUP BY MANAGEMENT_PRODUCT
ORDER BY {params['metric'].replace(' ', '_')} DESC"""

    else:
        return f"""SELECT TOP 100 NET_ZERO_SECTOR, BOOKING_LOCATION, SUM(EXPOSURE) AS total_exposure
FROM ESG.SF_FLAT
WHERE PERIOD = '{params.get('period', 'Dec 2024')}'
GROUP BY NET_ZERO_SECTOR, BOOKING_LOCATION
ORDER BY total_exposure DESC"""


# =============================================================================
# Generator Class
# =============================================================================

class SpecialistDataGenerator:
    """Generate training data for specialist models."""
    
    def __init__(self, seed: int = 42):
        self.random = random.Random(seed)
        self.sample_isins = ["US91282CGB19", "HK000109253", "GB00BNNGP775", "SG7Q97936509", "XS2577953601"]
    
    def generate_performance_examples(self, count: int = 100000) -> list[dict]:
        """Generate Performance/P&L training examples."""
        examples = []
        schema = PERFORMANCE_SCHEMA
        
        while len(examples) < count:
            template = self.random.choice(PERFORMANCE_TEMPLATES)
            
            params = {
                "period": self.random.choice(schema["dimensions"]["period"]),
                "year": self.random.choice(schema["dimensions"]["years"]),
                "segment": self.random.choice(schema["dimensions"]["segment"]),
                "product": self.random.choice(schema["dimensions"]["product"]),
                "entity": self.random.choice(schema["dimensions"]["entity"]),
                "account": self.random.choice(
                    schema["accounts"]["income"] + schema["accounts"]["costs"] + 
                    schema["accounts"]["impairment"] + schema["accounts"]["profit"]
                ),
                "ratio": self.random.choice(schema["accounts"]["ratios"]),
                "dimension": self.random.choice(["SEGMENT", "PRODUCT", "ENTITY"]),
                "version": self.random.choice(schema["dimensions"]["version"]),
                "currency": self.random.choice(schema["dimensions"]["currency"]),
                "year1": "2023",
                "year2": "2025",
            }
            
            try:
                question = template["q"].format(**params)
                sql = generate_performance_sql(template, params)
                
                examples.append({
                    "id": f"perf_{len(examples)}",
                    "domain": "performance",
                    "question": question,
                    "sql": sql,
                    "type": template["pattern"],
                })
            except (KeyError, ValueError, IndexError):
                continue
        
        return examples[:count]
    
    def generate_balance_sheet_examples(self, count: int = 100000) -> list[dict]:
        """Generate Balance Sheet training examples."""
        examples = []
        schema = BALANCE_SHEET_SCHEMA
        
        while len(examples) < count:
            template = self.random.choice(BALANCE_SHEET_TEMPLATES)
            
            params = {
                "period": self.random.choice(schema["dimensions"]["period"]),
                "year": self.random.choice(["2024", "2025"]),
                "segment": self.random.choice(schema["dimensions"]["segment"]),
                "entity": self.random.choice(schema["dimensions"]["entity"]),
                "account": self.random.choice(
                    schema["accounts"]["assets"] + schema["accounts"]["liabilities"] + schema["accounts"]["ratios"]
                ),
            }
            
            try:
                question = template["q"].format(**params)
                sql = generate_balance_sheet_sql(template, params)
                
                examples.append({
                    "id": f"bs_{len(examples)}",
                    "domain": "balance_sheet",
                    "question": question,
                    "sql": sql,
                    "type": template["pattern"],
                })
            except (KeyError, ValueError, IndexError):
                continue
        
        return examples[:count]
    
    def generate_treasury_examples(self, count: int = 100000) -> list[dict]:
        """Generate Treasury/ALM training examples."""
        examples = []
        schema = TREASURY_SCHEMA
        
        while len(examples) < count:
            template = self.random.choice(TREASURY_TEMPLATES)
            
            params = {
                "country": self.random.choice(schema["dimensions"]["country"]),
                "product": self.random.choice(schema["dimensions"]["product"]),
                "model": self.random.choice(schema["dimensions"]["model"]),
                "metric": self.random.choice(schema["metrics"]),
                "metric2": self.random.choice(schema["metrics"]),
                "cob_date": self.random.choice(schema["dimensions"]["cob_date"]),
                "isin": self.random.choice(self.sample_isins),
                "portfolio": self.random.choice(schema["dimensions"]["portfolio"]),
                "coupon_type": self.random.choice(schema["dimensions"]["coupon_type"]),
                "maturity_period": "August 2025",
            }
            
            try:
                question = template["q"].format(**params)
                sql = generate_treasury_sql(template, params)
                
                examples.append({
                    "id": f"treas_{len(examples)}",
                    "domain": "treasury",
                    "question": question,
                    "sql": sql,
                    "type": template["pattern"],
                })
            except (KeyError, ValueError, IndexError):
                continue
        
        return examples[:count]
    
    def generate_esg_examples(self, count: int = 100000) -> list[dict]:
        """Generate ESG/Carbon training examples."""
        examples = []
        schema = ESG_SCHEMA
        
        while len(examples) < count:
            template = self.random.choice(ESG_TEMPLATES)
            
            params = {
                "period": self.random.choice(schema["dimensions"]["period"]),
                "period1": "Dec 2024",
                "period2": "Dec 2023",
                "location": self.random.choice(schema["dimensions"]["booking_location"]),
                "sector": self.random.choice(schema["dimensions"]["net_zero_sector"]),
                "segment": self.random.choice(schema["dimensions"]["client_segment"]),
                "metric": self.random.choice(schema["metrics"]),
                "dimension": self.random.choice(["BOOKING_LOCATION", "ULTIMATE_PARENT_LOCATION", "CLIENT_NAME"]),
            }
            
            try:
                question = template["q"].format(**params)
                sql = generate_esg_sql(template, params)
                
                examples.append({
                    "id": f"esg_{len(examples)}",
                    "domain": "esg",
                    "question": question,
                    "sql": sql,
                    "type": template["pattern"],
                })
            except (KeyError, ValueError, IndexError):
                continue
        
        return examples[:count]
    
    def generate_router_examples(self, count: int = 50000) -> list[dict]:
        """Generate router classification examples."""
        examples = []
        
        # Sample from each specialist
        perf_sample = self.generate_performance_examples(count // 4)
        bs_sample = self.generate_balance_sheet_examples(count // 4)
        treas_sample = self.generate_treasury_examples(count // 4)
        esg_sample = self.generate_esg_examples(count // 4)
        
        for ex in perf_sample:
            examples.append({"question": ex["question"], "label": "performance", "id": f"router_{len(examples)}"})
        for ex in bs_sample:
            examples.append({"question": ex["question"], "label": "balance_sheet", "id": f"router_{len(examples)}"})
        for ex in treas_sample:
            examples.append({"question": ex["question"], "label": "treasury", "id": f"router_{len(examples)}"})
        for ex in esg_sample:
            examples.append({"question": ex["question"], "label": "esg", "id": f"router_{len(examples)}"})
        
        self.random.shuffle(examples)
        return examples[:count]


def generate_all_specialist_data(output_dir: str = "data/specialist_training", examples_per_specialist: int = 100000):
    """Generate training data for all specialists."""
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    generator = SpecialistDataGenerator()
    
    print("Generating specialist training data...")
    
    # Generate each specialist's data
    specialists = [
        ("performance", generator.generate_performance_examples),
        ("balance_sheet", generator.generate_balance_sheet_examples),
        ("treasury", generator.generate_treasury_examples),
        ("esg", generator.generate_esg_examples),
    ]
    
    sanitizer = MassiveTermGenerator()
    validator = HANASQLValidator(strict=False)

    total = 0
    for name, gen_func in specialists:
        print(f"  Generating {examples_per_specialist} examples for {name}...")
        data = gen_func(examples_per_specialist)

        # Sanitize and validate SQL
        clean_data = []
        invalid_count = 0
        for ex in data:
            sql = ex.get("sql", "")
            if sql:
                ex["sql"] = sanitizer._sanitize_sql(sql)
                report = validator.validate(ex["sql"])
                if not report.is_valid:
                    invalid_count += 1
                    continue
            clean_data.append(ex)

        output_file = output_path / f"train_{name}.json"
        with open(output_file, "w") as f:
            json.dump(clean_data, f, indent=2)

        print(f"    Saved {len(clean_data)} examples to {output_file}"
              f" (removed {invalid_count} invalid)")
        total += len(clean_data)
    
    # Generate router data
    print(f"  Generating router classification examples...")
    router_data = generator.generate_router_examples(50000)
    router_file = output_path / "train_router.json"
    with open(router_file, "w") as f:
        json.dump(router_data, f, indent=2)
    print(f"    Saved {len(router_data)} examples to {router_file}")
    
    print(f"\nTotal: {total + len(router_data)} examples generated")
    return total + len(router_data)


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="data/specialist_training")
    parser.add_argument("--examples", type=int, default=100000)
    args = parser.parse_args()
    
    generate_all_specialist_data(args.output_dir, args.examples)