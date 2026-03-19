#!/usr/bin/env python3
"""
Massive Semantic Term Generator for Text-to-SQL Training.

Generates 8-10x more semantic terms than model parameters.
Target: 
- Qwen2.5-0.5B: 4-5 billion token training examples
- Qwen2.5-7B: 56-70 billion token training examples  
- Qwen2.5-14B: 112-140 billion token training examples

Strategy:
1. Expand base terms with synonyms, acronyms, variations
2. Generate all permutations of question patterns
3. Add temporal variations (dates, periods, quarters)
4. Add dimensional variations (segments, regions, entities)
5. Add aggregation variations (sum, avg, count, min, max)
6. Add comparison variations (vs, compared to, difference)
7. Add trend variations (growth, change, delta)
8. Generate cross-domain combinations
"""

import json
import re
import random
import itertools
from pathlib import Path
from typing import Dict, List, Set, Tuple, Optional
from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib


# =============================================================================
# =============================================================================
# SEMANTIC ROUTING CONTEXTS
# Each training example is tagged with a context + system_prompt so the model
# learns to route UI analytics queries to endpoint tables vs pipeline/OData
# queries to lineage/staging tables.
# =============================================================================

ROUTING_CONTEXTS = {
    "analytics_ui": {
        "description": "End-user analytics via dashboards/UI — queries endpoint tables only",
        "system_prompts": {
            "performance": (
                "You are a financial performance analytics assistant for HANA BPC data. "
                "You help users query income, cost, RWA, and balance sheet metrics across "
                "business segments, products, locations, and cost centres. Use the CRD "
                "fact table joined with NFRP dimension hierarchies. Understand hierarchy "
                "levels (L0=broadest to L5=most granular). All data is confidential."
            ),
            "esg": (
                "You are an ESG analytics assistant for HANA. You help users query "
                "Net Zero emissions, client exposures, and sustainable finance metrics. "
                "Translate business terms to technical column names using the field "
                "mappings. All data is enterprise confidential."
            ),
            "treasury": (
                "You are a Treasury analytics assistant for HANA. You help users query "
                "bond and issuance positions. Use the field mappings below to translate "
                "business terms to technical column names. All data is enterprise "
                "confidential - use on-premise LLM only."
            ),
            "default": (
                "You are a financial analytics assistant for SAP HANA. You translate "
                "natural language questions into SQL queries against the bank's analytics "
                "tables. Return only valid SAP HANA SQL. All data is confidential."
            ),
        },
    },
    "data_quality": {
        "description": "Data engineers examining field lineage, completeness, and validation via OData/APIs",
        "system_prompts": {
            "default": (
                "You are a data quality assistant for the bank's SAP BTP data platform. "
                "You help data engineers inspect field-level lineage from source systems "
                "to BTP staging tables, check field completeness, review validation rules, "
                "and trace data transformations. Query the DATA_LINEAGE_CATALOG and "
                "DATA_VALIDATION_RULES tables. All metadata is enterprise confidential."
            ),
        },
    },
    "pipeline_ops": {
        "description": "Data operations examining the full ingestion pipeline across source systems",
        "system_prompts": {
            "default": (
                "You are a data pipeline operations assistant for the bank's data platform. "
                "You help ops teams monitor data ingestion pipelines, check source system "
                "registrations, validate staging schema mappings, and audit data flows "
                "from BCRS, BPC, S4_GL and FPSL into BTP. Query the pipeline metadata "
                "catalog tables. All pipeline data is confidential."
            ),
        },
    },
}

# Domain-to-routing-context mapping for existing synthetic examples
DOMAIN_TO_CONTEXT = {
    "performance": "analytics_ui",
    "balance_sheet": "analytics_ui",
    "treasury": "analytics_ui",
    "risk": "analytics_ui",
    "esg": "analytics_ui",
    "regulatory": "analytics_ui",
    "trade_finance": "analytics_ui",
    "wealth": "analytics_ui",
    "consumer": "analytics_ui",
    "schema": "data_quality",
    "staging": "data_quality",
}

# COMPREHENSIVE BANKING DOMAIN TERMS
# =============================================================================

FINANCIAL_TERMS = {
    # =========================================================================
    # P&L / Income Statement
    # =========================================================================
    "revenue": [
        "revenue", "income", "earnings", "proceeds", "sales", "turnover",
        "gross income", "total income", "net sales", "operating revenue",
        "business revenue", "operating income", "top line", "receipts",
        "revenue stream", "income stream", "total revenue", "gross revenue",
    ],
    "expense": [
        "expense", "cost", "expenditure", "outlay", "spending", "disbursement",
        "operating expense", "opex", "operating cost", "running cost",
        "overhead", "overhead cost", "administrative expense", "admin cost",
        "total costs", "direct cost", "indirect cost", "controllable cost",
    ],
    "profit": [
        "profit", "earnings", "net income", "net profit", "bottom line",
        "net earnings", "surplus", "gain", "return", "proceeds",
        "operating profit", "ebit", "ebitda", "gross profit", "pre-tax profit",
        "pbt", "pat", "profit after tax", "underlying profit",
    ],
    "margin": [
        "margin", "profit margin", "gross margin", "net margin", "spread",
        "operating margin", "ebitda margin", "contribution margin",
        "interest margin", "trading margin", "yield spread", "basis points spread",
    ],
    "nii": [
        "nii", "net interest income", "interest income", "interest revenue",
        "net interest", "interest earnings", "lending income",
        "interest earned", "loan interest income", "deposit spread income",
    ],
    "nim": [
        "nim", "net interest margin", "interest margin", "spread",
        "interest rate spread", "lending margin", "asset yield",
        "funding cost", "cost of funds", "yield on assets",
    ],
    "fee_income": [
        "fee income", "fee revenue", "commission income", "service fees",
        "non-interest income", "fee-based income", "commission revenue",
        "advisory fees", "underwriting fees", "transaction fees", "nfi",
    ],
    "trading_income": [
        "trading income", "trading revenue", "trading profit", "trading pnl",
        "client income", "markets revenue", "sales and trading",
        "proprietary trading", "flow trading income", "dealing income",
    ],
    "impairment": [
        "impairment", "credit impairment", "loan impairment", "asset impairment",
        "impairment charge", "write-down", "write-off", "provision charge",
        "impairment loss", "credit loss charge", "stage 3 impairment",
    ],
    "cost_income_ratio": [
        "cost income ratio", "cir", "efficiency ratio", "cost to income",
        "operating efficiency", "cost efficiency ratio", "expense ratio",
    ],
    "roe": [
        "roe", "return on equity", "return on capital", "rote",
        "return on tangible equity", "equity return", "capital return",
        "rorwa", "return on risk weighted assets", "rorc",
    ],
    "dividend": [
        "dividend", "dividend per share", "dps", "dividend yield",
        "payout ratio", "dividend payout", "interim dividend", "final dividend",
        "total dividend", "shareholder distribution", "buyback",
    ],
    "eps": [
        "eps", "earnings per share", "diluted eps", "basic eps",
        "underlying eps", "adjusted eps", "normalised eps",
    ],

    # =========================================================================
    # Balance Sheet
    # =========================================================================
    "assets": [
        "assets", "total assets", "asset base", "holdings", "resources",
        "properties", "investments", "portfolio", "asset value",
        "funded assets", "earning assets", "interest earning assets",
        "tangible assets", "intangible assets", "fixed assets",
    ],
    "liabilities": [
        "liabilities", "total liabilities", "obligations", "debts",
        "payables", "borrowings", "debt obligations",
        "funding liabilities", "wholesale funding", "interbank borrowing",
        "subordinated debt", "senior unsecured debt", "total funding",
    ],
    "equity": [
        "equity", "shareholders equity", "stockholders equity", "net worth",
        "capital", "book value", "net assets", "shareholders funds",
        "retained earnings", "reserves", "other comprehensive income",
        "tangible book value", "nav", "net asset value",
    ],
    "deposits": [
        "deposits", "customer deposits", "bank deposits", "total deposits",
        "savings deposits", "term deposits", "demand deposits", "fd", "fixed deposit",
        "time deposits", "call deposits", "notice deposits", "escrow deposits",
        "retail deposits", "wholesale deposits", "corporate deposits",
    ],
    "loans": [
        "loans", "advances", "credit", "lending", "loan book",
        "gross loans", "net loans", "loan portfolio", "credit portfolio",
        "outstanding loans", "loan balance", "credit facilities",
        "committed facilities", "drawn facilities", "undrawn commitments",
    ],
    "casa": [
        "casa", "current account savings account", "low-cost deposits",
        "demand deposits", "transaction deposits", "casa ratio",
        "casa balance", "savings balance", "current account balance",
    ],
    "npl": [
        "npl", "non-performing loans", "bad loans", "impaired loans",
        "delinquent loans", "problem loans", "doubtful loans",
        "npl ratio", "npa", "non-performing assets", "stage 3 loans",
        "past due loans", "defaulted loans", "watchlist loans",
    ],
    "goodwill": [
        "goodwill", "intangible assets", "brand value", "acquisition premium",
        "goodwill impairment", "other intangibles",
    ],
    "provisions": [
        "provisions", "loan loss provisions", "allowance for credit losses",
        "provision coverage", "provision ratio", "coverage ratio",
        "stage 1 provision", "stage 2 provision", "stage 3 provision",
        "collective provision", "specific provision", "general provision",
    ],

    # =========================================================================
    # Treasury / ALM / Markets
    # =========================================================================
    "forex": [
        "forex", "fx", "foreign exchange", "currency", "fx trading",
        "currency trading", "fx position", "currency position",
        "spot fx", "forward fx", "fx forward", "ndf", "fx swap",
    ],
    "derivatives": [
        "derivatives", "derivative instruments", "financial derivatives",
        "derivative products", "structured products",
        "otc derivatives", "exchange traded derivatives", "exotic derivatives",
        "derivative notional", "derivative fair value",
    ],
    "swaps": [
        "swaps", "interest rate swaps", "irs", "fx swaps", "currency swaps",
        "cross-currency swaps", "ccs", "basis swaps",
        "overnight index swap", "ois", "total return swap", "trs",
    ],
    "options": [
        "options", "fx options", "currency options", "caps", "floors",
        "collars", "swaptions", "exotic options",
        "barrier options", "digital options", "vanilla options",
    ],
    "bonds": [
        "bonds", "fixed income", "debt securities", "government bonds",
        "corporate bonds", "treasury bonds", "sovereign bonds",
        "agency bonds", "municipal bonds", "high yield bonds",
        "investment grade bonds", "green bonds", "sukuk",
    ],
    "mtm": [
        "mtm", "mark to market", "fair value", "market value",
        "mark-to-market value", "current market value",
        "unrealised pnl", "unrealised gain loss", "fv adjustment",
    ],
    "hedge": [
        "hedge", "hedging", "hedge position", "risk hedge",
        "interest rate hedge", "fx hedge", "currency hedge",
        "hedge effectiveness", "hedge ratio", "macro hedge", "micro hedge",
    ],
    "pv01": [
        "pv01", "dv01", "dollar duration", "basis point value",
        "bpv", "interest rate sensitivity", "rate sensitivity",
        "duration", "modified duration", "effective duration",
    ],
    "ftp": [
        "ftp", "funds transfer pricing", "transfer price",
        "internal funding rate", "matched maturity funding",
        "ftp charge", "ftp credit", "liquidity premium",
        "term premium", "credit spread premium",
    ],
    "alm": [
        "alm", "asset liability management", "asset liability mismatch",
        "gap analysis", "maturity gap", "repricing gap",
        "duration gap", "liquidity gap", "funding gap",
        "structural interest rate risk", "banking book risk",
    ],
    "irrbb": [
        "irrbb", "interest rate risk in the banking book",
        "banking book interest rate risk", "eve sensitivity",
        "nii sensitivity", "rate shock impact",
        "parallel shift", "steepener", "flattener",
        "basis risk", "yield curve risk", "repricing risk",
    ],
    "notional": [
        "notional", "notional amount", "notional value", "face value",
        "principal amount", "contract value", "nominal value",
        "outstanding notional", "gross notional", "net notional",
    ],

    # =========================================================================
    # Risk
    # =========================================================================
    "var": [
        "var", "value at risk", "value-at-risk", "market risk",
        "var 99", "var 95", "daily var", "portfolio var",
        "stressed var", "svar", "incremental var", "marginal var",
    ],
    "exposure": [
        "exposure", "risk exposure", "credit exposure", "market exposure",
        "counterparty exposure", "gross exposure", "net exposure",
        "ead", "exposure at default", "potential future exposure",
        "current exposure", "peak exposure",
    ],
    "credit_risk": [
        "credit risk", "default risk", "counterparty risk",
        "borrower risk", "lending risk", "concentration risk",
        "country risk", "sovereign risk", "transfer risk",
        "settlement risk", "wrong way risk",
    ],
    "pd": [
        "pd", "probability of default", "default probability",
        "default rate", "expected default", "through the cycle pd",
        "point in time pd", "ttc pd", "pit pd", "12 month pd",
    ],
    "lgd": [
        "lgd", "loss given default", "default loss", "recovery rate",
        "loss rate", "expected loss", "downturn lgd",
        "cure rate", "loss severity", "collateral recovery",
    ],
    "ecl": [
        "ecl", "expected credit loss", "credit loss", "loan loss provision",
        "provision", "impairment", "allowance",
        "ifrs9 ecl", "lifetime ecl", "12 month ecl",
        "stage 1 ecl", "stage 2 ecl", "stage 3 ecl",
    ],
    "operational_risk": [
        "operational risk", "op risk", "operational loss",
        "conduct risk", "compliance risk", "fraud risk",
        "cyber risk", "technology risk", "third party risk",
        "model risk", "legal risk", "reputational risk",
    ],
    "market_risk": [
        "market risk", "trading risk", "position risk",
        "equity risk", "commodity risk", "interest rate risk",
        "fx risk", "credit spread risk", "volatility risk",
    ],
    "stress_test": [
        "stress test", "stress testing", "scenario analysis",
        "stress scenario", "adverse scenario", "severely adverse",
        "stress loss", "stress capital", "reverse stress test",
    ],

    # =========================================================================
    # ESG / Sustainability
    # =========================================================================
    "carbon": [
        "carbon", "carbon emissions", "co2", "carbon dioxide",
        "greenhouse gas", "ghg", "carbon footprint",
        "carbon intensity", "emission intensity", "carbon neutral",
        "net zero", "decarbonisation", "carbon offset",
    ],
    "scope1": [
        "scope 1", "scope1", "direct emissions", "scope one",
        "owned emissions", "operational emissions",
        "fleet emissions", "facility emissions", "combustion emissions",
    ],
    "scope2": [
        "scope 2", "scope2", "indirect emissions", "scope two",
        "purchased energy", "electricity emissions",
        "grid emissions", "heating emissions", "cooling emissions",
    ],
    "scope3": [
        "scope 3", "scope3", "value chain emissions", "scope three",
        "supply chain emissions", "downstream emissions",
        "financed emissions", "investment emissions", "upstream emissions",
    ],
    "renewable": [
        "renewable", "renewable energy", "clean energy", "green energy",
        "sustainable energy", "solar", "wind", "hydro",
        "renewable capacity", "green power", "clean power",
    ],
    "esg_score": [
        "esg score", "esg rating", "sustainability score",
        "environmental score", "social score", "governance score",
        "sustainability rating", "climate score", "green rating",
    ],
    "sustainable_finance": [
        "sustainable finance", "green finance", "green loan",
        "sustainability linked loan", "green bond", "social bond",
        "transition finance", "blended finance", "impact investing",
        "sustainable lending", "green lending",
    ],
    "financed_emissions": [
        "financed emissions", "portfolio emissions", "attributed emissions",
        "scope 3 category 15", "investment emissions",
        "lending portfolio emissions", "pcaf emissions",
    ],
    "water": [
        "water consumption", "water usage", "water intensity",
        "water withdrawal", "water recycling", "water stress",
    ],
    "waste": [
        "waste", "waste generated", "waste recycled", "waste to landfill",
        "circular economy", "recycling rate", "waste intensity",
    ],

    # =========================================================================
    # Regulatory / Capital
    # =========================================================================
    "car": [
        "car", "capital adequacy ratio", "capital ratio", "tier 1 ratio",
        "total capital ratio", "regulatory capital",
        "minimum capital requirement", "capital buffer", "capital surplus",
    ],
    "cet1": [
        "cet1", "common equity tier 1", "core capital", "cet1 ratio",
        "core tier 1", "common equity", "cet1 capital",
        "fully loaded cet1", "transitional cet1",
    ],
    "rwa": [
        "rwa", "risk weighted assets", "risk-weighted assets",
        "weighted assets", "capital charge",
        "credit rwa", "market rwa", "operational rwa",
        "standardised rwa", "irb rwa", "total rwa",
    ],
    "lcr": [
        "lcr", "liquidity coverage ratio", "liquidity ratio",
        "short-term liquidity", "hqla",
        "high quality liquid assets", "liquidity buffer",
        "net cash outflow", "lcr numerator", "lcr denominator",
    ],
    "nsfr": [
        "nsfr", "net stable funding ratio", "stable funding",
        "long-term liquidity", "funding ratio",
        "available stable funding", "required stable funding",
    ],
    "leverage_ratio": [
        "leverage ratio", "leverage", "gearing", "debt ratio",
        "debt-to-equity", "financial leverage",
        "tier 1 leverage", "supplementary leverage", "total leverage",
    ],
    "tier2": [
        "tier 2", "tier 2 capital", "supplementary capital",
        "subordinated debt capital", "t2 capital",
        "total capital", "tier 1 plus tier 2",
    ],
    "mrel": [
        "mrel", "minimum requirement for own funds",
        "total loss absorbing capacity", "tlac",
        "bail-in-able liabilities", "resolution capital",
    ],
    "large_exposure": [
        "large exposure", "le", "single name concentration",
        "counterparty limit", "large exposure limit",
        "connected counterparty exposure", "group exposure",
    ],

    # =========================================================================
    # Trade Finance / Transaction Banking
    # =========================================================================
    "trade_finance": [
        "trade finance", "trade volume", "trade assets",
        "letters of credit", "lc", "documentary credit",
        "trade receivables", "supply chain finance", "scf",
        "trade loans", "bills of exchange", "bankers acceptance",
    ],
    "cash_management": [
        "cash management", "cash position", "cash balance",
        "cash flow", "cash pooling", "notional pooling",
        "payment volume", "collection volume", "liquidity management",
    ],
    "payments": [
        "payments", "payment volume", "transaction volume",
        "inbound payments", "outbound payments", "swift messages",
        "real time payments", "rtp", "cross border payments",
        "domestic payments", "payment throughput",
    ],
    "guarantees": [
        "guarantees", "bank guarantee", "standby lc", "sblc",
        "performance guarantee", "bid bond", "advance payment guarantee",
        "financial guarantee", "shipping guarantee",
    ],

    # =========================================================================
    # Wealth / Consumer Banking
    # =========================================================================
    "aum": [
        "aum", "assets under management", "funds under management",
        "managed assets", "discretionary assets",
        "advisory assets", "total aum", "net new money",
        "nnm", "net inflows", "gross inflows",
    ],
    "mortgage": [
        "mortgage", "home loan", "housing loan", "mortgage book",
        "mortgage portfolio", "residential mortgage",
        "mortgage balance", "mortgage origination", "ltv",
        "loan to value", "mortgage rate", "mortgage arrears",
    ],
    "credit_card": [
        "credit card", "card receivables", "card balance",
        "card spend", "card volume", "card transactions",
        "card delinquency", "card npl", "revolving balance",
        "interchange income", "card fee income",
    ],
    "insurance": [
        "insurance", "insurance premium", "gross written premium",
        "gwp", "net premium", "claims", "loss ratio",
        "combined ratio", "underwriting profit", "bancassurance",
    ],
    "wealth_income": [
        "wealth income", "wealth revenue", "wealth management revenue",
        "private banking income", "advisory income",
        "brokerage income", "custody income", "fund distribution",
    ],
}

