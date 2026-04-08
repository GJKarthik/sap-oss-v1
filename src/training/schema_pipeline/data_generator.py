#!/usr/bin/env python3
"""
data_generator.py

Generates 100K+ synthetic Text-to-SQL training examples per domain.
Uses schema definitions and templates to create diverse, validated examples.
"""
from __future__ import annotations

import json
import random
import re
from dataclasses import dataclass, field
from typing import Iterator
from pathlib import Path
from itertools import product

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from pipeline.team_context import TeamContext, GLOBAL_CONTEXT, COUNTRY_FILTER_VALUES


@dataclass
class Column:
    """Database column definition."""
    name: str
    data_type: str
    description: str = ""
    is_nullable: bool = True
    is_primary_key: bool = False
    foreign_key: str | None = None  # table.column format


@dataclass
class Table:
    """Database table definition."""
    schema: str
    name: str
    columns: list[Column]
    description: str = ""
    
    @property
    def full_name(self) -> str:
        return f"{self.schema}.{self.name}"


@dataclass 
class Domain:
    """Training domain with tables and query templates."""
    name: str
    description: str
    tables: list[Table]
    query_templates: list[dict]
    natural_language_patterns: list[str]


# =============================================================================
# SAP BTP Domain Definitions
# =============================================================================

BTP_FINANCIAL_DOMAIN = Domain(
    name="financial",
    description="Financial reporting and transaction data",
    tables=[
        Table(
            schema="BTP", name="FACT",
            columns=[
                Column("COB_DATE", "DATE", "Close of Business Date", is_nullable=False),
                Column("ENTITY_CODE", "VARCHAR(10)", "Legal Entity Code"),
                Column("COUNTRY_CODE", "VARCHAR(3)", "ISO Country Code"),
                Column("CURRENCY_CODE", "VARCHAR(3)", "ISO Currency Code"),
                Column("PRODUCT_CODE", "VARCHAR(20)", "Product Identifier"),
                Column("AMOUNT_USD", "DECIMAL(18,2)", "Amount in USD"),
                Column("AMOUNT_LOCAL", "DECIMAL(18,2)", "Amount in Local Currency"),
                Column("QUANTITY", "INTEGER", "Transaction Quantity"),
                Column("BOOKING_DATE", "DATE", "Transaction Booking Date"),
                Column("VALUE_DATE", "DATE", "Value Date"),
            ],
            description="Financial transactions fact table"
        ),
        Table(
            schema="BTP", name="DIM_ENTITY",
            columns=[
                Column("ENTITY_CODE", "VARCHAR(10)", "Entity Code", is_primary_key=True),
                Column("ENTITY_NAME", "VARCHAR(100)", "Full Entity Name"),
                Column("ENTITY_TYPE", "VARCHAR(20)", "Entity Type (BANK/SUBSIDIARY/BRANCH)"),
                Column("PARENT_ENTITY", "VARCHAR(10)", "Parent Entity Code"),
                Column("REGION", "VARCHAR(20)", "Geographic Region"),
                Column("COUNTRY_CODE", "VARCHAR(3)", "Country Code"),
                Column("STATUS", "VARCHAR(10)", "Entity Status (ACTIVE/INACTIVE)"),
            ],
            description="Entity dimension table"
        ),
        Table(
            schema="BTP", name="DIM_PRODUCT",
            columns=[
                Column("PRODUCT_CODE", "VARCHAR(20)", "Product Code", is_primary_key=True),
                Column("PRODUCT_NAME", "VARCHAR(100)", "Product Name"),
                Column("PRODUCT_TYPE", "VARCHAR(20)", "Product Type"),
                Column("PRODUCT_LINE", "VARCHAR(50)", "Product Line"),
                Column("IS_ACTIVE", "BOOLEAN", "Active Flag"),
            ],
            description="Product dimension table"
        ),
        Table(
            schema="BTP", name="DIM_TIME",
            columns=[
                Column("DATE_KEY", "DATE", "Date Key", is_primary_key=True),
                Column("YEAR", "INTEGER", "Year"),
                Column("QUARTER", "INTEGER", "Quarter (1-4)"),
                Column("MONTH", "INTEGER", "Month (1-12)"),
                Column("WEEK", "INTEGER", "Week of Year"),
                Column("DAY_OF_WEEK", "INTEGER", "Day of Week (1-7)"),
                Column("IS_HOLIDAY", "BOOLEAN", "Holiday Flag"),
                Column("FISCAL_YEAR", "INTEGER", "Fiscal Year"),
                Column("FISCAL_QUARTER", "INTEGER", "Fiscal Quarter"),
            ],
            description="Time dimension table"
        ),
    ],
    query_templates=[],  # Will be populated below
    natural_language_patterns=[]
)

