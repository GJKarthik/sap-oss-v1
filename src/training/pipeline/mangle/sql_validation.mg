% =============================================================================
% SQL Validation Rules for generated HANA SQL queries
% Ensures generated SQL references valid schema objects and follows
% SAP HANA SQL dialect constraints.
% =============================================================================

% All tables referenced in SQL must exist in the schema registry
valid_table_ref(SqlId, Tab) :-
    sql_table_ref(SqlId, Tab),
    table_name(Tab).

invalid_table_ref(SqlId, Tab) :-
    sql_table_ref(SqlId, Tab),
    !table_name(Tab).

% All columns referenced in SQL must exist in their respective tables
valid_column_ref(SqlId, Tab, Col) :-
    sql_column_ref(SqlId, Tab, Col),
    table_column(Tab, Col, _, _).

invalid_column_ref(SqlId, Tab, Col) :-
    sql_column_ref(SqlId, Tab, Col),
    !table_column(Tab, Col, _, _).

% Aggregate functions must not wrap primary keys
invalid_aggregate(SqlId, AggFunc, Col, Tab) :-
    sql_aggregate(SqlId, AggFunc, Tab, Col),
    primary_key(Tab, Col),
    AggFunc != "COUNT".

% WHERE clause type consistency — string columns should use string ops
type_consistent_filter(SqlId) :-
    sql_filter(SqlId, Tab, Col, _Op, _Val),
    table_column(Tab, Col, _Type, _).

type_inconsistent_filter(SqlId, Tab, Col) :-
    sql_filter(SqlId, Tab, Col, _Op, _Val),
    !table_column(Tab, Col, _, _).

% HANA-specific: LIMIT requires ORDER BY
missing_order_with_limit(SqlId) :-
    sql_has_limit(SqlId),
    !sql_has_order_by(SqlId).

% SQL correctness: GROUP BY columns must appear in SELECT or aggregate
valid_group_by(SqlId) :-
    sql_group_by(SqlId, Col),
    sql_select_column(SqlId, Col).

invalid_group_by(SqlId, Col) :-
    sql_group_by(SqlId, Col),
    !sql_select_column(SqlId, Col),
    !sql_aggregate_column(SqlId, Col).