# Dimensions for cross-product expansion
DIMENSIONS = {
    "time_periods": [
        "Q1", "Q2", "Q3", "Q4", "Q1 2024", "Q2 2024", "Q3 2024", "Q4 2024",
        "Q1 2025", "Q2 2025", "Q3 2025", "Q4 2025", "Q1 2026", "Q2 2026",
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
        "2023", "2024", "2025", "2026", "FY2024", "FY2025", "FY2026",
        "YTD", "MTD", "QTD", "last month", "this month", "next month",
        "last quarter", "this quarter", "next quarter",
        "last year", "this year", "next year",
        "year to date", "month to date", "quarter to date",
        "prior period", "current period", "previous year",
        "H1", "H2", "first half", "second half",
        "rolling 12 months", "trailing 12 months", "TTM",
        "past 3 months", "past 6 months", "past 12 months"
    ],
    "segments": [
        "retail", "wholesale", "corporate", "commercial", "SME",
        "private banking", "wealth management", "treasury",
        "consumer banking", "business banking", "institutional",
        "global markets", "investment banking", "asset management",
        "transaction banking", "trade finance", "cash management",
        "personal banking", "premier banking", "mass affluent"
    ],
    "regions": [
        "Singapore", "Malaysia", "Indonesia", "Thailand", "Philippines",
        "Vietnam", "Hong Kong", "China", "India", "Japan", "Korea",
        "ASEAN", "Greater China", "North Asia", "South Asia",
        "Asia Pacific", "APAC", "Americas", "EMEA", "Europe",
        "United States", "UK", "Australia", "Middle East"
    ],
    "currencies": [
        "SGD", "USD", "EUR", "GBP", "JPY", "CNY", "HKD", "MYR",
        "THB", "IDR", "PHP", "INR", "AUD", "KRW", "TWD"
    ],
    "products": [
        "home loans", "mortgages", "credit cards", "personal loans",
        "auto loans", "car loans", "education loans", "student loans",
        "business loans", "term loans", "overdrafts", "trade finance",
        "letters of credit", "guarantees", "savings accounts",
        "current accounts", "fixed deposits", "structured deposits",
        "unit trusts", "bonds", "equities", "insurance"
    ],
    "customer_types": [
        "individual", "corporate", "sme", "government", "institutional",
        "high net worth", "hnwi", "mass market", "affluent",
        "multinational", "local corporate", "non-profit"
    ],
}

AGGREGATIONS = [
    "total", "sum", "average", "avg", "mean", "median",
    "maximum", "max", "minimum", "min", "count",
    "percentage", "percent", "ratio", "proportion",
    "growth", "change", "delta", "difference", "variance"
]

QUESTION_TEMPLATES = [
    # === Basic retrieval (13) ===
    "What is the {term}?",
    "Show me the {term}",
    "Display {term}",
    "Get {term}",
    "Retrieve {term}",
    "Find {term}",
    "Calculate {term}",
    "Compute {term}",
    "Give me {term}",
    "I need {term}",
    "Tell me {term}",
    "What's the {term}",
    "How much is the {term}",

    # === Aggregation (8) ===
    "What is the {agg} {term}?",
    "Show {agg} {term}",
    "Calculate {agg} {term}",
    "Get the {agg} of {term}",
    "What's the overall {agg} {term}?",
    "Provide the {agg} {term} across the portfolio",
    "Can you compute the {agg} {term}?",
    "How much is the {agg} {term}?",

    # === Temporal (10) ===
    "What is the {term} for {time}?",
    "Show {term} in {time}",
    "{term} for {time}",
    "Get {term} as of {time}",
    "{term} during {time}",
    "What was the {term} last reported in {time}?",
    "Pull the {term} numbers for {time}",
    "How did {term} perform in {time}?",
    "Give me {term} as at {time}",
    "Provide {term} data for the period {time}",

    # === Dimensional breakdown (8) ===
    "Show {term} by {dim}",
    "{term} breakdown by {dim}",
    "{term} split by {dim}",
    "Get {term} per {dim}",
    "{term} for each {dim}",
    "Break down {term} across all {dim}s",
    "What is the {term} distribution by {dim}?",
    "Provide a {dim}-level view of {term}",

    # === Comparison (8) ===
    "Compare {term} between {dim1} and {dim2}",
    "{term} {dim1} vs {dim2}",
    "Difference in {term} between {dim1} and {dim2}",
    "{term} comparison across {dims}",
    "How does {term} in {dim1} compare to {dim2}?",
    "What is the gap in {term} between {dim1} and {dim2}?",
    "Contrast {term} for {dim1} versus {dim2}",
    "Side by side {term} for {dim1} and {dim2}",

    # === Trend / Historical (8) ===
    "{term} trend",
    "{term} over time",
    "{term} historical trend",
    "How has {term} changed?",
    "{term} movement",
    "{term} trajectory",
    "Show the {term} trend over the past 12 months",
    "Plot {term} evolution from {time} to now",

    # === Growth / Period-over-period (10) ===
    "{term} growth",
    "{term} year over year",
    "{term} yoy",
    "{term} quarter over quarter",
    "{term} qoq",
    "{term} month over month",
    "{term} mom",
    "What is the YoY% change in {term}?",
    "How much did {term} grow quarter on quarter?",
    "Calculate the period-over-period change in {term}",

    # === Top/Bottom ranking (8) ===
    "Top 10 {dim} by {term}",
    "Bottom 10 {dim} by {term}",
    "Highest {term} by {dim}",
    "Lowest {term} by {dim}",
    "Best performing {dim} in {term}",
    "Worst performing {dim} in {term}",
    "Which {dim} has the highest {term}?",
    "Rank all {dim}s by {term} descending",

    # === Multi-dimensional / Complex (12) ===
    "What is the {term} for {dim1} in {time}?",
    "Show {term} by {dim1} for {time}",
    "{agg} {term} by {dim1} in {time}",
    "Compare {term} across {dim1} for {time}",
    "{term} by {dim1} and {dim2}",
    "{term} breakdown by {dim1} and {time}",
    "What is the {term} for {dim1} segment in {dim2} region for {time}?",
    "Show {agg} {term} by {dim1} and {dim2} for {time}",
    "Give me the {term} split by {dim1} filtered to {dim2} for {time}",
    "How does {term} break down by {dim1} within {dim2}?",
    "Cross-tab of {term} by {dim1} and {time}",
    "Pivot {term} across {dim1} for each {time} period",

    # === Contribution / Share (5) ===
    "What percentage does {dim1} contribute to overall {term}?",
    "What is {dim1}'s share of total {term}?",
    "How much of the {term} comes from {dim1}?",
    "{dim1} contribution to {term} as a percentage",
    "Show {term} proportion by {dim}",

    # === Variance / Budget comparison (5) ===
    "Compare {term} actual vs budget for {time}",
    "What is the {term} variance against plan for {time}?",
    "Show {term} actual versus forecast for {dim1} in {time}",
    "How far is {term} from the budget target?",
    "{term} actuals vs outlook for {time}",

    # === Natural analyst phrasing (10) ===
    "Was {time} a record period for {term}?",
    "Which quarter was the highest for {term} in the last 3 years?",
    "What is the current YTD monthly run rate for {term}?",
    "Is {term} trending up or down?",
    "What drove the change in {term} this quarter?",
    "Can you explain the {term} movement between {dim1} and {dim2}?",
    "Summarize {term} performance for {time}",
    "Give me a snapshot of {term} across all regions",
    "What's the outlook for {term} based on current trends?",
    "Highlight any anomalies in {term} for {time}",
]

SQL_TEMPLATES = {
    "simple": "SELECT {columns} FROM {table}",
    "aggregate": "SELECT {agg}({column}) as {alias} FROM {table}",
    "group_by": "SELECT {dim}, {agg}({column}) as {alias} FROM {table} GROUP BY {dim}",
    "filter": "SELECT {columns} FROM {table} WHERE {condition}",
    "order": "SELECT {columns} FROM {table} ORDER BY {order_col} {direction}",
    "top_n": "SELECT TOP {n} {columns} FROM {table} ORDER BY {order_col} DESC",
    "comparison": "SELECT {dim}, {agg}({column}) as {alias} FROM {table} WHERE {dim} IN ({values}) GROUP BY {dim}",
    "trend": "SELECT {time_dim}, {agg}({column}) as {alias} FROM {table} GROUP BY {time_dim} ORDER BY {time_dim}",
    "yoy": "SELECT \"YEAR\", {agg}({column}) as {alias}, LAG({agg}({column})) OVER (ORDER BY \"YEAR\") as PREV, ({agg}({column}) / LAG({agg}({column})) OVER (ORDER BY \"YEAR\") - 1) * 100 as YOY_GROWTH FROM {table} GROUP BY \"YEAR\"",
    "complex": "SELECT {dims}, {agg}({column}) as {alias} FROM {table} WHERE {conditions} GROUP BY {dims} ORDER BY {alias} DESC",
    # JOIN templates
    "join_dim": "SELECT d.{dim_col}, {agg}(f.{column}) as {alias} FROM {fact_table} f JOIN {dim_table} d ON f.{join_key} = d.{join_key} GROUP BY d.{dim_col}",
    "join_filter": "SELECT f.{column}, d.{dim_col} FROM {fact_table} f JOIN {dim_table} d ON f.{join_key} = d.{join_key} WHERE d.{dim_col} = '{filter_val}'",
    "join_multi": "SELECT d.{dim_col}, t.{time_col}, {agg}(f.{column}) as {alias} FROM {fact_table} f JOIN {dim_table} d ON f.{join_key} = d.{join_key} GROUP BY d.{dim_col}, t.{time_col} ORDER BY t.{time_col}",
    # CTE / subquery templates
    "with_cte": "WITH base AS (SELECT {dim}, {agg}({column}) as val FROM {table} WHERE {condition} GROUP BY {dim}) SELECT * FROM base WHERE val > (SELECT AVG(val) FROM base)",
    "subquery_filter": "SELECT {columns} FROM {table} WHERE {column} > (SELECT AVG({column}) FROM {table})",
}