BTP_RISK_DOMAIN = Domain(
    name="risk",
    description="Risk management and exposure data",
    tables=[
        Table(
            schema="BTP", name="CLIENT_MI",
            columns=[
                Column("COB_DATE", "DATE", "Close of Business Date"),
                Column("CLIENT_ID", "VARCHAR(20)", "Client Identifier"),
                Column("ENTITY_CODE", "VARCHAR(10)", "Entity Code"),
                Column("COUNTRY_CODE", "VARCHAR(3)", "Country Code"),
                Column("RWA", "DECIMAL(18,2)", "Risk-Weighted Assets"),
                Column("EAD", "DECIMAL(18,2)", "Exposure at Default"),
                Column("PD", "DECIMAL(8,6)", "Probability of Default"),
                Column("LGD", "DECIMAL(8,6)", "Loss Given Default"),
                Column("EXPECTED_LOSS", "DECIMAL(18,2)", "Expected Loss"),
                Column("RATING", "VARCHAR(5)", "Internal Rating"),
                Column("SECTOR", "VARCHAR(50)", "Industry Sector"),
            ],
            description="Client risk management information"
        ),
        Table(
            schema="BTP", name="CREDIT_LIMIT",
            columns=[
                Column("CLIENT_ID", "VARCHAR(20)", "Client Identifier"),
                Column("LIMIT_TYPE", "VARCHAR(20)", "Limit Type"),
                Column("LIMIT_AMOUNT", "DECIMAL(18,2)", "Limit Amount"),
                Column("UTILIZED_AMOUNT", "DECIMAL(18,2)", "Utilized Amount"),
                Column("AVAILABLE_AMOUNT", "DECIMAL(18,2)", "Available Amount"),
                Column("CURRENCY_CODE", "VARCHAR(3)", "Currency Code"),
                Column("EFFECTIVE_DATE", "DATE", "Effective Date"),
                Column("EXPIRY_DATE", "DATE", "Expiry Date"),
            ],
            description="Credit limit data"
        ),
        Table(
            schema="BTP", name="COLLATERAL",
            columns=[
                Column("COLLATERAL_ID", "VARCHAR(20)", "Collateral ID"),
                Column("CLIENT_ID", "VARCHAR(20)", "Client ID"),
                Column("COLLATERAL_TYPE", "VARCHAR(30)", "Type of Collateral"),
                Column("MARKET_VALUE", "DECIMAL(18,2)", "Current Market Value"),
                Column("HAIRCUT_PCT", "DECIMAL(5,2)", "Haircut Percentage"),
                Column("EFFECTIVE_VALUE", "DECIMAL(18,2)", "Effective Collateral Value"),
                Column("VALUATION_DATE", "DATE", "Last Valuation Date"),
            ],
            description="Collateral information"
        ),
    ],
    query_templates=[],
    natural_language_patterns=[]
)

