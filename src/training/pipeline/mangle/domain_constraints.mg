% =============================================================================
% Domain Constraints for Banking / Financial text-to-SQL pairs
% Ensures training data respects business domain rules.
% =============================================================================

% Treasury domain: bond positions must reference ISIN
treasury_bond_query(SqlId) :-
    sql_domain(SqlId, "TREASURY"),
    sql_table_ref(SqlId, Tab),
    bond_position_table(Tab).

bond_position_table("BOND_POSITIONS").
bond_position_table("BOND_CASHFLOWS").
bond_position_table("FX_POSITIONS").

% Treasury queries about ISIN must filter on ISIN column
isin_query_has_filter(SqlId) :-
    question_mentions_isin(SqlId),
    sql_filter(SqlId, _Tab, "ISIN", _, _).

isin_query_missing_filter(SqlId) :-
    question_mentions_isin(SqlId),
    !isin_query_has_filter(SqlId).

% ESG domain: sustainability queries must reference ESG tables
esg_query(SqlId) :-
    sql_domain(SqlId, "ESG"),
    sql_table_ref(SqlId, Tab),
    esg_table(Tab).

esg_table("ESG_SCORES").
esg_table("ESG_EMISSIONS").
esg_table("ESG_RATINGS").
esg_table("ESG_TAXONOMY").

% Performance domain: NFRP queries must join dimension tables
nfrp_query_with_dimension(SqlId) :-
    sql_domain(SqlId, "PERFORMANCE"),
    sql_table_ref(SqlId, "NFRP_FACT"),
    sql_table_ref(SqlId, DimTab),
    nfrp_dimension_table(DimTab).

nfrp_dimension_table("NFRP_Account").
nfrp_dimension_table("NFRP_Product").
nfrp_dimension_table("NFRP_Location").
nfrp_dimension_table("NFRP_Cost").
nfrp_dimension_table("NFRP_Segment").

% Hierarchy queries should specify a valid level
valid_hierarchy_level(SqlId, DimTab, Level) :-
    sql_hierarchy_ref(SqlId, DimTab, Level),
    hierarchy_level(DimTab, Level).

invalid_hierarchy_level(SqlId, DimTab, Level) :-
    sql_hierarchy_ref(SqlId, DimTab, Level),
    !hierarchy_level(DimTab, Level).

% Amount columns must use appropriate aggregation
amount_column_aggregated(SqlId, Col) :-
    amount_column(Col),
    sql_aggregate(SqlId, _Agg, _Tab, Col).

amount_column_not_aggregated(SqlId, Col) :-
    amount_column(Col),
    sql_select_column(SqlId, Col),
    !amount_column_aggregated(SqlId, Col).

amount_column("MTM").
amount_column("NOTIONAL").
amount_column("EXPOSURE").
amount_column("PNL").
amount_column("REVENUE").
amount_column("COST").
amount_column("BALANCE").