TABLES = {
    "performance": [
        "BPC.ZFI_FIN_OVER_AFO_CP_FIN", "BPC.ZFI_PL_SUMMARY", "FIN.INCOME_STATEMENT",
        "FIN.PL_MONTHLY", "FIN.PL_QUARTERLY", "BPC.ZFI_PL_DETAIL",
    ],
    "balance_sheet": [
        "BPC.ZFI_BS_SUMMARY", "FIN.BALANCE_SHEET", "BPC.ZFI_BS_DETAIL",
        "FIN.BS_MONTHLY", "FIN.BS_QUARTERLY",
    ],
    "treasury": [
        "TREASURY.POSITION", "TREASURY.FX_TRADES", "TREASURY.DERIVATIVES",
        "TREASURY.BOND_PORTFOLIO", "TREASURY.ALM_GAP", "TREASURY.FTP_RATES",
    ],
    "risk": [
        "RISK.VAR_DAILY", "RISK.CREDIT_EXPOSURE", "RISK.LIMITS",
        "RISK.ECL_STAGE", "RISK.PD_MODEL", "RISK.STRESS_RESULTS",
    ],
    "esg": [
        "SUSTAINABILITY.ESG_METRICS", "ESG.EMISSIONS", "ESG.ENVIRONMENTAL",
        "ESG.SF_FLAT", "ESG.FINANCED_EMISSIONS", "ESG.SUSTAINABILITY_SCORES",
    ],
    "regulatory": [
        "REG.BASEL_RATIOS", "REG.LIQUIDITY_RATIOS", "REG.CAPITAL",
        "REG.RWA_DETAIL", "REG.LCR_DETAIL", "REG.NSFR_DETAIL",
    ],
    "general_ledger": ["GL.ACDOCA", "GL.BSEG", "GL.FAGLFLEXA"],
    "trade_finance": [
        "TF.TRADE_TRANSACTIONS", "TF.LC_PORTFOLIO", "TF.GUARANTEE_BOOK",
        "TF.SCF_POSITIONS",
    ],
    "wealth": [
        "WM.AUM_SUMMARY", "WM.PORTFOLIO_HOLDINGS", "WM.CLIENT_ASSETS",
        "WM.NET_FLOWS",
    ],
    "consumer": [
        "CB.MORTGAGE_BOOK", "CB.CARD_PORTFOLIO", "CB.PERSONAL_LOANS",
        "CB.DEPOSIT_BOOK", "CB.INSURANCE_PREMIUM",
    ],
}

# JOIN relationships for multi-table query generation
JOIN_SCHEMAS = {
    "risk_country": {
        "fact_table": "STG_BCRS.BSI_REM_FACT",
        "dim_table": "STG_BCRS.BSI_REM_DIM_COUNTRY_GEOLOCATION",
        "join_key": "COUNTRY_CODE",
        "fact_cols": ["EAD", "RWA", "NOTIONAL", "IRB_PROBABILITY_OF_DEFAULT_PD", "IRB_LOSS_GIVEN_DEFAULT_LGD", "FINAL_RISK_WEIGHT"],
        "dim_cols": ["COUNTRY", "ALPHA_CODE_2", "ALPHA_CODE_3"],
    },
    "risk_fx": {
        "fact_table": "STG_BCRS.BSI_REM_FACT",
        "dim_table": "STG_BCRS.BSI_REM_MKT_FX",
        "join_key": "CCY_CODE",
        "fact_cols": ["EAD", "RWA", "NOTIONAL"],
        "dim_cols": ["RATE", "VALUE_DATE"],
    },
    "treasury_fx": {
        "fact_table": "TREASURY.POSITION",
        "dim_table": "TREASURY.FX_RATE",
        "join_key": "CCY_CODE",
        "fact_cols": ["NOTIONAL", "MTM", "PV01", "RWA"],
        "dim_cols": ["SPOT_RATE", "BASE_CCY", "QUOTE_CCY"],
    },
    "performance_account": {
        "fact_table": "BPC.ZFI_FIN_OVER_AFO_CP_FIN",
        "dim_table": "BPC.DIM_ACCOUNT",
        "join_key": "ACCOUNT",
        "fact_cols": ["RTC_AMO"],
        "dim_cols": ["ACCOUNT_NAME", "ACCOUNT_TYPE", "ACCOUNT_GROUP"],
    },
    "performance_entity": {
        "fact_table": "BPC.ZFI_FIN_OVER_AFO_CP_FIN",
        "dim_table": "BPC.DIM_ENTITY",
        "join_key": "ENTITY",
        "fact_cols": ["RTC_AMO"],
        "dim_cols": ["ENTITY_NAME", "REGION", "COUNTRY"],
    },
    "esg_location": {
        "fact_table": "ESG.SF_FLAT",
        "dim_table": "ESG.DIM_LOCATION",
        "join_key": "BOOKING_LOCATION",
        "fact_cols": ["FINANCED_EMISSION", "CIB_PE_ASSET", "TOTAL_REVENUE_YTD", "EXPOSURE", "RWA"],
        "dim_cols": ["LOCATION_NAME", "REGION", "COUNTRY_GROUP"],
    },
    "performance_time": {
        "fact_table": "BPC.ZFI_FIN_OVER_AFO_CP_FIN",
        "dim_table": "BPC.DIM_TIME",
        "join_key": "TIME_ID",
        "fact_cols": ["RTC_AMO"],
        "dim_cols": ["YEAR", "QUARTER", "MONTH", "FISCAL_YEAR"],
    },
    "regulatory_entity": {
        "fact_table": "REG.BASEL_RATIOS",
        "dim_table": "REG.DIM_ENTITY",
        "join_key": "ENTITY_CODE",
        "fact_cols": ["CET1_RATIO", "RWA", "LCR", "NSFR", "LEVERAGE_RATIO"],
        "dim_cols": ["ENTITY_NAME", "REGION", "LEGAL_ENTITY"],
    },
    "treasury_product": {
        "fact_table": "TREASURY.POSITION",
        "dim_table": "TREASURY.DIM_PRODUCT",
        "join_key": "PRODUCT_CODE",
        "fact_cols": ["NOTIONAL", "MTM", "PV01"],
        "dim_cols": ["PRODUCT_NAME", "PRODUCT_TYPE", "ASSET_CLASS"],
    },
    "consumer_segment": {
        "fact_table": "CB.MORTGAGE_BOOK",
        "dim_table": "CB.DIM_SEGMENT",
        "join_key": "SEGMENT_CODE",
        "fact_cols": ["BALANCE", "ORIGINATION", "DELINQUENCY", "LTV"],
        "dim_cols": ["SEGMENT_NAME", "CUSTOMER_TYPE", "CHANNEL"],
    },
    "wealth_client": {
        "fact_table": "WM.AUM_SUMMARY",
        "dim_table": "WM.DIM_CLIENT_TIER",
        "join_key": "CLIENT_TIER",
        "fact_cols": ["AUM", "NET_FLOWS", "REVENUE", "FEE_INCOME"],
        "dim_cols": ["TIER_NAME", "MIN_BALANCE", "RELATIONSHIP_MANAGER"],
    },
}