BTP_ESG_DOMAIN = Domain(
    name="esg",
    description="ESG and sustainability metrics",
    tables=[
        Table(
            schema="BTP", name="ESG_METRIC",
            columns=[
                Column("COB_DATE", "DATE", "Reporting Date"),
                Column("ENTITY_CODE", "VARCHAR(10)", "Entity Code"),
                Column("CLIENT_ID", "VARCHAR(20)", "Client/Counterparty ID"),
                Column("NET_ZERO_SECTOR", "VARCHAR(50)", "Net Zero Sector Classification"),
                Column("FINANCED_EMISSION", "DECIMAL(18,4)", "Financed Emissions (tCO2e)"),
                Column("SCOPE1_EMISSION", "DECIMAL(18,4)", "Scope 1 Emissions"),
                Column("SCOPE2_EMISSION", "DECIMAL(18,4)", "Scope 2 Emissions"),
                Column("SCOPE3_EMISSION", "DECIMAL(18,4)", "Scope 3 Emissions"),
                Column("EMISSION_INTENSITY", "DECIMAL(12,6)", "Emission Intensity"),
                Column("GREEN_ASSET_RATIO", "DECIMAL(8,4)", "Green Asset Ratio"),
                Column("TRANSITION_RISK_SCORE", "DECIMAL(5,2)", "Transition Risk Score"),
                Column("PHYSICAL_RISK_SCORE", "DECIMAL(5,2)", "Physical Risk Score"),
            ],
            description="ESG and climate risk metrics"
        ),
        Table(
            schema="BTP", name="ESG_TARGET",
            columns=[
                Column("TARGET_ID", "VARCHAR(20)", "Target Identifier"),
                Column("SECTOR", "VARCHAR(50)", "Target Sector"),
                Column("TARGET_YEAR", "INTEGER", "Target Year"),
                Column("BASELINE_YEAR", "INTEGER", "Baseline Year"),
                Column("BASELINE_VALUE", "DECIMAL(18,4)", "Baseline Value"),
                Column("TARGET_VALUE", "DECIMAL(18,4)", "Target Value"),
                Column("CURRENT_VALUE", "DECIMAL(18,4)", "Current Value"),
                Column("METRIC_TYPE", "VARCHAR(30)", "Metric Type"),
            ],
            description="ESG targets and progress"
        ),
    ],
    query_templates=[],
    natural_language_patterns=[]
)

BTP_TREASURY_DOMAIN = Domain(
    name="treasury",
    description="Treasury and trading data",
    tables=[
        Table(
            schema="BTP", name="TREASURY_POSITION",
            columns=[
                Column("POSITION_ID", "VARCHAR(30)", "Position Identifier"),
                Column("COB_DATE", "DATE", "Close of Business Date"),
                Column("ENTITY_CODE", "VARCHAR(10)", "Entity Code"),
                Column("PRODUCT_CODE", "VARCHAR(20)", "Product Code"),
                Column("CURRENCY_CODE", "VARCHAR(3)", "Currency Code"),
                Column("NOTIONAL", "DECIMAL(18,2)", "Notional Amount"),
                Column("MARKET_VALUE", "DECIMAL(18,2)", "Mark-to-Market Value"),
                Column("DV01", "DECIMAL(18,6)", "Dollar Value of 01"),
                Column("DURATION", "DECIMAL(10,4)", "Modified Duration"),
                Column("CONVEXITY", "DECIMAL(10,4)", "Convexity"),
                Column("MATURITY_DATE", "DATE", "Maturity Date"),
                Column("COUNTERPARTY_ID", "VARCHAR(20)", "Counterparty Identifier"),
            ],
            description="Treasury position data"
        ),
        Table(
            schema="BTP", name="FX_RATE",
            columns=[
                Column("RATE_DATE", "DATE", "Rate Date"),
                Column("BASE_CURRENCY", "VARCHAR(3)", "Base Currency"),
                Column("QUOTE_CURRENCY", "VARCHAR(3)", "Quote Currency"),
                Column("SPOT_RATE", "DECIMAL(18,8)", "Spot Rate"),
                Column("RATE_SOURCE", "VARCHAR(20)", "Rate Source"),
            ],
            description="Foreign exchange rates"
        ),
        Table(
            schema="BTP", name="YIELD_CURVE",
            columns=[
                Column("CURVE_DATE", "DATE", "Curve Date"),
                Column("CURRENCY_CODE", "VARCHAR(3)", "Currency"),
                Column("TENOR", "VARCHAR(10)", "Tenor (1M, 3M, 6M, 1Y, etc)"),
                Column("RATE", "DECIMAL(10,6)", "Interest Rate"),
                Column("CURVE_TYPE", "VARCHAR(20)", "Curve Type (GOVT/SWAP/CORP)"),
            ],
            description="Yield curve data"
        ),
    ],
    query_templates=[],
    natural_language_patterns=[]
)


