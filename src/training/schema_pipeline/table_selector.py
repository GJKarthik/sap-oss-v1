#!/usr/bin/env python3
"""
Table Selector for Text-to-SQL Query Routing.

Determines which HANA table(s) to query based on:
1. Query domain (P&L, Balance Sheet, Treasury, ESG)
2. Keyword matching
3. Semantic similarity
4. Table relationships

This complements the semantic_alias_extractor by providing
intelligent table routing for complex multi-table scenarios.
"""

import re
from typing import Dict, List, Optional, Set, Tuple
from dataclasses import dataclass, field
from enum import Enum


class QueryDomain(Enum):
    """Financial query domains."""
    PERFORMANCE = "performance"      # P&L, Income Statement
    BALANCE_SHEET = "balance_sheet"  # Assets, Liabilities, Equity
    TREASURY = "treasury"            # FX, Derivatives, Hedging
    ESG = "esg"                      # Carbon, Sustainability
    RISK = "risk"                    # VaR, Limits, Exposure
    GENERAL_LEDGER = "general_ledger"  # GL, Journal entries
    UNKNOWN = "unknown"


@dataclass
class TableInfo:
    """Information about a HANA table."""
    name: str
    schema: str
    domain: QueryDomain
    description: str = ""
    key_columns: List[str] = field(default_factory=list)
    measure_columns: List[str] = field(default_factory=list)
    dimension_columns: List[str] = field(default_factory=list)
    keywords: Set[str] = field(default_factory=set)
    related_tables: List[str] = field(default_factory=list)
    priority: int = 10  # Higher = more likely to be selected
    
    @property
    def full_name(self) -> str:
        return f"{self.schema}.{self.name}"


@dataclass
class TableSelectionResult:
    """Result of table selection."""
    primary_table: TableInfo
    secondary_tables: List[TableInfo] = field(default_factory=list)
    domain: QueryDomain = QueryDomain.UNKNOWN
    confidence: float = 0.0
    reasoning: str = ""
    joins: List[str] = field(default_factory=list)