# Negative / unanswerable question templates
NEGATIVE_TEMPLATES = [
    # Unknown metric (will cross with FAKE_TERMS)
    {"question": "What is the {fake_term} for {dim}?", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "Show me the {fake_term} by {dim}", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "Calculate the {fake_term}", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "Get the total {fake_term} for {dim}", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "How much is the {fake_term}?", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "Provide {fake_term} breakdown by {dim}", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "Pull the {fake_term} numbers", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    {"question": "I need the {fake_term} for {dim}", "response": "I cannot answer this question. '{fake_term}' is not a recognized metric in our data model.", "type": "unknown_metric"},
    # Unknown dimension (will cross with FAKE_DIMS)
    {"question": "Show {term} for {fake_dim}", "response": "I cannot answer this question. '{fake_dim}' is not a valid dimension in the {domain} domain.", "type": "unknown_dimension"},
    {"question": "Break down {term} by {fake_dim}", "response": "I cannot answer this question. '{fake_dim}' is not a valid dimension in the {domain} domain.", "type": "unknown_dimension"},
    {"question": "Get {term} per {fake_dim}", "response": "I cannot answer this question. '{fake_dim}' is not a valid dimension in the {domain} domain.", "type": "unknown_dimension"},
    {"question": "What is the {term} split by {fake_dim}?", "response": "I cannot answer this question. '{fake_dim}' is not a valid dimension in the {domain} domain.", "type": "unknown_dimension"},
    {"question": "{term} grouped by {fake_dim}", "response": "I cannot answer this question. '{fake_dim}' is not a valid dimension in the {domain} domain.", "type": "unknown_dimension"},
    {"question": "Provide {term} by {fake_dim}", "response": "I cannot answer this question. '{fake_dim}' is not a valid dimension in the {domain} domain.", "type": "unknown_dimension"},
    # Future date
    {"question": "What is the {term} for March 2030?", "response": "I cannot answer this question. Data is not available for future periods beyond the current reporting cycle.", "type": "future_date"},
    {"question": "Show {term} forecast for 2035", "response": "I cannot answer this question. Data is not available for future periods beyond the current reporting cycle.", "type": "future_date"},
    {"question": "Get {term} for Q4 2031", "response": "I cannot answer this question. Data is not available for future periods beyond the current reporting cycle.", "type": "future_date"},
    {"question": "What will the {term} be in 2029?", "response": "I cannot answer this question. Data is not available for future periods beyond the current reporting cycle.", "type": "future_date"},
    {"question": "Predict {term} for next decade", "response": "I cannot answer this question. I can only query historical data, not generate predictions.", "type": "future_date"},
    {"question": "Project {term} for 2028 by {dim}", "response": "I cannot answer this question. Data is not available for future periods beyond the current reporting cycle.", "type": "future_date"},
    # Non-SELECT (DML/DDL)
    {"question": "Delete all {term} records", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Update the {term} to 1000000", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Drop table {table}", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Insert a new {term} record", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Truncate the {term} table", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Alter the {term} column type", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Create a new table for {term}", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Grant access to {term} data", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Merge {term} records from staging", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    {"question": "Overwrite {term} with corrected values", "response": "I cannot perform this action. I can only generate SELECT queries for data retrieval, not data modification.", "type": "non_select"},
    # PII restricted
    {"question": "What is the {term} for individual customer John Smith?", "response": "I cannot answer this question. Customer-level personal data queries are restricted under data privacy policies.", "type": "pii_restricted"},
    {"question": "Show me the {term} by customer name", "response": "I cannot answer this question. Customer-level personal data queries are restricted under data privacy policies.", "type": "pii_restricted"},
    {"question": "Get {term} for account number 12345678", "response": "I cannot answer this question. Individual account-level queries are restricted under data privacy policies.", "type": "pii_restricted"},
    {"question": "List all customers with {term} above 1 million", "response": "I cannot answer this question. Customer-level personal data queries are restricted under data privacy policies.", "type": "pii_restricted"},
    {"question": "Show {term} by employee ID", "response": "I cannot answer this question. Employee-level personal data queries are restricted under data privacy policies.", "type": "pii_restricted"},
    {"question": "What is the {term} for passport number X12345?", "response": "I cannot answer this question. Queries referencing personal identification documents are restricted.", "type": "pii_restricted"},
    # Out of range
    {"question": "What was the {term} in 1995?", "response": "I cannot answer this question. Historical data prior to the retention period is not available in the current data model.", "type": "out_of_range"},
    {"question": "Show {term} for 1980", "response": "I cannot answer this question. Historical data prior to the retention period is not available in the current data model.", "type": "out_of_range"},
    {"question": "Get {term} from the 1990s", "response": "I cannot answer this question. Historical data prior to the retention period is not available in the current data model.", "type": "out_of_range"},
    {"question": "What was the {term} before the bank was founded?", "response": "I cannot answer this question. Historical data prior to the retention period is not available in the current data model.", "type": "out_of_range"},
    # Invalid operation
    {"question": "Calculate {term} divided by zero", "response": "I cannot generate this query. Division by zero is undefined and would result in an error.", "type": "invalid_operation"},
    {"question": "What is the square root of negative {term}?", "response": "I cannot generate this query. The square root of a negative number is undefined for real-valued metrics.", "type": "invalid_operation"},
    {"question": "Compute log of zero for {term}", "response": "I cannot generate this query. Logarithm of zero is undefined.", "type": "invalid_operation"},
    # Cross-domain confusion
    {"question": "What is the carbon emission of the treasury portfolio?", "response": "I cannot answer this question. Carbon emissions are tracked in the ESG domain, not the treasury domain. Please rephrase your question.", "type": "cross_domain"},
    {"question": "Show the CET1 ratio for ESG metrics", "response": "I cannot answer this question. CET1 ratio is a regulatory capital metric, not an ESG metric.", "type": "cross_domain"},
    {"question": "Get the mortgage balance from the treasury system", "response": "I cannot answer this question. Mortgage data is in the consumer banking domain, not treasury.", "type": "cross_domain"},
    {"question": "What is the AUM in the risk system?", "response": "I cannot answer this question. AUM is tracked in the wealth management domain, not the risk domain.", "type": "cross_domain"},
    # Ambiguous
    {"question": "Show me the numbers", "response": "I cannot answer this question. Please specify which metric and time period you are interested in.", "type": "ambiguous"},
    {"question": "What is the total?", "response": "I cannot answer this question. Please specify which metric you would like the total for.", "type": "ambiguous"},
    {"question": "Give me everything", "response": "I cannot answer this question. Please specify which metric, domain, and time period you need.", "type": "ambiguous"},
    {"question": "How are we doing?", "response": "I cannot answer this question. Please specify which performance metric and time period you are interested in.", "type": "ambiguous"},
    {"question": "Show the data", "response": "I cannot answer this question. Please specify which metric and dimension you would like to see.", "type": "ambiguous"},
]

FAKE_TERMS = [
    "customer happiness index", "blockchain efficiency", "quantum yield",
    "social media score", "weather impact factor", "employee satisfaction",
    "machine learning accuracy", "website traffic", "app downloads",
    "sentiment score", "viral coefficient", "churn prediction",
    "brand awareness score", "innovation index", "digital maturity",
    "cloud adoption rate", "agile velocity", "sprint burndown",
    "net promoter score", "customer effort score", "bounce rate",
    "page views per session", "click through rate", "conversion funnel",
    "talent retention index", "diversity score", "wellness index",
    "supply chain resilience", "inventory turnover days", "order fulfillment rate",
]

FAKE_DIMS = [
    "zodiac sign", "blood type", "favorite color", "shoe size",
    "birth month", "pet type", "coffee preference", "music genre",
    "star rating", "weather condition", "day of week", "moon phase",
    "personality type", "dietary preference", "commute distance",
    "social media platform", "browser type", "operating system",
]

# Multi-turn conversation templates
MULTI_TURN_TEMPLATES = [
    {
        "turns": [
            {"role": "user", "content": "What is the {term} for {time}?"},
            {"role": "assistant", "content": "Here is the {term} for {time}:", "sql": "SELECT SUM({column}) as {alias} FROM {table} WHERE PERIOD = '{time}'"},
            {"role": "user", "content": "Now break that down by {dim}"},
            {"role": "assistant", "content": "Here is the {term} broken down by {dim}:", "sql": "SELECT {dim}, SUM({column}) as {alias} FROM {table} WHERE PERIOD = '{time}' GROUP BY {dim} ORDER BY {alias} DESC"},
        ],
        "type": "drill_down",
    },
    {
        "turns": [
            {"role": "user", "content": "Show {term} by {dim}"},
            {"role": "assistant", "content": "Here is {term} by {dim}:", "sql": "SELECT {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "Filter that to just {filter_val}"},
            {"role": "assistant", "content": "Here is {term} filtered to {filter_val}:", "sql": "SELECT SUM({column}) as {alias} FROM {table} WHERE {dim} = '{filter_val}'"},
        ],
        "type": "refine_filter",
    },
    {
        "turns": [
            {"role": "user", "content": "What is the total {term}?"},
            {"role": "assistant", "content": "Here is the total {term}:", "sql": "SELECT SUM({column}) as SUM_{column} FROM {table}"},
            {"role": "user", "content": "How does that compare to last year?"},
            {"role": "assistant", "content": "Here is the year-over-year comparison:", "sql": "SELECT \"YEAR\", SUM({column}) as SUM_{column} FROM {table} GROUP BY \"YEAR\" ORDER BY \"YEAR\" DESC LIMIT 2"},
        ],
        "type": "temporal_followup",
    },
    {
        "turns": [
            {"role": "user", "content": "Show me the top 5 {dim}s by {term}"},
            {"role": "assistant", "content": "Here are the top 5 {dim}s by {term}:", "sql": "SELECT TOP 5 {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "What about the bottom 5?"},
            {"role": "assistant", "content": "Here are the bottom 5 {dim}s by {term}:", "sql": "SELECT TOP 5 {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} ASC"},
        ],
        "type": "flip_ranking",
    },
    {
        "turns": [
            {"role": "user", "content": "Give me {term} for {time}"},
            {"role": "assistant", "content": "Here is {term} for {time}:", "sql": "SELECT SUM({column}) as {alias} FROM {table} WHERE PERIOD = '{time}'"},
            {"role": "user", "content": "Now show me the average instead"},
            {"role": "assistant", "content": "Here is the average {term} for {time}:", "sql": "SELECT AVG({column}) as AVG_{column} FROM {table} WHERE PERIOD = '{time}'"},
        ],
        "type": "change_aggregation",
    },
    {
        "turns": [
            {"role": "user", "content": "What is the {term} by {dim}?"},
            {"role": "assistant", "content": "Here is {term} by {dim}:", "sql": "SELECT {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "Add a time filter for {time}"},
            {"role": "assistant", "content": "Here is {term} by {dim} for {time}:", "sql": "SELECT {dim}, SUM({column}) as {alias} FROM {table} WHERE PERIOD = '{time}' GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "Just show {filter_val}"},
            {"role": "assistant", "content": "Here is {term} for {filter_val} in {time}:", "sql": "SELECT SUM({column}) as {alias} FROM {table} WHERE PERIOD = '{time}' AND {dim} = '{filter_val}'"},
        ],
        "type": "progressive_filter",
    },
    {
        "turns": [
            {"role": "user", "content": "Show {term} for {filter_val}"},
            {"role": "assistant", "content": "Here is {term} for {filter_val}:", "sql": "SELECT SUM({column}) as {alias} FROM {table} WHERE {dim} = '{filter_val}'"},
            {"role": "user", "content": "What percentage is that of the total?"},
            {"role": "assistant", "content": "Here is {filter_val}'s share of total {term}:", "sql": "SELECT ROUND(100.0 * SUM(CASE WHEN {dim} = '{filter_val}' THEN {column} ELSE 0 END) / NULLIF(SUM({column}), 0), 2) as pct_of_total FROM {table}"},
        ],
        "type": "share_of_total",
    },
    {
        "turns": [
            {"role": "user", "content": "How much is the {term}?"},
            {"role": "assistant", "content": "Here is the total {term}:", "sql": "SELECT SUM({column}) as SUM_{column} FROM {table}"},
            {"role": "user", "content": "Split that by {dim} and {time}"},
            {"role": "assistant", "content": "Here is {term} by {dim} and period:", "sql": "SELECT {dim}, PERIOD, SUM({column}) as SUM_{column} FROM {table} GROUP BY {dim}, PERIOD ORDER BY PERIOD, SUM_{column} DESC"},
        ],
        "type": "multi_dim_drill",
    },
    {
        "turns": [
            {"role": "user", "content": "Get {term} trend over time"},
            {"role": "assistant", "content": "Here is the {term} trend:", "sql": "SELECT PERIOD, SUM({column}) as {alias} FROM {table} GROUP BY PERIOD ORDER BY PERIOD"},
            {"role": "user", "content": "Now just for {filter_val}"},
            {"role": "assistant", "content": "Here is the {term} trend for {filter_val}:", "sql": "SELECT PERIOD, SUM({column}) as {alias} FROM {table} WHERE {dim} = '{filter_val}' GROUP BY PERIOD ORDER BY PERIOD"},
        ],
        "type": "trend_then_filter",
    },
    {
        "turns": [
            {"role": "user", "content": "Compare {term} across {dim}s"},
            {"role": "assistant", "content": "Here is {term} across all {dim}s:", "sql": "SELECT {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "Which one has the highest?"},
            {"role": "assistant", "content": "Here is the {dim} with the highest {term}:", "sql": "SELECT TOP 1 {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "And the lowest?"},
            {"role": "assistant", "content": "Here is the {dim} with the lowest {term}:", "sql": "SELECT TOP 1 {dim}, SUM({column}) as {alias} FROM {table} GROUP BY {dim} ORDER BY {alias} ASC"},
        ],
        "type": "compare_then_extremes",
    },
    {
        "turns": [
            {"role": "user", "content": "I need {term} for {time} by {dim}"},
            {"role": "assistant", "content": "Here is {term} for {time} by {dim}:", "sql": "SELECT {dim}, SUM({column}) as {alias} FROM {table} WHERE PERIOD = '{time}' GROUP BY {dim} ORDER BY {alias} DESC"},
            {"role": "user", "content": "Can you also show the count?"},
            {"role": "assistant", "content": "Here is {term} with count for {time} by {dim}:", "sql": "SELECT {dim}, SUM({column}) as {alias}, COUNT(*) as record_count FROM {table} WHERE PERIOD = '{time}' GROUP BY {dim} ORDER BY {alias} DESC"},
        ],
        "type": "add_metric",
    },
    {
        "turns": [
            {"role": "user", "content": "Pull {term} for {filter_val} in {time}"},
            {"role": "assistant", "content": "Here is {term} for {filter_val} in {time}:", "sql": "SELECT SUM({column}) as {alias} FROM {table} WHERE {dim} = '{filter_val}' AND PERIOD = '{time}'"},
            {"role": "user", "content": "What about the same period last year?"},
            {"role": "assistant", "content": "Here is the prior year comparison:", "sql": "SELECT PERIOD, SUM({column}) as {alias} FROM {table} WHERE {dim} = '{filter_val}' AND PERIOD IN ('{time}', 'prior_year') GROUP BY PERIOD ORDER BY PERIOD"},
        ],
        "type": "prior_period",
    },
]

# Schema-description training pairs (staging CSV metadata → NL)
SCHEMA_DESCRIPTION_TEMPLATES = [
    "What table contains {field_desc}?",
    "Which schema stores {field_desc}?",
    "Where can I find {field_name} data?",
    "What is the data type of {field_name} in {table_name}?",
    "Describe the {field_name} column in {table_name}",
    "What fields are available in {table_name}?",
    "Which source system feeds {table_name}?",
    "What is the BTP equivalent of {source_field} from {source_table}?",
    "Map {source_field} from {source_system} to BTP",
    "How is {field_name} stored in the staging layer?",
]

class MassiveTermGenerator:
    """Generate massive amounts of semantic training data."""
    
    def __init__(self, target_multiplier: float = 10.0):
        """
        Args:
            target_multiplier: Generate this many times the base term count
        """
        self.target_multiplier = target_multiplier
        self.generated_examples: List[Dict] = []
        self.seen_hashes: Set[str] = set()
        
    def _hash_example(self, question: str, sql: str) -> str:
        """Create hash to detect duplicates."""
        return hashlib.md5(f"{question}|{sql}".encode()).hexdigest()
    
    # Reserved words that commonly appear as column names in banking schemas
    # and must be quoted in HANA. We intentionally exclude SQL keywords that
    # are only used structurally (ORDER, GROUP, SELECT, etc.).
    _HANA_RESERVED_COLUMNS = {
        "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND",
        "DATE", "TIME", "TIMESTAMP", "INTERVAL",
        "KEY", "INDEX", "USER", "LIMIT",
        "WINDOW", "CURRENT", "FIRST", "NEXT", "ONLY",
    }

    # Contexts where a reserved word should NOT be quoted (it's a SQL keyword)
    _KEYWORD_CONTEXTS = re.compile(
        r'EXTRACT\s*\(\s*$'       # EXTRACT(YEAR FROM ...)
        r'|ORDER\s+$'             # ORDER BY
        r'|GROUP\s+$'             # GROUP BY
        r'|PARTITION\s+$'         # PARTITION BY
    )

    @classmethod
    def _sanitize_sql(cls, sql: str) -> str:
        """Quote HANA reserved words used as bare column identifiers in SQL."""
        result = sql
        for word in cls._HANA_RESERVED_COLUMNS:
            if word not in result.upper():
                continue
            # Pattern: bare WORD not already quoted, not preceded by dot/quote,
            # not followed by open-paren (function call) or quote.
            pattern = rf'(?<!["\w.])({word})(?!["\w(])'
            def _quote_if_column(m: re.Match) -> str:
                # Check what precedes this match — if it's a keyword context, skip
                prefix = result[:m.start()]
                if cls._KEYWORD_CONTEXTS.search(prefix):
                    return m.group(0)  # Don't quote
                return f'"{m.group(1)}"'
            result = re.sub(pattern, _quote_if_column, result)
        # Clean up any double-quoting from templates that already quoted
        result = result.replace('""', '"')
        return result

    def _add_example(self, question: str, sql: str, metadata: Dict) -> bool:
        """Add example if not duplicate. Sanitizes SQL for HANA compatibility."""
        sql = self._sanitize_sql(sql)
        h = self._hash_example(question.lower(), sql.lower())
        if h in self.seen_hashes:
            return False
        self.seen_hashes.add(h)
        self.generated_examples.append({
            "question": question,
            "sql": sql,
            **metadata
        })
        return True
    
    def expand_term(self, base_term: str, synonyms: List[str]) -> List[str]:
        """Expand a term with all its variations."""
        variations = set(synonyms)
        
        # Add capitalization variants
        for syn in synonyms:
            variations.add(syn.lower())
            variations.add(syn.upper())
            variations.add(syn.title())
        
        # Add abbreviated forms
        words = base_term.split()
        if len(words) > 1:
            acronym = "".join(w[0] for w in words)
            variations.add(acronym.upper())
            variations.add(acronym.lower())
        
        # Add common modifiers
        for syn in synonyms[:8]:  # Expanded for 500K target
            for mod in ["total", "net", "gross", "actual", "budgeted", "forecasted"]:
                variations.add(f"{mod} {syn}")
            
        return list(variations)
    
    # Diverse question prefixes for simple/aggregate queries
    _SIMPLE_Q_TEMPLATES = [
        "What is the {term} {ctx}?",
        "Show me the {term} {ctx}",
        "Get the {term} {ctx}",
        "Retrieve {term} {ctx}",
        "Display {term} {ctx}",
        "Give me {term} {ctx}",
        "I need the {term} {ctx}",
        "Tell me the {term} {ctx}",
        "What's the {term} {ctx}",
        "How much is the {term} {ctx}?",
        "Pull the {term} numbers {ctx}",
        "Can you get {term} {ctx}?",
        "Provide {term} {ctx}",
        "Find the {term} {ctx}",
        "Look up {term} {ctx}",
    ]
    _AGG_Q_TEMPLATES = [
        "What is the {agg} {term} {ctx}?",
        "Show the {agg} {term} {ctx}",
        "Calculate {agg} {term} {ctx}",
        "Get the {agg} of {term} {ctx}",
        "Compute the {agg} {term} {ctx}",
        "What's the overall {agg} {term} {ctx}?",
        "Provide the {agg} {term} {ctx}",
        "How much is the {agg} {term} {ctx}?",
        "Give me the {agg} {term} {ctx}",
        "Find the {agg} {term} {ctx}",
        "Can you calculate the {agg} {term} {ctx}?",
        "Tell me the {agg} {term} {ctx}",
        "Retrieve the {agg} {term} {ctx}",
        "Pull the {agg} {term} {ctx}",
        "I need the {agg} {term} {ctx}",
    ]

    def generate_simple_queries(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate simple SELECT queries with contextual WHERE clauses."""
        count = 0
        tables = TABLES.get(domain, TABLES["performance"])
        default_filters = [
            ('WHERE "YEAR" = 2025', "for 2025"),
            ("WHERE PERIOD = 'YTD'", "year to date"),
            ("WHERE PERIOD = 'Q4 2024'", "for Q4 2024"),
        ]
        simple_idx = 0
        agg_idx = 0

        for syn in synonyms:
            for table in tables:
                column = syn.upper().replace(" ", "_")

                # Simple select — rotate through templates
                filt, filt_text = random.choice(default_filters)
                tmpl = self._SIMPLE_Q_TEMPLATES[simple_idx % len(self._SIMPLE_Q_TEMPLATES)]
                simple_idx += 1
                q = tmpl.format(term=syn, ctx=filt_text)
                sql = f"SELECT {column} FROM {table} {filt}"
                if self._add_example(q, sql, {"domain": domain, "type": "simple", "term": term}):
                    count += 1

                # With aggregation — rotate through templates
                for agg in ["SUM", "AVG", "COUNT", "MAX", "MIN"]:
                    filt, filt_text = random.choice(default_filters)
                    alias = f"{agg}_{column}"
                    tmpl = self._AGG_Q_TEMPLATES[agg_idx % len(self._AGG_Q_TEMPLATES)]
                    agg_idx += 1
                    q = tmpl.format(agg=agg.lower(), term=syn, ctx=filt_text)
                    sql = f"SELECT {agg}({column}) as {alias} FROM {table} {filt}"
                    if self._add_example(q, sql, {"domain": domain, "type": "aggregate", "term": term}):
                        count += 1

        return count
    
    _DIM_Q_TEMPLATES = [
        "Show {term} by {dim}",
        "{term} breakdown by {dim}",
        "{term} split by {dim}",
        "Get {term} per {dim}",
        "{term} for each {dim}",
        "Break down {term} across all {dim}s",
        "What is the {term} distribution by {dim}?",
        "Provide a {dim}-level view of {term}",
        "Give me {term} grouped by {dim}",
        "Display {term} by {dim}",
        "How does {term} vary by {dim}?",
        "Summarize {term} by {dim}",
    ]

    def generate_dimensional_queries(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate queries with dimensional breakdowns."""
        count = 0
        tables = TABLES.get(domain, TABLES["performance"])
        dim_idx = 0

        for syn in synonyms[:12]:
            for table in tables[:4]:
                column = syn.upper().replace(" ", "_")

                # By segment
                for segment_type in ["SEGMENT", "REGION", "PRODUCT", "CURRENCY"]:
                    tmpl = self._DIM_Q_TEMPLATES[dim_idx % len(self._DIM_Q_TEMPLATES)]
                    dim_idx += 1
                    q = tmpl.format(term=syn, dim=segment_type.lower())
                    sql = f"SELECT {segment_type}, SUM({column}) as {column} FROM {table} GROUP BY {segment_type}"
                    if self._add_example(q, sql, {"domain": domain, "type": "group_by", "term": term}):
                        count += 1

                # By time period
                for time_dim in ["PERIOD", "YEAR", "MONTH", "QUARTER"]:
                    tmpl = self._DIM_Q_TEMPLATES[dim_idx % len(self._DIM_Q_TEMPLATES)]
                    dim_idx += 1
                    q = tmpl.format(term=syn, dim=time_dim.lower())
                    sql = f"SELECT {time_dim}, SUM({column}) as {column} FROM {table} GROUP BY {time_dim} ORDER BY {time_dim}"
                    if self._add_example(q, sql, {"domain": domain, "type": "trend", "term": term}):
                        count += 1

        return count
    
    # Diverse question templates for filtered queries
    _FILTER_TIME_TEMPLATES = [
        "What is the {term} for {val}?",
        "Show me {term} for {val}",
        "Get {term} for {val}",
        "Pull the {term} numbers for {val}",
        "How did {term} perform in {val}?",
        "Give me {term} as at {val}",
        "{term} for {val}",
        "Provide {term} data for {val}",
        "What was the {term} in {val}?",
        "Retrieve {term} for the period {val}",
        "Can you show {term} for {val}?",
        "I need {term} for {val}",
        "Tell me the {term} for {val}",
        "Look up {term} for {val}",
        "What's the {term} for {val}?",
    ]
    _FILTER_DIM_TEMPLATES = [
        "What is the {term} for {val}?",
        "Show me {term} for {val}",
        "Get {term} for the {val} segment",
        "{term} for {val}",
        "How much is {term} in {val}?",
        "Give me {term} for {val}",
        "Pull {term} for {val}",
        "What's the {term} in {val}?",
        "Provide {term} for {val}",
        "Retrieve {term} filtered to {val}",
        "Can you get {term} for {val}?",
        "I need {term} for {val}",
        "Tell me {term} for {val}",
        "Look up {term} for {val}",
        "Find {term} for {val}",
    ]

    def generate_filtered_queries(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate queries with WHERE clauses."""
        count = 0
        tables = TABLES.get(domain, TABLES["performance"])
        time_idx = 0
        seg_idx = 0
        reg_idx = 0

        for syn in synonyms[:10]:
            for table in tables[:3]:
                column = syn.upper().replace(" ", "_")

                # Time filters
                for period in DIMENSIONS["time_periods"][:40]:
                    period_clean = period.replace("'", "''")
                    tmpl = self._FILTER_TIME_TEMPLATES[time_idx % len(self._FILTER_TIME_TEMPLATES)]
                    time_idx += 1
                    q = tmpl.format(term=syn, val=period)

                    if period.isdigit() and len(period) == 4:
                        sql = f"SELECT SUM({column}) as {column} FROM {table} WHERE YEAR = {period}"
                    else:
                        sql = f"SELECT SUM({column}) as {column} FROM {table} WHERE PERIOD = '{period_clean}'"

                    if self._add_example(q, sql, {"domain": domain, "type": "filtered", "term": term}):
                        count += 1

                # Segment filters
                for segment in DIMENSIONS["segments"][:20]:
                    tmpl = self._FILTER_DIM_TEMPLATES[seg_idx % len(self._FILTER_DIM_TEMPLATES)]
                    seg_idx += 1
                    q = tmpl.format(term=syn, val=segment)
                    sql = f"SELECT SUM({column}) as {column} FROM {table} WHERE SEGMENT = '{segment}'"
                    if self._add_example(q, sql, {"domain": domain, "type": "filtered", "term": term}):
                        count += 1

                # Region filters
                for region in DIMENSIONS["regions"][:20]:
                    tmpl = self._FILTER_DIM_TEMPLATES[reg_idx % len(self._FILTER_DIM_TEMPLATES)]
                    reg_idx += 1
                    q = tmpl.format(term=syn, val=region)
                    sql = f"SELECT SUM({column}) as {column} FROM {table} WHERE REGION = '{region}'"
                    if self._add_example(q, sql, {"domain": domain, "type": "filtered", "term": term}):
                        count += 1

        return count
    
    def generate_comparison_queries(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate comparison queries."""
        count = 0
        tables = TABLES.get(domain, TABLES["performance"])
        
        for syn in synonyms[:10]:
            for table in tables[:3]:
                column = syn.upper().replace(" ", "_")

                # Segment comparisons
                segments = DIMENSIONS["segments"][:15]
                for i, seg1 in enumerate(segments):
                    for seg2 in segments[i+1:i+3]:  # Limit pairs
                        q = f"Compare {syn} between {seg1} and {seg2}"
                        sql = f"SELECT SEGMENT, SUM({column}) as {column} FROM {table} WHERE SEGMENT IN ('{seg1}', '{seg2}') GROUP BY SEGMENT"
                        if self._add_example(q, sql, {"domain": domain, "type": "comparison", "term": term}):
                            count += 1
                
                # YoY comparisons
                for year in ["2024", "2025", "2026"]:
                    prev_year = str(int(year) - 1)
                    q = f"Compare {syn} {year} vs {prev_year}"
                    sql = f'SELECT "YEAR", SUM({column}) as {column} FROM {table} WHERE "YEAR" IN ({prev_year}, {year}) GROUP BY "YEAR" ORDER BY "YEAR"'
                    if self._add_example(q, sql, {"domain": domain, "type": "yoy", "term": term}):
                        count += 1
                
                # QoQ comparisons
                for q_pair in [("Q1", "Q2"), ("Q2", "Q3"), ("Q3", "Q4")]:
                    q = f"Compare {syn} {q_pair[0]} vs {q_pair[1]}"
                    sql = f"SELECT PERIOD, SUM({column}) as {column} FROM {table} WHERE PERIOD IN ('{q_pair[0]}', '{q_pair[1]}') GROUP BY PERIOD ORDER BY PERIOD"
                    if self._add_example(q, sql, {"domain": domain, "type": "qoq", "term": term}):
                        count += 1
        
        return count
    
    def generate_complex_queries(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate complex multi-condition queries."""
        count = 0
        tables = TABLES.get(domain, TABLES["performance"])
        
        for syn in synonyms[:8]:
            for table in tables[:3]:
                column = syn.upper().replace(" ", "_")

                # Multi-dimensional
                for segment in DIMENSIONS["segments"][:12]:
                    for year in ["2023", "2024", "2025"]:
                        q = f"What is the {syn} for {segment} in {year}?"
                        sql = f"SELECT SUM({column}) as {column} FROM {table} WHERE SEGMENT = '{segment}' AND YEAR = {year}"
                        if self._add_example(q, sql, {"domain": domain, "type": "complex", "term": term}):
                            count += 1
                
                # Group by multiple dimensions
                q = f"Show {syn} by segment and quarter"
                sql = f"SELECT SEGMENT, PERIOD, SUM({column}) as {column} FROM {table} GROUP BY SEGMENT, PERIOD ORDER BY SEGMENT, PERIOD"
                if self._add_example(q, sql, {"domain": domain, "type": "multi_group", "term": term}):
                    count += 1
                
                # Top N
                for n in [5, 10, 20]:
                    q = f"Top {n} segments by {syn}"
                    sql = f"SELECT TOP {n} SEGMENT, SUM({column}) as {column} FROM {table} GROUP BY SEGMENT ORDER BY SUM({column}) DESC"
                    if self._add_example(q, sql, {"domain": domain, "type": "top_n", "term": term}):
                        count += 1
        
        return count

    def generate_join_queries(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate multi-table JOIN queries using JOIN_SCHEMAS."""
        count = 0
        # Find applicable join schemas for this domain
        domain_joins = {
            "risk": ["risk_country", "risk_fx"],
            "treasury": ["treasury_fx", "treasury_product"],
            "performance": ["performance_account", "performance_entity", "performance_time"],
            "esg": ["esg_location"],
            "regulatory": ["regulatory_entity"],
            "consumer": ["consumer_segment"],
            "wealth": ["wealth_client"],
        }
        join_keys = domain_joins.get(domain, [])
        if not join_keys:
            return 0

        for syn in synonyms[:8]:
            column = syn.upper().replace(" ", "_")
            for jk in join_keys:
                js = JOIN_SCHEMAS[jk]
                fact_t = js["fact_table"]
                dim_t = js["dim_table"]
                jkey = js["join_key"]
                for dim_col in js["dim_cols"]:
                    for agg in ["SUM", "AVG"]:
                        alias = f"{agg}_{column}"
                        # Grouped by dimension
                        q = f"Show {syn} by {dim_col.lower().replace('_', ' ')} from {dim_t.split('.')[-1]}"
                        sql = (f"SELECT d.{dim_col}, {agg}(f.{column}) as {alias} "
                               f"FROM {fact_t} f JOIN {dim_t} d ON f.{jkey} = d.{jkey} "
                               f"GROUP BY d.{dim_col} ORDER BY {alias} DESC")
                        if self._add_example(q, sql, {"domain": domain, "type": "join", "term": term}):
                            count += 1

                    # Filtered join
                    for fval in DIMENSIONS["regions"][:8]:
                        q = f"What is the {syn} for {dim_col.lower().replace('_', ' ')} {fval}?"
                        sql = (f"SELECT SUM(f.{column}) as SUM_{column} "
                               f"FROM {fact_t} f JOIN {dim_t} d ON f.{jkey} = d.{jkey} "
                               f"WHERE d.{dim_col} = '{fval}'")
                        if self._add_example(q, sql, {"domain": domain, "type": "join_filter", "term": term}):
                            count += 1
        return count

    def generate_subquery_examples(self, term: str, synonyms: List[str], domain: str) -> int:
        """Generate CTE and subquery-based training examples."""
        count = 0
        tables = TABLES.get(domain, TABLES["performance"])

        for syn in synonyms[:6]:
            for table in tables[:2]:
                column = syn.upper().replace(" ", "_")

                # Above-average filter
                q = f"Show {syn} values above the average"
                sql = (f"SELECT {column} FROM {table} "
                       f"WHERE {column} > (SELECT AVG({column}) FROM {table})")
                if self._add_example(q, sql, {"domain": domain, "type": "subquery", "term": term}):
                    count += 1

                # CTE: segments above average
                for dim in ["SEGMENT", "REGION"]:
                    q = f"Which {dim.lower()}s have above-average {syn}?"
                    sql = (f"WITH base AS (SELECT {dim}, SUM({column}) as val "
                           f"FROM {table} GROUP BY {dim}) "
                           f"SELECT {dim}, val FROM base WHERE val > (SELECT AVG(val) FROM base) "
                           f"ORDER BY val DESC")
                    if self._add_example(q, sql, {"domain": domain, "type": "cte", "term": term}):
                        count += 1

                # Percentage of total using subquery
                q = f"What percentage of total {syn} does each segment represent?"
                sql = (f"SELECT SEGMENT, SUM({column}) as val, "
                       f"ROUND(100.0 * SUM({column}) / (SELECT SUM({column}) FROM {table}), 2) as pct "
                       f"FROM {table} GROUP BY SEGMENT ORDER BY pct DESC")
                if self._add_example(q, sql, {"domain": domain, "type": "subquery", "term": term}):
                    count += 1

        return count

    def generate_negative_examples(self) -> int:
        """Generate unanswerable / refusal training examples."""
        count = 0
        domain_terms_map = {
            "performance": ["revenue", "expense", "profit", "nii", "fee_income", "trading_income", "roe"],
            "balance_sheet": ["assets", "deposits", "loans", "npl", "provisions"],
            "treasury": ["forex", "bonds", "mtm", "pv01", "ftp", "notional"],
            "risk": ["var", "exposure", "ecl", "pd", "lgd", "stress_test"],
            "esg": ["carbon", "renewable", "esg_score", "financed_emissions"],
            "regulatory": ["rwa", "cet1", "lcr", "nsfr", "leverage_ratio"],
            "trade_finance": ["trade_finance", "payments", "guarantees"],
            "wealth": ["aum", "wealth_income"],
            "consumer": ["mortgage", "credit_card", "insurance"],
        }

        for template in NEGATIVE_TEMPLATES:
            for domain, terms in domain_terms_map.items():
                for term in terms:
                    syns = FINANCIAL_TERMS.get(term, [term])
                    table = TABLES.get(domain, TABLES["performance"])[0]

                    # Iterate over multiple synonyms and fake terms for scale
                    for syn in syns[:5]:
                        column = syn.upper().replace(" ", "_")
                        for fake_t in FAKE_TERMS[:10]:
                            for fake_d in FAKE_DIMS[:6]:
                                try:
                                    q = template["question"].format(
                                        term=syn, fake_term=fake_t,
                                        dim=random.choice(DIMENSIONS["segments"]),
                                        fake_dim=fake_d,
                                        domain=domain, table=table, column=column,
                                    )
                                    resp = template["response"].format(
                                        term=syn, fake_term=fake_t,
                                        fake_dim=fake_d, domain=domain,
                                    )
                                except (KeyError, IndexError):
                                    continue

                                h = self._hash_example(q.lower(), resp.lower())
                                if h not in self.seen_hashes:
                                    self.seen_hashes.add(h)
                                    self.generated_examples.append({
                                        "question": q,
                                        "sql": None,
                                        "response": resp,
                                        "domain": domain,
                                        "type": f"negative_{template['type']}",
                                        "term": term,
                                    })
                                    count += 1
        return count

    def generate_multi_turn_examples(self) -> int:
        """Generate multi-turn conversational training examples."""
        count = 0
        domain_terms_map = {
            "performance": ["revenue", "expense", "profit", "nii", "fee_income", "trading_income", "roe"],
            "balance_sheet": ["assets", "deposits", "loans", "npl", "provisions"],
            "treasury": ["forex", "bonds", "mtm", "pv01", "ftp", "notional"],
            "risk": ["var", "exposure", "ecl", "pd", "lgd", "stress_test"],
            "esg": ["carbon", "renewable", "esg_score", "financed_emissions"],
            "regulatory": ["rwa", "cet1", "lcr", "nsfr", "leverage_ratio"],
            "trade_finance": ["trade_finance", "payments", "guarantees"],
            "wealth": ["aum", "wealth_income"],
            "consumer": ["mortgage", "credit_card", "insurance"],
        }

        for conv_template in MULTI_TURN_TEMPLATES:
            for domain, terms in domain_terms_map.items():
                for term in terms:
                    syns = FINANCIAL_TERMS.get(term, [term])
                    tables = TABLES.get(domain, TABLES["performance"])

                    for syn in syns[:3]:
                        column = syn.upper().replace(" ", "_")
                        alias = f"SUM_{column}"
                        table = tables[0]

                        for dim in ["SEGMENT", "REGION", "PRODUCT", "CURRENCY"]:
                            for time_val in DIMENSIONS["time_periods"][:6]:
                                for fval in DIMENSIONS["segments"][:4]:
                                    try:
                                        turns = []
                                        for turn in conv_template["turns"]:
                                            t = {
                                                "role": turn["role"],
                                                "content": turn["content"].format(
                                                    term=syn, dim=dim.lower(),
                                                    time=time_val, column=column,
                                                    alias=alias, table=table,
                                                    filter_val=fval,
                                                ),
                                            }
                                            if "sql" in turn:
                                                t["sql"] = turn["sql"].format(
                                                    column=column, alias=alias,
                                                    table=table, dim=dim,
                                                    time=time_val, filter_val=fval,
                                                )
                                            turns.append(t)

                                        conv_hash = hashlib.md5(
                                            json.dumps(turns).encode()
                                        ).hexdigest()
                                        if conv_hash not in self.seen_hashes:
                                            self.seen_hashes.add(conv_hash)
                                            self.generated_examples.append({
                                                "turns": turns,
                                                "domain": domain,
                                                "type": f"multi_turn_{conv_template['type']}",
                                                "term": term,
                                            })
                                            count += 1
                                    except (KeyError, IndexError):
                                        continue
        return count

    def generate_schema_description_pairs(self, staging_csv_path: Optional[str] = None) -> int:
        """Generate schema-description training pairs from staging CSVs."""
        import csv as csv_mod
        count = 0

        csv_path = staging_csv_path or str(
            Path(__file__).parent.parent / "data" / "2_stagingschema.csv"
        )
        try:
            with open(csv_path, "r", encoding="utf-8-sig") as f:
                reader = csv_mod.reader(f)
                rows = list(reader)
        except FileNotFoundError:
            return 0

        if len(rows) < 3:
            return 0

        # Parse header (row 0 has ownership, row 2 has field names)
        header = rows[2] if len(rows) > 2 else rows[0]
        data_rows = rows[3:] if len(rows) > 3 else rows[1:]

        for row in data_rows[:5000]:  # Expanded for 500K target
            if len(row) < 9:
                continue
            use_case = row[1].strip() if row[1] else ""
            source_sys = row[2].strip() if row[2] else ""
            source_table = row[3].strip() if row[3] else ""
            source_field = row[4].strip() if row[4] else ""
            btp_schema = row[5].strip() if row[5] else ""
            btp_table = row[6].strip() if row[6] else ""
            btp_field = row[7].strip() if row[7] else ""
            description = row[8].strip() if row[8] else ""
            data_type = row[9].strip() if len(row) > 9 and row[9] else ""

            if not btp_table or not btp_field:
                continue

            full_table = f"{btp_schema}.{btp_table}" if btp_schema else btp_table

            # "Where is X?" style
            q = f"Where can I find {btp_field} data?"
            a = f"The field {btp_field} is in table {full_table}"
            if description:
                a += f". Description: {description}"
            if data_type:
                a += f". Data type: {data_type}"
            h = self._hash_example(q.lower(), a.lower())
            if h not in self.seen_hashes:
                self.seen_hashes.add(h)
                self.generated_examples.append({
                    "question": q, "response": a, "sql": None,
                    "domain": "schema", "type": "schema_lookup", "term": btp_field,
                })
                count += 1

            # Source mapping style
            if source_field and source_sys:
                q = f"What is the BTP equivalent of {source_field} from {source_sys}?"
                a = f"{source_field} from {source_sys} maps to {btp_field} in {full_table}"
                h = self._hash_example(q.lower(), a.lower())
                if h not in self.seen_hashes:
                    self.seen_hashes.add(h)
                    self.generated_examples.append({
                        "question": q, "response": a, "sql": None,
                        "domain": "schema", "type": "schema_mapping", "term": btp_field,
                    })
                    count += 1

            # Data type query
            if data_type:
                q = f"What is the data type of {btp_field} in {btp_table}?"
                a = f"{btp_field} in {btp_table} has data type {data_type}"
                h = self._hash_example(q.lower(), a.lower())
                if h not in self.seen_hashes:
                    self.seen_hashes.add(h)
                    self.generated_examples.append({
                        "question": q, "response": a, "sql": None,
                        "domain": "schema", "type": "schema_datatype", "term": btp_field,
                    })
                    count += 1

        return count

    def _add_real_example(self, question: str, sql: str, domain: str, ex_type: str, term: str = "") -> bool:
        """Add a real-schema training example with dedup."""
        sql = self._sanitize_sql(sql)
        h = self._hash_example(question.lower(), sql.lower())
        if h in self.seen_hashes:
            return False
        self.seen_hashes.add(h)
        self.generated_examples.append({
            "question": question, "sql": sql,
            "domain": domain, "type": ex_type, "term": term,
        })
        return True

    def _gen_treasury_queries(self, meta) -> int:
        """Generate queries against real Treasury column definitions."""
        count = 0
        # Real table name for Treasury bonds/securities
        table = "GLB_SECURITIES"
        countries = meta.treasury_filter_countries or ["UNITED KINGDOM", "HONG KONG", "SINGAPORE"]
        dates = meta.treasury_filter_dates or ["2025-03-31", "2025-02-28"]
        products = meta.treasury_filter_products or ["BOND", "ISSUANCE"]

        q_templates = [
            ("What is the total {biz} across all securities?",
             "SELECT SUM({col}) AS TOTAL_{col} FROM {table}"),
            ("Show {biz} by country",
             'SELECT GLB_FINAL_COUNTRY_NAME, SUM({col}) AS TOTAL_{col} FROM {table} GROUP BY GLB_FINAL_COUNTRY_NAME'),
            ("What is the average {biz} for {product} positions?",
             "SELECT AVG({col}) AS AVG_{col} FROM {table} WHERE GLB_PRODUCT_SUBTYPE = '{product}'"),
            ("Show {biz} for {country} as of {date}",
             "SELECT {col} FROM {table} WHERE GLB_FINAL_COUNTRY_NAME = '{country}' AND GLB_REPORT_DATE = '{date}'"),
            ("Compare {biz} between BOND and ISSUANCE",
             "SELECT GLB_PRODUCT_SUBTYPE, SUM({col}) AS TOTAL_{col} FROM {table} GROUP BY GLB_PRODUCT_SUBTYPE"),
            ("What are the top 10 issuers by {biz}?",
             'SELECT TOP 10 GLB_ISSUER_NAME, SUM({col}) AS TOTAL_{col} FROM {table} GROUP BY GLB_ISSUER_NAME ORDER BY TOTAL_{col} DESC'),
            ("Show {biz} by asset class",
             'SELECT GLB_ASSET_CLASS_2, SUM({col}) AS TOTAL_{col} FROM {table} GROUP BY GLB_ASSET_CLASS_2'),
            ("What is the {biz} for S&P rated AAA securities?",
             "SELECT SUM({col}) AS TOTAL_{col} FROM {table} WHERE GLB_ISSUE_RATING_SP = 'AAA'"),
            ("Show {biz} by region for {product} positions",
             "SELECT GLB_GLOBAL_REGION, SUM({col}) AS TOTAL_{col} FROM {table} WHERE GLB_PRODUCT_SUBTYPE = '{product}' GROUP BY GLB_GLOBAL_REGION"),
            ("What is the total {biz} for HQLA Level 1 assets?",
             "SELECT SUM({col}) AS TOTAL_{col} FROM {table} WHERE GLB_HQLA = '1'"),
        ]

        # Only use measure columns (numeric) for aggregation queries
        measure_cols = [c for c in meta.treasury_columns if c.technical_name.startswith("GLB_") and
                        any(k in c.technical_name for k in ["VALUE", "PRICE", "YIELD", "PV01", "DELTA", "RWA", "MTM", "NOTIONAL", "IMPACT", "ASW"])]
        if not measure_cols:
            measure_cols = meta.treasury_columns[-12:]  # last 12 are measures

        for col_def in measure_cols:
            col = col_def.technical_name
            biz = col_def.business_name
            for tpl_q, tpl_sql in q_templates:
                for country in countries[:4]:
                    for date in dates[:3]:
                        for product in products:
                            q = tpl_q.format(biz=biz, col=col, table=table, country=country, date=date, product=product)
                            s = tpl_sql.format(biz=biz, col=col, table=table, country=country, date=date, product=product)
                            if self._add_real_example(q, s, "treasury", "real_treasury", col):
                                count += 1

        # Dimension/lookup queries for all columns
        dim_cols = [c for c in meta.treasury_columns if c not in measure_cols]
        dim_templates = [
            ("What does the {col} field mean?",
             "SELECT DISTINCT {col} FROM {table} ORDER BY {col}"),
            ("List all unique values of {biz}",
             "SELECT DISTINCT {col}, COUNT(*) AS CNT FROM {table} GROUP BY {col} ORDER BY CNT DESC"),
            ("How many distinct {biz} values are there?",
             "SELECT COUNT(DISTINCT {col}) AS DISTINCT_COUNT FROM {table}"),
        ]
        for col_def in dim_cols:
            col = col_def.technical_name
            biz = col_def.business_name
            for tpl_q, tpl_sql in dim_templates:
                q = tpl_q.format(col=col, biz=biz, table=table)
                s = tpl_sql.format(col=col, biz=biz, table=table)
                if self._add_real_example(q, s, "treasury", "real_treasury_dim", col):
                    count += 1

        return count

    def _gen_esg_queries(self, meta) -> int:
        """Generate queries against real ESG field definitions."""
        count = 0
        models = {
            "Net Zero": ("ESG_NETZERO", meta.esg_netzero_fields),
            "Client": ("ESG_CLIENT", meta.esg_client_fields),
            "Sustainable": ("ESG_SUSTAINABLE_FINANCE", meta.esg_sustainable_fields),
        }

        q_templates = [
            ("What is the total {biz} in the {model} model?",
             "SELECT SUM({col}) AS TOTAL_{col} FROM {table}"),
            ("Show {biz} by booking location",
             "SELECT BE_LOCATION, SUM({col}) AS TOTAL_{col} FROM {table} GROUP BY BE_LOCATION"),
            ("What is the average {biz} by client tier?",
             "SELECT CLIENT_TIER, AVG({col}) AS AVG_{col} FROM {table} GROUP BY CLIENT_TIER"),
            ("Show the top 10 clients by {biz}",
             "SELECT TOP 10 CLIENT_NAME, {col} FROM {table} ORDER BY {col} DESC"),
            ("What is the {biz} for the CIB franchise segment?",
             "SELECT SUM({col}) AS TOTAL_{col} FROM {table} WHERE FRANCHISE_SEGMENT = 'CIB'"),
        ]

        for model_name, (table, fields) in models.items():
            for fld in fields:
                col = fld.technical_name
                biz = fld.business_name
                if not biz or not col:
                    continue
                for tpl_q, tpl_sql in q_templates:
                    q = tpl_q.format(biz=biz, col=col, table=table, model=model_name)
                    s = tpl_sql.format(biz=biz, col=col, table=table, model=model_name)
                    if self._add_real_example(q, s, "esg", f"real_esg_{model_name.lower().replace(' ', '_')}", col):
                        count += 1
        return count

    def _gen_performance_queries(self, meta) -> int:
        """Generate queries against the real CRD_FACT + NFRP star schema."""
        count = 0
        fact_table = "CRD_FACT"
        dim_tables = {
            "account": ("NFRP_ACCOUNT_AM", meta.account_hierarchy, "ACCOUNT"),
            "location": ("NFRP_LOCATION_AM", meta.location_hierarchy, "LOCATION"),
            "product": ("NFRP_PRODUCT_AM", meta.product_hierarchy, "PRODUCT"),
            "segment": ("NFRP_SEGMENT_AM", meta.segment_hierarchy, "M_SEGMENT"),
            "cost": ("NFRP_COST_AM", meta.cost_hierarchy, "COST_CLUSTER"),
        }
        measures = ["RESPECTIVE_CURRENCY", "CONSTANT_CURRENCY", "FORWARD_CURRENCY"]
        versions = ["MTD", "YTD"]
        indicators = ["CIB", "WRB", "FPNA"]

        # Star-schema JOIN queries
        for dim_name, (dim_table, hierarchy, col_prefix) in dim_tables.items():
            if not hierarchy:
                continue
            # Sample hierarchy values for L0 and L1
            l0_vals = sorted(set(n.levels.get("L0", "") for n in hierarchy if n.levels.get("L0")))[:8]
            l1_vals = sorted(set(n.levels.get("L1", "") for n in hierarchy if n.levels.get("L1")))[:8]

            for measure in measures:
                for version in versions:
                    for indicator in indicators:
                        # Aggregate by dimension L0
                        for l0 in l0_vals[:4]:
                            q = f"What is the total {measure.replace('_', ' ').lower()} for {l0} ({version}) in {indicator}?"
                            s = (f"SELECT d.\"{col_prefix} (L0)\", SUM(f.{measure}) AS TOTAL_{measure} "
                                 f"FROM {fact_table} f "
                                 f"JOIN {dim_table} d ON f.{col_prefix}_PK = d.{col_prefix}_PK "
                                 f"WHERE f.VERSION = '{version}' AND f.REPORTING = '{indicator}' "
                                 f"AND d.\"{col_prefix} (L0)\" = '{l0}' "
                                 f"GROUP BY d.\"{col_prefix} (L0)\"")
                            if self._add_real_example(q, s, "performance", f"real_perf_{dim_name}", measure):
                                count += 1

                        # Drill from L0 to L1
                        for l1 in l1_vals[:4]:
                            q = f"Break down {measure.replace('_', ' ').lower()} by {dim_name} level 1 for {indicator} {version}"
                            s = (f"SELECT d.\"{col_prefix} (L1)\", SUM(f.{measure}) AS TOTAL_{measure} "
                                 f"FROM {fact_table} f "
                                 f"JOIN {dim_table} d ON f.{col_prefix}_PK = d.{col_prefix}_PK "
                                 f"WHERE f.VERSION = '{version}' AND f.REPORTING = '{indicator}' "
                                 f"GROUP BY d.\"{col_prefix} (L1)\"")
                            if self._add_real_example(q, s, "performance", f"real_perf_{dim_name}_drill", measure):
                                count += 1

        # Cross-dimension queries (2 dimensions)
        dim_pairs = [("account", "location"), ("product", "segment"), ("account", "cost")]
        for d1_name, d2_name in dim_pairs:
            d1_table, d1_hier, d1_prefix = dim_tables[d1_name]
            d2_table, d2_hier, d2_prefix = dim_tables[d2_name]
            for measure in measures:
                for indicator in indicators:
                    q = (f"Show {measure.replace('_', ' ').lower()} by {d1_name} and {d2_name} "
                         f"for {indicator} YTD")
                    s = (f"SELECT d1.\"{d1_prefix} (L0)\", d2.\"{d2_prefix} (L0)\", "
                         f"SUM(f.{measure}) AS TOTAL_{measure} "
                         f"FROM {fact_table} f "
                         f"JOIN {d1_table} d1 ON f.{d1_prefix}_PK = d1.{d1_prefix}_PK "
                         f"JOIN {d2_table} d2 ON f.{d2_prefix}_PK = d2.{d2_prefix}_PK "
                         f"WHERE f.VERSION = 'YTD' AND f.REPORTING = '{indicator}' "
                         f"GROUP BY d1.\"{d1_prefix} (L0)\", d2.\"{d2_prefix} (L0)\"")
                    if self._add_real_example(q, s, "performance", "real_perf_cross_dim", measure):
                        count += 1

        # Budget vs Actual queries
        books = ["Actual", "Budget", "Forecast", "Outlook"]
        for measure in measures:
            for indicator in indicators:
                for book in books[1:]:  # compare against Actual
                    q = f"Compare {book} vs Actual {measure.replace('_', ' ').lower()} for {indicator} YTD"
                    s = (f"SELECT f.BOOKS, SUM(f.{measure}) AS TOTAL_{measure} "
                         f"FROM {fact_table} f "
                         f"WHERE f.REPORTING = '{indicator}' AND f.VERSION = 'YTD' "
                         f"AND f.BOOKS IN ('Actual', '{book}') "
                         f"GROUP BY f.BOOKS")
                    if self._add_real_example(q, s, "performance", "real_perf_budget_vs_actual", measure):
                        count += 1

        # Deeper hierarchy drill (L2, L3) for account and location
        for dim_name in ["account", "location"]:
            dim_table, hierarchy, col_prefix = dim_tables[dim_name]
            l2_vals = sorted(set(n.levels.get("L2", "") for n in hierarchy if n.levels.get("L2")))[:6]
            for measure in measures[:2]:
                for l2 in l2_vals:
                    for indicator in indicators:
                        q = f"Show {measure.replace('_', ' ').lower()} for {dim_name} '{l2}' in {indicator}"
                        s = (f"SELECT d.\"{col_prefix} (L2)\", SUM(f.{measure}) AS TOTAL_{measure} "
                             f"FROM {fact_table} f "
                             f"JOIN {dim_table} d ON f.{col_prefix}_PK = d.{col_prefix}_PK "
                             f"WHERE f.REPORTING = '{indicator}' AND d.\"{col_prefix} (L2)\" = '{l2}' "
                             f"GROUP BY d.\"{col_prefix} (L2)\"")
                        if self._add_real_example(q, s, "performance", f"real_perf_{dim_name}_l2", measure):
                            count += 1

        # Temporal queries with PERIOD_DATE
        for measure in measures:
            for indicator in indicators:
                q = f"Show monthly trend of {measure.replace('_', ' ').lower()} for {indicator}"
                s = (f"SELECT f.\"MONTH\", f.\"YEAR\", SUM(f.{measure}) AS TOTAL_{measure} "
                     f"FROM {fact_table} f "
                     f"WHERE f.REPORTING = '{indicator}' AND f.VERSION = 'MTD' "
                     f"GROUP BY f.\"MONTH\", f.\"YEAR\" ORDER BY f.\"YEAR\", f.\"MONTH\"")
                if self._add_real_example(q, s, "performance", "real_perf_temporal", measure):
                    count += 1

        # MEMO vs non-MEMO flag queries
        for measure in measures[:2]:
            for indicator in indicators:
                q = f"What is the {measure.replace('_', ' ').lower()} excluding memo lines for {indicator}?"
                s = (f"SELECT SUM(f.{measure}) AS TOTAL_{measure} FROM {fact_table} f "
                     f"WHERE f.REPORTING = '{indicator}' AND f.MEMO_FLAG != 'Memo' AND f.VERSION = 'YTD'")
                if self._add_real_example(q, s, "performance", "real_perf_memo_filter", measure):
                    count += 1

        return count

    def _gen_lineage_queries(self, meta) -> int:
        """Generate metadata/lineage queries from staging pipeline."""
        count = 0
        # Group mappings by BTP table
        table_fields: Dict[str, List] = {}
        table_sources: Dict[str, set] = {}
        for m in meta.staging_mappings:
            if m.btp_table:
                table_fields.setdefault(m.btp_table, []).append(m)
                if m.source_system:
                    table_sources.setdefault(m.btp_table, set()).add(m.source_system)

        # Metadata catalog table (conceptual — training the model to query a lineage catalog)
        cat_table = "DATA_LINEAGE_CATALOG"

        # Sample BTP tables (take up to 50 most-populated ones)
        top_tables = sorted(table_fields.keys(), key=lambda t: -len(table_fields[t]))[:50]

        for btp_table in top_tables:
            fields = table_fields[btp_table]
            sources = table_sources.get(btp_table, set())
            src_list = sorted(sources)

            # "What source system feeds X?"
            q = f"Which source system provides data for the {btp_table} table?"
            s = (f"SELECT DISTINCT SOURCE_SYSTEM FROM {cat_table} "
                 f"WHERE BTP_TABLE = '{btp_table}'")
            if self._add_real_example(q, s, "staging", "real_lineage_source", btp_table):
                count += 1

            # "What fields are in table X?"
            q = f"List all fields in the {btp_table} staging table"
            s = (f"SELECT BTP_FIELD, DATA_TYPE, DESCRIPTION FROM {cat_table} "
                 f"WHERE BTP_TABLE = '{btp_table}' ORDER BY BTP_FIELD")
            if self._add_real_example(q, s, "staging", "real_lineage_fields", btp_table):
                count += 1

            # "How many fields does X have?"
            q = f"How many fields does the {btp_table} table have?"
            s = (f"SELECT COUNT(*) AS FIELD_COUNT FROM {cat_table} "
                 f"WHERE BTP_TABLE = '{btp_table}'")
            if self._add_real_example(q, s, "staging", "real_lineage_count", btp_table):
                count += 1

            # Per-field lineage
            for fld in fields[:5]:  # top 5 fields per table
                if fld.btp_field and fld.source_field:
                    q = f"Where does the {fld.btp_field} field in {btp_table} come from?"
                    s = (f"SELECT SOURCE_SYSTEM, SOURCE_TABLE, SOURCE_FIELD "
                         f"FROM {cat_table} "
                         f"WHERE BTP_TABLE = '{btp_table}' AND BTP_FIELD = '{fld.btp_field}'")
                    if self._add_real_example(q, s, "staging", "real_lineage_field_origin", fld.btp_field):
                        count += 1

            # Source system → tables mapping
            for src in src_list[:2]:
                q = f"What tables does the {src} source system feed?"
                s = (f"SELECT DISTINCT BTP_TABLE FROM {cat_table} "
                     f"WHERE SOURCE_SYSTEM = '{src}' ORDER BY BTP_TABLE")
                if self._add_real_example(q, s, "staging", "real_lineage_system_tables", src):
                    count += 1

        # Validation enum queries
        for enum_name, vals in meta.validation_enums.items():
            q = f"What are the valid values for {enum_name}?"
            s = (f"SELECT DISTINCT \"{enum_name}\" FROM DATA_VALIDATION_RULES "
                 f"WHERE \"{enum_name}\" IS NOT NULL ORDER BY \"{enum_name}\"")
            if self._add_real_example(q, s, "staging", "real_lineage_validation", enum_name):
                count += 1

        return count

    def _gen_pipeline_ops_queries(self, meta) -> int:
        """Generate pipeline operations queries — cross-system data flow and completeness."""
        count = 0
        cat_table = "DATA_LINEAGE_CATALOG"
        reg_table = "DATA_REGISTER"
        val_table = "DATA_VALIDATION_RULES"

        # Group by use_case to get pipeline-level queries
        use_cases = set(m.use_case for m in meta.staging_mappings if m.use_case)
        src_systems = meta.source_systems

        for use_case in sorted(use_cases):
            # Pipeline completeness check
            q = f"How many fields are mapped in the {use_case} pipeline?"
            s = (f"SELECT USE_CASE, COUNT(*) AS MAPPED_FIELDS FROM {cat_table} "
                 f"WHERE USE_CASE = '{use_case}' GROUP BY USE_CASE")
            if self._add_real_example(q, s, "staging", "real_pipeline_completeness", use_case):
                count += 1

            # Source coverage per pipeline
            q = f"Which source systems feed the {use_case} pipeline?"
            s = (f"SELECT DISTINCT SOURCE_SYSTEM, COUNT(*) AS FIELD_COUNT FROM {cat_table} "
                 f"WHERE USE_CASE = '{use_case}' GROUP BY SOURCE_SYSTEM ORDER BY FIELD_COUNT DESC")
            if self._add_real_example(q, s, "staging", "real_pipeline_sources", use_case):
                count += 1

            # Unmapped fields (data quality)
            q = f"Are there any unmapped source fields in the {use_case} pipeline?"
            s = (f"SELECT SOURCE_SYSTEM, SOURCE_TABLE, SOURCE_FIELD FROM {cat_table} "
                 f"WHERE USE_CASE = '{use_case}' AND (BTP_FIELD IS NULL OR BTP_FIELD = '')")
            if self._add_real_example(q, s, "staging", "real_pipeline_unmapped", use_case):
                count += 1

        # Cross-system comparisons
        for src in src_systems:
            q = f"How many pipelines does {src} feed into?"
            s = (f"SELECT SOURCE_SYSTEM, COUNT(DISTINCT USE_CASE) AS PIPELINE_COUNT "
                 f"FROM {cat_table} WHERE SOURCE_SYSTEM = '{src}' GROUP BY SOURCE_SYSTEM")
            if self._add_real_example(q, s, "staging", "real_pipeline_system_reach", src):
                count += 1

            q = f"What is the total field count from {src} across all BTP tables?"
            s = (f"SELECT BTP_TABLE, COUNT(*) AS FIELD_COUNT FROM {cat_table} "
                 f"WHERE SOURCE_SYSTEM = '{src}' GROUP BY BTP_TABLE ORDER BY FIELD_COUNT DESC")
            if self._add_real_example(q, s, "staging", "real_pipeline_system_coverage", src):
                count += 1

        # Registration status
        q = "How many data products are registered by domain?"
        s = (f"SELECT DOMAIN, COUNT(*) AS PRODUCT_COUNT FROM {reg_table} "
             f"GROUP BY DOMAIN ORDER BY PRODUCT_COUNT DESC")
        if self._add_real_example(q, s, "staging", "real_pipeline_register", "register"):
            count += 1

        q = "Show all registered data products with their refresh frequency"
        s = (f"SELECT DATA_PRODUCT_NAME, DOMAIN, REFRESH_FREQUENCY, SENSITIVITY "
             f"FROM {reg_table} ORDER BY DOMAIN, DATA_PRODUCT_NAME")
        if self._add_real_example(q, s, "staging", "real_pipeline_register", "register_list"):
            count += 1

        # Data type distribution
        q = "What data types are used across all staging tables?"
        s = (f"SELECT DATA_TYPE, COUNT(*) AS FIELD_COUNT FROM {cat_table} "
             f"GROUP BY DATA_TYPE ORDER BY FIELD_COUNT DESC")
        if self._add_real_example(q, s, "staging", "real_pipeline_datatypes", "datatypes"):
            count += 1

        return count

    def generate_real_schema_queries(self) -> int:
        """Generate training pairs from real metadata across all 4 pipelines."""
        from schema_pipeline.real_schema_parser import load_all_metadata
        meta = load_all_metadata()
        count = 0

        # --- Pipeline 1: Treasury field queries ---
        count += self._gen_treasury_queries(meta)
        # --- Pipeline 2: ESG field queries ---
        count += self._gen_esg_queries(meta)
        # --- Pipeline 3: Performance star schema queries ---
        count += self._gen_performance_queries(meta)
        # --- Pipeline 4: Lineage / metadata queries ---
        count += self._gen_lineage_queries(meta)
        # --- Pipeline 5: Pipeline operations queries ---
        count += self._gen_pipeline_ops_queries(meta)

        return count

    def generate_all(self, verbose: bool = True) -> List[Dict]:
        """Generate all training examples including JOINs, negatives, multi-turn, and schema pairs."""
        total = 0

        # Domain mapping
        domain_terms = {
            "performance": [
                "revenue", "expense", "profit", "margin", "nii", "nim", "fee_income",
                "trading_income", "impairment", "cost_income_ratio", "roe", "dividend", "eps",
            ],
            "balance_sheet": [
                "assets", "liabilities", "equity", "deposits", "loans", "casa", "npl",
                "goodwill", "provisions",
            ],
            "treasury": [
                "forex", "derivatives", "swaps", "options", "bonds", "mtm", "hedge",
                "pv01", "ftp", "alm", "irrbb", "notional",
            ],
            "risk": [
                "var", "exposure", "credit_risk", "pd", "lgd", "ecl",
                "operational_risk", "market_risk", "stress_test",
            ],
            "esg": [
                "carbon", "scope1", "scope2", "scope3", "renewable",
                "esg_score", "sustainable_finance", "financed_emissions", "water", "waste",
            ],
            "regulatory": [
                "car", "cet1", "rwa", "lcr", "nsfr", "leverage_ratio",
                "tier2", "mrel", "large_exposure",
            ],
            "trade_finance": [
                "trade_finance", "cash_management", "payments", "guarantees",
            ],
            "wealth": [
                "aum", "wealth_income",
            ],
            "consumer": [
                "mortgage", "credit_card", "insurance",
            ],
        }

        for domain, terms in domain_terms.items():
            if verbose:
                print(f"\n=== Processing {domain.upper()} domain ===")

            for term in terms:
                if term not in FINANCIAL_TERMS:
                    continue

                synonyms = self.expand_term(term, FINANCIAL_TERMS[term])

                # Generate all query types (original + new)
                c1 = self.generate_simple_queries(term, synonyms, domain)
                c2 = self.generate_dimensional_queries(term, synonyms, domain)
                c3 = self.generate_filtered_queries(term, synonyms, domain)
                c4 = self.generate_comparison_queries(term, synonyms, domain)
                c5 = self.generate_complex_queries(term, synonyms, domain)
                c6 = self.generate_join_queries(term, synonyms, domain)
                c7 = self.generate_subquery_examples(term, synonyms, domain)

                term_total = c1 + c2 + c3 + c4 + c5 + c6 + c7
                total += term_total

                if verbose:
                    print(f"  {term}: {term_total} examples "
                          f"(simple={c1} dim={c2} filter={c3} comp={c4} "
                          f"complex={c5} join={c6} subquery={c7})")

        # Generate cross-cutting examples
        if verbose:
            print(f"\n=== Generating negative examples ===")
        neg_count = self.generate_negative_examples()
        total += neg_count
        if verbose:
            print(f"  Negatives: {neg_count}")

        if verbose:
            print(f"\n=== Generating multi-turn examples ===")
        mt_count = self.generate_multi_turn_examples()
        total += mt_count
        if verbose:
            print(f"  Multi-turn: {mt_count}")

        if verbose:
            print(f"\n=== Generating schema-description pairs ===")
        sd_count = self.generate_schema_description_pairs()
        total += sd_count
        if verbose:
            print(f"  Schema-description: {sd_count}")

        if verbose:
            print(f"\n=== Loading real prompt samples ===")
        rp_count = self.load_real_prompts()
        total += rp_count
        if verbose:
            print(f"  Real prompts: {rp_count}")

        if verbose:
            print(f"\n=== Merging specialist data ===")
        sp_count = self.merge_specialist_data()
        total += sp_count
        if verbose:
            print(f"  Specialist examples: {sp_count}")

        if verbose:
            print(f"\n=== Generating real-schema queries (4 pipelines) ===")
        rs_count = self.generate_real_schema_queries()
        total += rs_count
        if verbose:
            print(f"  Real-schema queries: {rs_count}")

        # Post-generation HANA SQL validation
        if verbose:
            print(f"\n=== Running HANA SQL validation ===")
        valid, invalid, warnings = self._validate_all_sql(verbose=verbose)

        # Tag every example with routing context + system_prompt
        if verbose:
            print(f"\n=== Applying semantic routing context ===")
        context_counts = self._apply_routing_context()
        if verbose:
            for ctx, cnt in sorted(context_counts.items()):
                print(f"  {ctx}: {cnt:,}")

        if verbose:
            print(f"\n=== TOTAL: {total} unique examples ===")
            print(f"  HANA valid: {valid:,}, invalid removed: {invalid:,}, with warnings: {warnings:,}")

        return self.generated_examples

    def _validate_all_sql(self, verbose: bool = False) -> Tuple[int, int, int]:
        """Run HANASQLValidator on all generated examples, removing invalid ones."""
        from schema_pipeline.sql_validator import HANASQLValidator
        validator = HANASQLValidator(strict=False)

        valid_count = 0
        invalid_count = 0
        warning_count = 0
        clean_examples = []
        error_types: Dict[str, int] = {}

        for ex in self.generated_examples:
            sql = ex.get("sql")
            if not sql:
                # Non-SQL examples (negatives, schema, multi-turn) pass through
                clean_examples.append(ex)
                continue

            report = validator.validate(sql)
            if report.is_valid:
                valid_count += 1
                if report.warning_count > 0:
                    warning_count += 1
                clean_examples.append(ex)
            else:
                invalid_count += 1
                for e in report.errors:
                    error_types[e.message] = error_types.get(e.message, 0) + 1

        if invalid_count > 0 and verbose:
            print(f"  Removed {invalid_count} invalid SQL examples:")
            for msg, cnt in sorted(error_types.items(), key=lambda x: -x[1]):
                print(f"    {cnt:6,}  {msg}")

        self.generated_examples = clean_examples
        return valid_count, invalid_count, warning_count

    def _apply_routing_context(self) -> Dict[str, int]:
        """Tag every example with a routing context and system_prompt.

        Uses the domain field to determine the routing context
        (analytics_ui vs data_quality vs pipeline_ops), then assigns
        the appropriate system prompt from ROUTING_CONTEXTS.
        """
        context_counts: Dict[str, int] = {}
        for ex in self.generated_examples:
            domain = ex.get("domain", "")
            ex_type = ex.get("type", "")

            # Determine routing context
            if ex_type.startswith("real_lineage_") or ex_type.startswith("real_pipeline_"):
                # Lineage and pipeline queries → data_quality or pipeline_ops
                if "pipeline" in ex_type or "register" in ex_type:
                    ctx = "pipeline_ops"
                else:
                    ctx = "data_quality"
            elif domain == "staging":
                ctx = "data_quality"
            elif domain == "schema":
                # Schema lookup could be either context — tag as data_quality
                ctx = "data_quality"
            else:
                ctx = DOMAIN_TO_CONTEXT.get(domain, "analytics_ui")

            # Select system prompt
            ctx_config = ROUTING_CONTEXTS.get(ctx, ROUTING_CONTEXTS["analytics_ui"])
            prompts = ctx_config["system_prompts"]

            # For analytics_ui, pick the domain-specific prompt if available
            if ctx == "analytics_ui":
                # Map broader domains to the 3 main system prompts
                prompt_key = domain
                if domain in ("balance_sheet", "regulatory"):
                    prompt_key = "performance"
                elif domain in ("risk", "trade_finance", "wealth", "consumer"):
                    prompt_key = "default"
                sys_prompt = prompts.get(prompt_key, prompts["default"])
            else:
                sys_prompt = prompts.get("default", "")

            ex["context"] = ctx
            ex["system_prompt"] = sys_prompt

            context_counts[ctx] = context_counts.get(ctx, 0) + 1

        return context_counts

    def merge_specialist_data(self, examples_per_specialist: int = 2000) -> int:
        """Generate specialist data and merge into the main dataset."""
        count = 0
        try:
            from schema_pipeline.specialist_data_generator import SpecialistDataGenerator
            gen = SpecialistDataGenerator()
            for gen_func in [
                gen.generate_performance_examples,
                gen.generate_balance_sheet_examples,
                gen.generate_treasury_examples,
                gen.generate_esg_examples,
            ]:
                batch = gen_func(examples_per_specialist)
                for ex in batch:
                    sql = ex.get("sql", "")
                    if sql:
                        ex["sql"] = self._sanitize_sql(sql)
                    q = ex.get("question", "")
                    s = ex.get("sql", "")
                    h = self._hash_example(q.lower(), (s or "").lower())
                    if h not in self.seen_hashes:
                        self.seen_hashes.add(h)
                        self.generated_examples.append(ex)
                        count += 1
        except ImportError:
            pass
        return count

    def load_real_prompts(self, prompts_path: Optional[str] = None, amplify: int = 20) -> int:
        """Load real prompt samples and amplify them with SQL variations.

        Each real prompt is paired with multiple plausible SQL targets
        (different tables, aggregations, time periods) to increase its
        weight in the training set.
        """
        count = 0
        path = prompts_path or str(
            Path(__file__).parent.parent / "data" / "massive_semantic" / "real_prompts.jsonl"
        )
        domain_table_map = {
            "treasury": TABLES.get("treasury", [])[:3],
            "esg": TABLES.get("esg", [])[:3],
            "performance": TABLES.get("performance", [])[:3],
        }
        aggs = ["SUM", "AVG", "COUNT"]
        periods = ["'YTD'", "'Q4 2024'", "'Q3 2024'", "'H1 2025'", "'FY 2024'"]

        try:
            with open(path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    ex = json.loads(line)
                    q = ex.get("question", "")
                    if not q:
                        continue
                    domain = ex.get("domain", "performance")

                    # Add the original prompt as-is
                    h = hashlib.md5(q.lower().encode()).hexdigest()
                    if h not in self.seen_hashes:
                        self.seen_hashes.add(h)
                        self.generated_examples.append(ex)
                        count += 1

                    # Amplify: generate SQL variations for this prompt
                    tables = domain_table_map.get(domain, TABLES["performance"][:2])
                    variations_added = 0
                    for table in tables:
                        for agg in aggs:
                            for period in periods:
                                if variations_added >= amplify:
                                    break
                                col = "AMOUNT"
                                alias = f"{agg}_{col}"
                                sql = f"SELECT {agg}({col}) as {alias} FROM {table} WHERE PERIOD = {period}"
                                variant = {
                                    "question": q,
                                    "sql": sql,
                                    "domain": domain,
                                    "type": "real_prompt_amplified",
                                    "source": ex.get("source", ""),
                                }
                                vh = self._hash_example(q.lower(), sql.lower())
                                if vh not in self.seen_hashes:
                                    self.seen_hashes.add(vh)
                                    self.generated_examples.append(variant)
                                    count += 1
                                    variations_added += 1
                            if variations_added >= amplify:
                                break
                        if variations_added >= amplify:
                            break
        except FileNotFoundError:
            pass
        return count
    
    def save(self, output_path: Path, format: str = "jsonl") -> None:
        """Save generated examples."""
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        if format == "jsonl":
            with open(output_path, 'w') as f:
                for ex in self.generated_examples:
                    f.write(json.dumps(ex) + "\n")
        elif format == "json":
            with open(output_path, 'w') as f:
                json.dump(self.generated_examples, f, indent=2)
        
        print(f"Saved {len(self.generated_examples)} examples to {output_path}")
    
    def get_statistics(self) -> Dict:
        """Get generation statistics."""
        stats = {
            "total_examples": len(self.generated_examples),
            "by_domain": {},
            "by_type": {},
            "by_term": {},
        }
        
        for ex in self.generated_examples:
            domain = ex.get("domain", "unknown")
            qtype = ex.get("type", "unknown")
            term = ex.get("term", "unknown")
            
            stats["by_domain"][domain] = stats["by_domain"].get(domain, 0) + 1
            stats["by_type"][qtype] = stats["by_type"].get(qtype, 0) + 1
            stats["by_term"][term] = stats["by_term"].get(term, 0) + 1
        
        return stats


def stratified_split(
    examples: List[Dict],
    train_ratio: float = 0.80,
    val_ratio: float = 0.10,
    test_ratio: float = 0.10,
    seed: int = 42,
) -> Tuple[List[Dict], List[Dict], List[Dict]]:
    """Split examples into train/val/test with stratification by domain×type.

    Ensures every domain×type combination is represented proportionally
    in all three splits.
    """
    assert abs(train_ratio + val_ratio + test_ratio - 1.0) < 1e-6

    rng = random.Random(seed)

    # Group by stratification key
    buckets: Dict[str, List[Dict]] = {}
    for ex in examples:
        key = f"{ex.get('domain', 'unknown')}|{ex.get('type', 'unknown')}"
        buckets.setdefault(key, []).append(ex)

    train, val, test = [], [], []
    for key in sorted(buckets.keys()):
        items = buckets[key]
        rng.shuffle(items)
        n = len(items)
        n_train = max(1, int(n * train_ratio))
        n_val = max(1, int(n * val_ratio)) if n > 2 else 0
        n_test = n - n_train - n_val

        train.extend(items[:n_train])
        val.extend(items[n_train:n_train + n_val])
        test.extend(items[n_train + n_val:])

    # Final shuffle within each split
    rng.shuffle(train)
    rng.shuffle(val)
    rng.shuffle(test)

    return train, val, test


def main():
    """Generate massive training data with stratified splits."""
    print("=" * 60)
    print("MASSIVE SEMANTIC TERM GENERATOR")
    print("Target: 500K+ examples with stratified train/val/test split")
    print("=" * 60)

    generator = MassiveTermGenerator()
    examples = generator.generate_all(verbose=True)

    # Save full dataset
    output_dir = Path(__file__).parent.parent / "data" / "massive_semantic"
    output_dir.mkdir(parents=True, exist_ok=True)

    generator.save(output_dir / "training_data.jsonl", format="jsonl")
    generator.save(output_dir / "training_data.json", format="json")

    # Stratified split
    print(f"\n=== STRATIFIED SPLIT (80/10/10) ===")
    train, val, test = stratified_split(examples)

    for split_name, split_data in [("train", train), ("val", val), ("test", test)]:
        path = output_dir / f"{split_name}.jsonl"
        with open(path, "w") as f:
            for ex in split_data:
                f.write(json.dumps(ex) + "\n")
        print(f"  {split_name}: {len(split_data):>8,} examples -> {path.name}")

    # Verify stratification
    from collections import Counter
    train_domains = Counter(e.get("domain", "") for e in train)
    val_domains = Counter(e.get("domain", "") for e in val)
    test_domains = Counter(e.get("domain", "") for e in test)
    print(f"\n  Domain distribution check:")
    for domain in sorted(set(train_domains) | set(val_domains) | set(test_domains)):
        t = train_domains.get(domain, 0)
        v = val_domains.get(domain, 0)
        ts = test_domains.get(domain, 0)
        total_d = t + v + ts
        print(f"    {domain:22s}  train={t:>6,} ({100*t/total_d:4.1f}%)  "
              f"val={v:>5,} ({100*v/total_d:4.1f}%)  "
              f"test={ts:>5,} ({100*ts/total_d:4.1f}%)")

    # Print statistics
    stats = generator.get_statistics()
    print(f"\n=== STATISTICS ===")
    print(f"Total examples: {stats['total_examples']:,}")
    print(f"\nBy domain:")
    for domain, count in sorted(stats['by_domain'].items()):
        print(f"  {domain}: {count:,}")
    print(f"\nBy query type:")
    for qtype, count in sorted(stats['by_type'].items()):
        print(f"  {qtype}: {count:,}")

    print(f"\n=== MODEL COVERAGE ===")
    print(f"Training examples: {stats['total_examples']:,}")
    print(f"Qwen2.5-0.5B (500M params): {stats['total_examples']/500_000_000*100:.4f}x coverage")


if __name__ == "__main__":
    main()