# =============================================================================
# Query Templates by Pattern Type
# =============================================================================

AGGREGATION_TEMPLATES = [
    {
        "pattern": "sum_by_dimension",
        "questions": [
            "What is the total {measure} by {dimension}?",
            "Show the sum of {measure} for each {dimension}",
            "Give me {measure} totals grouped by {dimension}",
            "Calculate total {measure} per {dimension}",
            "Aggregate {measure} by {dimension}",
        ],
        "sql_template": "SELECT {dimension_col}, SUM({measure_col}) AS total_{measure} FROM {table} GROUP BY {dimension_col}",
    },
    {
        "pattern": "avg_by_dimension",
        "questions": [
            "What is the average {measure} by {dimension}?",
            "Show average {measure} for each {dimension}",
            "Calculate mean {measure} per {dimension}",
        ],
        "sql_template": "SELECT {dimension_col}, AVG({measure_col}) AS avg_{measure} FROM {table} GROUP BY {dimension_col}",
    },
    {
        "pattern": "count_by_dimension",
        "questions": [
            "How many records per {dimension}?",
            "Count of entries by {dimension}",
            "Show record count for each {dimension}",
        ],
        "sql_template": "SELECT {dimension_col}, COUNT(*) AS count FROM {table} GROUP BY {dimension_col}",
    },
    {
        "pattern": "min_max_by_dimension",
        "questions": [
            "What are the min and max {measure} by {dimension}?",
            "Show {measure} range per {dimension}",
        ],
        "sql_template": "SELECT {dimension_col}, MIN({measure_col}) AS min_{measure}, MAX({measure_col}) AS max_{measure} FROM {table} GROUP BY {dimension_col}",
    },
]

FILTER_TEMPLATES = [
    {
        "pattern": "filter_equals",
        "questions": [
            "Show all records where {dimension} is '{value}'",
            "Find entries with {dimension} equal to '{value}'",
            "Get data for {dimension} = '{value}'",
            "List records for {dimension} '{value}'",
        ],
        "sql_template": "SELECT * FROM {table} WHERE {dimension_col} = '{value}'",
    },
    {
        "pattern": "filter_greater_than",
        "questions": [
            "Show records where {measure} is greater than {threshold}",
            "Find entries with {measure} above {threshold}",
            "Get data where {measure} > {threshold}",
            "List records with {measure} exceeding {threshold}",
        ],
        "sql_template": "SELECT * FROM {table} WHERE {measure_col} > {threshold}",
    },
    {
        "pattern": "filter_between",
        "questions": [
            "Show records where {measure} is between {min_val} and {max_val}",
            "Find entries with {measure} in range {min_val} to {max_val}",
        ],
        "sql_template": "SELECT * FROM {table} WHERE {measure_col} BETWEEN {min_val} AND {max_val}",
    },
    {
        "pattern": "filter_date_range",
        "questions": [
            "Show data for {date_col} between {start_date} and {end_date}",
            "Get records from {start_date} to {end_date}",
            "Find entries in date range {start_date} to {end_date}",
        ],
        "sql_template": "SELECT * FROM {table} WHERE {date_col} BETWEEN '{start_date}' AND '{end_date}'",
    },
]