class TableSelector:
    """
    Intelligent table selection for SAP HANA Text-to-SQL.
    
    Features:
    - Domain-based routing
    - Keyword matching
    - Multi-table join detection
    - Hierarchical table relationships
    """
    
    # Table registry
    TABLES: List[TableInfo] = [
        # P&L / Performance
        TableInfo(
            name="ZFI_FIN_OVER_AFO_CP_FIN",
            schema="BPC",
            domain=QueryDomain.PERFORMANCE,
            description="Consolidated P&L and financial overview",
            key_columns=["SEGMENT", "PERIOD", "YEAR", "VERSION"],
            measure_columns=["AMOUNT", "NII", "NIM_PCT", "PROFIT", "REVENUE"],
            dimension_columns=["SEGMENT", "REGION", "BUSINESS_LINE", "CURRENCY"],
            keywords={"p&l", "income", "revenue", "profit", "nii", "nim", "margin", "performance", "earnings", "financial"},
            priority=100
        ),
        TableInfo(
            name="ZFI_PL_DETAIL",
            schema="BPC",
            domain=QueryDomain.PERFORMANCE,
            description="Detailed P&L line items",
            key_columns=["ACCOUNT", "PERIOD", "YEAR"],
            measure_columns=["AMOUNT", "BUDGET", "VARIANCE"],
            dimension_columns=["ACCOUNT", "COST_CENTER", "SEGMENT"],
            keywords={"line item", "detail", "account", "budget", "variance"},
            priority=80
        ),
        
        # Balance Sheet
        TableInfo(
            name="ZFI_BS_SUMMARY",
            schema="BPC",
            domain=QueryDomain.BALANCE_SHEET,
            description="Balance sheet summary",
            key_columns=["BS_ITEM", "PERIOD", "YEAR"],
            measure_columns=["TOTAL_ASSETS", "TOTAL_LIABILITIES", "EQUITY", "DEPOSITS", "LOANS"],
            dimension_columns=["BS_ITEM", "ENTITY", "CURRENCY"],
            keywords={"balance sheet", "assets", "liabilities", "equity", "deposits", "loans", "capital", "bs"},
            priority=100
        ),
        TableInfo(
            name="ZFI_LOANS_DETAIL",
            schema="BPC",
            domain=QueryDomain.BALANCE_SHEET,
            description="Loan portfolio details",
            key_columns=["LOAN_ID", "CUSTOMER_ID"],
            measure_columns=["PRINCIPAL", "OUTSTANDING", "INTEREST_RATE", "PROVISION"],
            dimension_columns=["LOAN_TYPE", "SEGMENT", "RISK_RATING"],
            keywords={"loan", "lending", "credit", "provision", "npl"},
            priority=80
        ),
        
        # Treasury
        TableInfo(
            name="POSITION",
            schema="TREASURY",
            domain=QueryDomain.TREASURY,
            description="Treasury positions (FX, IRS, Derivatives)",
            key_columns=["DEAL_ID", "POSITION_TYPE"],
            measure_columns=["NOTIONAL", "MTM", "REALIZED_PNL", "UNREALIZED_PNL"],
            dimension_columns=["CURRENCY_PAIR", "COUNTERPARTY", "MATURITY_DATE", "POSITION_TYPE"],
            keywords={"treasury", "fx", "forex", "swap", "irs", "derivative", "mtm", "notional", "hedge", "position"},
            priority=100
        ),
        TableInfo(
            name="HEDGE_ACCOUNTING",
            schema="TREASURY",
            domain=QueryDomain.TREASURY,
            description="Hedge accounting and effectiveness",
            key_columns=["HEDGE_ID"],
            measure_columns=["HEDGE_EFFECTIVENESS_PCT", "INEFFECTIVE_PORTION"],
            dimension_columns=["HEDGE_TYPE", "HEDGED_ITEM"],
            keywords={"hedge", "effectiveness", "ifrs9", "cash flow hedge", "fair value hedge"},
            priority=90
        ),
        TableInfo(
            name="CASH_POSITION",
            schema="TREASURY",
            domain=QueryDomain.TREASURY,
            description="Cash and liquidity positions",
            key_columns=["CURRENCY", "ACCOUNT"],
            measure_columns=["BALANCE", "AVAILABLE"],
            dimension_columns=["CURRENCY", "BANK", "ACCOUNT_TYPE"],
            keywords={"cash", "liquidity", "balance", "funding"},
            priority=80
        ),
        
        # ESG / Sustainability
        TableInfo(
            name="ESG_METRICS",
            schema="SUSTAINABILITY",
            domain=QueryDomain.ESG,
            description="ESG and sustainability metrics",
            key_columns=["METRIC_ID", "PERIOD", "YEAR"],
            measure_columns=["CARBON_EMISSIONS", "SCOPE1", "SCOPE2", "SCOPE3", "RENEWABLE_PCT", "WATER_USAGE"],
            dimension_columns=["ENTITY", "REGION", "METRIC_TYPE"],
            keywords={"esg", "carbon", "emissions", "sustainability", "scope 1", "scope 2", "scope 3", "renewable", "climate", "environmental"},
            priority=100
        ),
        TableInfo(
            name="GREEN_BONDS",
            schema="SUSTAINABILITY",
            domain=QueryDomain.ESG,
            description="Green bond portfolio",
            key_columns=["BOND_ID"],
            measure_columns=["AMOUNT", "GREEN_IMPACT"],
            dimension_columns=["CATEGORY", "USE_OF_PROCEEDS"],
            keywords={"green bond", "sustainable finance", "impact"},
            priority=80
        ),
        
        # Risk
        TableInfo(
            name="VAR_DAILY",
            schema="RISK",
            domain=QueryDomain.RISK,
            description="Daily VaR calculations",
            key_columns=["RISK_TYPE", "DATE"],
            measure_columns=["VAR_95", "VAR_99", "ES_95"],
            dimension_columns=["RISK_TYPE", "PORTFOLIO", "DESK"],
            keywords={"var", "value at risk", "risk", "exposure", "limit"},
            priority=100
        ),
        TableInfo(
            name="CREDIT_EXPOSURE",
            schema="RISK",
            domain=QueryDomain.RISK,
            description="Credit risk exposure",
            key_columns=["COUNTERPARTY_ID"],
            measure_columns=["EXPOSURE", "PD", "LGD", "EL", "ECL"],
            dimension_columns=["COUNTERPARTY", "RATING", "SECTOR"],
            keywords={"credit risk", "counterparty", "ecl", "expected loss", "pd", "lgd"},
            priority=90
        ),
        
        # General Ledger
        TableInfo(
            name="ACDOCA",
            schema="GL",
            domain=QueryDomain.GENERAL_LEDGER,
            description="Universal Journal (GL line items)",
            key_columns=["BELNR", "BUZEI"],
            measure_columns=["HSL", "WSL", "MSL"],
            dimension_columns=["BUKRS", "RACCT", "RCNTR", "PRCTR", "SEGMENT"],
            keywords={"gl", "general ledger", "journal", "posting", "acdoca", "document"},
            priority=100
        ),
    ]
    
    def __init__(self):
        self._table_map = {t.full_name: t for t in self.TABLES}
        self._keyword_index = self._build_keyword_index()
    
    def _build_keyword_index(self) -> Dict[str, List[TableInfo]]:
        """Build inverted index from keywords to tables."""
        index: Dict[str, List[TableInfo]] = {}
        for table in self.TABLES:
            for keyword in table.keywords:
                if keyword not in index:
                    index[keyword] = []
                index[keyword].append(table)
        return index
    
    def select_table(self, query: str) -> TableSelectionResult:
        """
        Select the most appropriate table(s) for a query.
        
        Args:
            query: Natural language query
        
        Returns:
            TableSelectionResult with primary and secondary tables
        """
        query_lower = query.lower()
        
        # Score each table
        scores: Dict[str, float] = {}
        for table in self.TABLES:
            score = self._score_table(query_lower, table)
            if score > 0:
                scores[table.full_name] = score
        
        if not scores:
            # Default to P&L
            default_table = self._table_map.get("BPC.ZFI_FIN_OVER_AFO_CP_FIN", self.TABLES[0])
            return TableSelectionResult(
                primary_table=default_table,
                domain=QueryDomain.PERFORMANCE,
                confidence=0.3,
                reasoning="No specific table match, defaulting to P&L"
            )
        
        # Sort by score
        sorted_tables = sorted(scores.items(), key=lambda x: -x[1])
        
        # Get primary table
        primary_name, primary_score = sorted_tables[0]
        primary_table = self._table_map[primary_name]
        
        # Get secondary tables (for potential joins)
        secondary_tables = []
        for name, score in sorted_tables[1:3]:  # Top 2 secondary
            if score > primary_score * 0.5:  # At least 50% of primary score
                secondary_tables.append(self._table_map[name])
        
        # Detect if join is needed
        joins = self._detect_joins(query_lower, primary_table, secondary_tables)
        
        return TableSelectionResult(
            primary_table=primary_table,
            secondary_tables=secondary_tables,
            domain=primary_table.domain,
            confidence=min(1.0, primary_score / 10),
            reasoning=f"Matched keywords: {self._get_matched_keywords(query_lower, primary_table)}",
            joins=joins
        )
    
    def _score_table(self, query: str, table: TableInfo) -> float:
        """Score how well a table matches a query."""
        score = 0.0
        
        # Keyword matching
        for keyword in table.keywords:
            if keyword in query:
                # Longer keywords get higher scores
                score += len(keyword.split()) * 2
        
        # Column name matching
        for col in table.measure_columns + table.dimension_columns:
            col_lower = col.lower().replace("_", " ")
            if col_lower in query:
                score += 1.5
        
        # Apply priority weight
        score *= (table.priority / 100)
        
        return score
    
    def _get_matched_keywords(self, query: str, table: TableInfo) -> List[str]:
        """Get keywords that matched."""
        return [kw for kw in table.keywords if kw in query]
    
    def _detect_joins(
        self, 
        query: str, 
        primary: TableInfo, 
        secondary: List[TableInfo]
    ) -> List[str]:
        """Detect if joins are needed and generate join conditions."""
        joins = []
        
        # Cross-domain queries often need joins
        if secondary:
            for sec in secondary:
                if sec.domain != primary.domain:
                    # Different domains - likely need time-based join
                    join = f"JOIN {sec.full_name} ON {primary.schema}.PERIOD = {sec.schema}.PERIOD AND {primary.schema}.YEAR = {sec.schema}.YEAR"
                    joins.append(join)
        
        # Detect explicit comparison keywords
        comparison_keywords = ["compare", "versus", "vs", "and", "with"]
        for kw in comparison_keywords:
            if kw in query:
                # Query is asking for comparison - may need joins
                pass
        
        return joins
    
    def get_table_by_domain(self, domain: QueryDomain) -> List[TableInfo]:
        """Get all tables for a domain."""
        return [t for t in self.TABLES if t.domain == domain]
    
    def get_table_by_name(self, name: str) -> Optional[TableInfo]:
        """Get table by full name (schema.table)."""
        return self._table_map.get(name)
    
    def list_all_tables(self) -> List[str]:
        """List all table names."""
        return list(self._table_map.keys())


def main():
    """Demo table selection."""
    selector = TableSelector()
    
    test_queries = [
        "What is total revenue for Q1 2025?",
        "Show FX position by currency pair",
        "Carbon emissions by region",
        "Compare P&L with balance sheet assets",
        "VaR by risk type",
        "Hedge effectiveness for IRS",
        "Total deposits by segment",
    ]
    
    print("=" * 60)
    print("TABLE SELECTION DEMO")
    print("=" * 60)
    
    for query in test_queries:
        result = selector.select_table(query)
        print(f"\nQuery: {query}")
        print(f"  Primary: {result.primary_table.full_name}")
        print(f"  Domain: {result.domain.value}")
        print(f"  Confidence: {result.confidence:.2f}")
        if result.secondary_tables:
            print(f"  Secondary: {[t.full_name for t in result.secondary_tables]}")
        if result.joins:
            print(f"  Joins: {result.joins}")


if __name__ == "__main__":
    main()