TOP_N_TEMPLATES = [
    {
        "pattern": "top_n_by_measure",
        "questions": [
            "What are the top {n} {dimension} by {measure}?",
            "Show top {n} {dimension} ranked by {measure}",
            "List the {n} highest {dimension} based on {measure}",
            "Get top {n} {dimension} with highest {measure}",
        ],
        "sql_template": "SELECT {dimension_col}, SUM({measure_col}) AS total_{measure} FROM {table} GROUP BY {dimension_col} ORDER BY total_{measure} DESC LIMIT {n}",
    },
    {
        "pattern": "bottom_n_by_measure",
        "questions": [
            "What are the bottom {n} {dimension} by {measure}?",
            "Show lowest {n} {dimension} ranked by {measure}",
        ],
        "sql_template": "SELECT {dimension_col}, SUM({measure_col}) AS total_{measure} FROM {table} GROUP BY {dimension_col} ORDER BY total_{measure} ASC LIMIT {n}",
    },
]

JOIN_TEMPLATES = [
    {
        "pattern": "join_two_tables",
        "questions": [
            "Show {measure} with {dimension_name} details",
            "Get {measure} including {dimension_name} information",
            "List {measure} joined with {dimension_name}",
        ],
        "sql_template": "SELECT d.{dimension_name_col}, SUM(f.{measure_col}) AS total FROM {fact_table} f JOIN {dim_table} d ON f.{join_key} = d.{join_key} GROUP BY d.{dimension_name_col}",
    },
]

DATE_TEMPLATES = [
    {
        "pattern": "monthly_aggregation",
        "questions": [
            "Show monthly {measure} for {year}",
            "What is the {measure} by month in {year}?",
            "Get monthly breakdown of {measure} for year {year}",
        ],
        "sql_template": "SELECT EXTRACT(MONTH FROM {date_col}) AS month, SUM({measure_col}) AS total_{measure} FROM {table} WHERE EXTRACT(YEAR FROM {date_col}) = {year} GROUP BY EXTRACT(MONTH FROM {date_col}) ORDER BY month",
    },
    {
        "pattern": "quarterly_aggregation",
        "questions": [
            "Show quarterly {measure} for {year}",
            "What is the {measure} by quarter in {year}?",
        ],
        "sql_template": "SELECT CEIL(EXTRACT(MONTH FROM {date_col}) / 3.0) AS quarter, SUM({measure_col}) AS total_{measure} FROM {table} WHERE EXTRACT(YEAR FROM {date_col}) = {year} GROUP BY CEIL(EXTRACT(MONTH FROM {date_col}) / 3.0) ORDER BY quarter",
    },
    {
        "pattern": "year_over_year",
        "questions": [
            "Compare {measure} between {year1} and {year2}",
            "Show {measure} year-over-year for {year1} vs {year2}",
        ],
        "sql_template": "SELECT EXTRACT(YEAR FROM {date_col}) AS year, SUM({measure_col}) AS total_{measure} FROM {table} WHERE EXTRACT(YEAR FROM {date_col}) IN ({year1}, {year2}) GROUP BY EXTRACT(YEAR FROM {date_col}) ORDER BY year",
    },
]

WINDOW_TEMPLATES = [
    {
        "pattern": "running_total",
        "questions": [
            "Show running total of {measure} by {date_col}",
            "Calculate cumulative {measure} over time",
        ],
        "sql_template": "SELECT {date_col}, {measure_col}, SUM({measure_col}) OVER (ORDER BY {date_col}) AS running_total FROM {table}",
    },
    {
        "pattern": "rank_within_group",
        "questions": [
            "Rank {measure} within each {dimension}",
            "Show {measure} ranking by {dimension}",
        ],
        "sql_template": "SELECT {dimension_col}, {measure_col}, RANK() OVER (PARTITION BY {dimension_col} ORDER BY {measure_col} DESC) AS rank FROM {table}",
    },
]

CTE_TEMPLATES = [
    {
        "pattern": "cte_with_aggregation",
        "questions": [
            "Show {dimension} where total {measure} exceeds {threshold}",
            "Find {dimension} with {measure} above average",
        ],
        "sql_template": "WITH agg AS (SELECT {dimension_col}, SUM({measure_col}) AS total FROM {table} GROUP BY {dimension_col}) SELECT * FROM agg WHERE total > {threshold}",
    },
]


# =============================================================================
# Data Generator Class
# =============================================================================

class TrainingDataGenerator:
    """
    Generates large-scale synthetic Text-to-SQL training data.
    
    Target: 100K+ examples per domain.
    Supports optional TeamContext for country/domain-scoped generation.
    """
    
    def __init__(self, domains: list[Domain], seed: int = 42,
                 team_context: TeamContext | None = None):
        self.team_context = team_context or GLOBAL_CONTEXT
        
        # Filter domains by team context
        if self.team_context.domain:
            self.domains = {d.name: d for d in domains if d.name == self.team_context.domain}
        else:
            self.domains = {d.name: d for d in domains}
        
        self.random = random.Random(seed)
        
        # Sample values for substitution — scoped by team country when set
        if self.team_context.country:
            country_codes = [self.team_context.country]
        else:
            country_codes = ["US", "UK", "DE", "FR", "JP", "CN", "SG", "HK", "AU", "CA"]
        
        self.sample_values = {
            "country_codes": country_codes,
            "entity_types": ["BANK", "SUBSIDIARY", "BRANCH", "HOLDING"],
            "currencies": ["USD", "EUR", "GBP", "JPY", "CHF", "SGD", "HKD", "AUD"],
            "sectors": ["Energy", "Financials", "Technology", "Healthcare", "Consumer", "Industrial", "Materials", "Utilities"],
            "ratings": ["AAA", "AA+", "AA", "A+", "A", "BBB+", "BBB", "BB+", "BB"],
            "years": [2022, 2023, 2024, 2025],
            "months": list(range(1, 13)),
            "thresholds": [1000, 10000, 100000, 1000000, 10000000],
            "top_n": [3, 5, 10, 20, 50, 100],
        }
    
    def generate_all(self, examples_per_domain: int = 100000) -> dict[str, list[dict]]:
        """
        Generate training examples for all domains.
        
        Args:
            examples_per_domain: Target number of examples per domain
            
        Returns:
            Dict mapping domain name to list of training examples
        """
        results = {}
        
        for domain_name, domain in self.domains.items():
            print(f"Generating {examples_per_domain} examples for domain: {domain_name}")
            examples = list(self._generate_domain(domain, examples_per_domain))
            results[domain_name] = examples
            print(f"  Generated: {len(examples)} examples")
        
        return results
    
    def _generate_domain(self, domain: Domain, target_count: int) -> Iterator[dict]:
        """Generate examples for a single domain."""
        example_id = 0
        
        all_templates = (
            AGGREGATION_TEMPLATES + 
            FILTER_TEMPLATES + 
            TOP_N_TEMPLATES + 
            DATE_TEMPLATES +
            WINDOW_TEMPLATES +
            CTE_TEMPLATES
        )
        
        while example_id < target_count:
            template = self.random.choice(all_templates)
            
            for table in domain.tables:
                for example in self._apply_template(template, table, example_id):
                    if example_id >= target_count:
                        return
                    yield example
                    example_id += 1
    
    def _apply_template(self, template: dict, table: Table, base_id: int) -> Iterator[dict]:
        """Apply a template to a table to generate examples."""
        pattern = template["pattern"]
        
        # Get column categories
        measure_cols = [c for c in table.columns if c.data_type.startswith("DECIMAL") or c.data_type == "INTEGER"]
        dimension_cols = [c for c in table.columns if c.data_type.startswith("VARCHAR")]
        date_cols = [c for c in table.columns if c.data_type == "DATE"]
        
        if not measure_cols and "measure" in pattern:
            return
        if not dimension_cols and "dimension" in pattern:
            return
        if not date_cols and "date" in pattern:
            return
        
        # Generate variations
        for question_template in template["questions"]:
            sql_template = template["sql_template"]
            
            try:
                if "sum_by_dimension" in pattern or "avg_by_dimension" in pattern or "count_by_dimension" in pattern:
                    for measure_col in measure_cols[:3]:  # Limit variations
                        for dim_col in dimension_cols[:3]:
                            yield self._create_example(
                                base_id,
                                question_template,
                                sql_template,
                                table,
                                measure=measure_col.name.lower().replace("_", " "),
                                measure_col=measure_col.name,
                                dimension=dim_col.name.lower().replace("_", " "),
                                dimension_col=dim_col.name,
                            )
                
                elif "filter_equals" in pattern:
                    for dim_col in dimension_cols[:3]:
                        value = self._get_sample_value(dim_col.name)
                        yield self._create_example(
                            base_id,
                            question_template,
                            sql_template,
                            table,
                            dimension=dim_col.name.lower().replace("_", " "),
                            dimension_col=dim_col.name,
                            value=value,
                        )
                
                elif "filter_greater_than" in pattern:
                    for measure_col in measure_cols[:3]:
                        threshold = self.random.choice(self.sample_values["thresholds"])
                        yield self._create_example(
                            base_id,
                            question_template,
                            sql_template,
                            table,
                            measure=measure_col.name.lower().replace("_", " "),
                            measure_col=measure_col.name,
                            threshold=threshold,
                        )
                
                elif "top_n" in pattern:
                    for measure_col in measure_cols[:2]:
                        for dim_col in dimension_cols[:2]:
                            n = self.random.choice(self.sample_values["top_n"])
                            yield self._create_example(
                                base_id,
                                question_template,
                                sql_template,
                                table,
                                measure=measure_col.name.lower().replace("_", " "),
                                measure_col=measure_col.name,
                                dimension=dim_col.name.lower().replace("_", " "),
                                dimension_col=dim_col.name,
                                n=n,
                            )
                
                elif "monthly" in pattern or "quarterly" in pattern:
                    for measure_col in measure_cols[:2]:
                        for date_col in date_cols[:2]:
                            year = self.random.choice(self.sample_values["years"])
                            yield self._create_example(
                                base_id,
                                question_template,
                                sql_template,
                                table,
                                measure=measure_col.name.lower().replace("_", " "),
                                measure_col=measure_col.name,
                                date_col=date_col.name,
                                year=year,
                            )
                
                elif "running_total" in pattern or "rank" in pattern:
                    for measure_col in measure_cols[:2]:
                        for dim_col in dimension_cols[:2]:
                            date_col = date_cols[0] if date_cols else dim_col
                            yield self._create_example(
                                base_id,
                                question_template,
                                sql_template,
                                table,
                                measure=measure_col.name.lower().replace("_", " "),
                                measure_col=measure_col.name,
                                dimension=dim_col.name.lower().replace("_", " "),
                                dimension_col=dim_col.name,
                                date_col=date_col.name if date_cols else dim_col.name,
                            )
                
                elif "cte" in pattern:
                    for measure_col in measure_cols[:2]:
                        for dim_col in dimension_cols[:2]:
                            threshold = self.random.choice(self.sample_values["thresholds"])
                            yield self._create_example(
                                base_id,
                                question_template,
                                sql_template,
                                table,
                                measure=measure_col.name.lower().replace("_", " "),
                                measure_col=measure_col.name,
                                dimension=dim_col.name.lower().replace("_", " "),
                                dimension_col=dim_col.name,
                                threshold=threshold,
                            )
            
            except Exception as e:
                continue  # Skip failed generations
    
    def _create_example(self, base_id: int, question_template: str, sql_template: str, 
                        table: Table, **kwargs) -> dict:
        """Create a single training example."""
        kwargs["table"] = table.full_name
        
        question = question_template.format(**{k: v for k, v in kwargs.items() if "{" + k + "}" in question_template})
        sql = sql_template.format(**kwargs)
        
        return {
            "id": f"{table.schema}_{table.name}_{base_id}_{self.random.randint(1000,9999)}",
            "domain": table.schema,
            "table": table.full_name,
            "question": question,
            "sql": sql,
        }
    
    def _get_sample_value(self, column_name: str) -> str:
        """Get a sample value based on column name."""
        col_upper = column_name.upper()
        
        if "COUNTRY" in col_upper:
            return self.random.choice(self.sample_values["country_codes"])
        elif "CURRENCY" in col_upper:
            return self.random.choice(self.sample_values["currencies"])
        elif "SECTOR" in col_upper:
            return self.random.choice(self.sample_values["sectors"])
        elif "RATING" in col_upper:
            return self.random.choice(self.sample_values["ratings"])
        elif "TYPE" in col_upper:
            return self.random.choice(self.sample_values["entity_types"])
        else:
            return f"VALUE_{self.random.randint(1, 100)}"


def generate_training_data(
    output_dir: str = "data/training",
    examples_per_domain: int = 100000,
    validate: bool = True,
    team_context: TeamContext | None = None,
) -> dict[str, int]:
    """
    Generate and save training data for all domains.
    
    Args:
        output_dir: Directory to save training files
        examples_per_domain: Number of examples per domain
        validate: Whether to validate SQL queries
        team_context: Optional team context for scoped generation
        
    Returns:
        Dict mapping domain to example count
    """
    from pathlib import Path
    
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    # Initialize domains
    domains = [
        BTP_FINANCIAL_DOMAIN,
        BTP_RISK_DOMAIN,
        BTP_ESG_DOMAIN,
        BTP_TREASURY_DOMAIN,
    ]
    
    generator = TrainingDataGenerator(domains, team_context=team_context)
    if team_context and not team_context.is_global:
        print(f"Team context: {team_context.team_id}")
    all_data = generator.generate_all(examples_per_domain)
    
    # Optionally validate
    if validate:
        from sql_validator import HANASQLValidator
        validator = HANASQLValidator(strict=False)
        
        for domain_name, examples in all_data.items():
            valid_examples = []
            for ex in examples:
                report = validator.validate(ex["sql"])
                if report.is_valid:
                    valid_examples.append(ex)
            
            invalid_count = len(examples) - len(valid_examples)
            if invalid_count > 0:
                print(f"  {domain_name}: Filtered {invalid_count} invalid queries")
            
            all_data[domain_name] = valid_examples
    
    # Save files
    stats = {}
    for domain_name, examples in all_data.items():
        output_file = output_path / f"train_{domain_name}.json"
        with open(output_file, "w") as f:
            json.dump(examples, f, indent=2)
        
        stats[domain_name] = len(examples)
        print(f"Saved {len(examples)} examples to {output_file}")
    
    # Save combined file
    all_examples = []
    for examples in all_data.values():
        all_examples.extend(examples)
    
    combined_file = output_path / "train_all_domains.json"
    with open(combined_file, "w") as f:
        json.dump(all_examples, f, indent=2)
    
    print(f"\nTotal: {len(all_examples)} examples saved to {combined_file}")
    
    return stats


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Generate Text-to-SQL training data")
    parser.add_argument("--output-dir", default="data/training", help="Output directory")
    parser.add_argument("--examples", type=int, default=100000, help="Examples per domain")
    parser.add_argument("--no-validate", action="store_true", help="Skip validation")
    parser.add_argument("--team", type=str, default="", help="Team context (e.g. 'AE:treasury')")
    
    args = parser.parse_args()
    
    team_ctx = TeamContext.from_cli(args.team) if args.team else None
    
    stats = generate_training_data(
        output_dir=args.output_dir,
        examples_per_domain=args.examples,
        validate=not args.no_validate,
        team_context=team_ctx,
    )
    
    print("\nGeneration Summary:")
    for domain, count in stats.items():
        print(f"  {domain}: {count:,} examples")