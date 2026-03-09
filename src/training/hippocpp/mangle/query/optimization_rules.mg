// Mangle: Query Optimization Rules
//
// Purpose:
// Defines rules for query plan optimization including join ordering,
// predicate pushdown, index selection, and cost estimation.

// ============================================================================
// Index Selection Rules
// ============================================================================

// A scan can use an index if one exists for the filtered column
Decl index_applicable(table_id: i64, column_id: i64, index_id: i64).

index_applicable(T, C, I) :-
    scan_filter(_, T, C, _),
    index_def(I, T, C, _).

// Prefer hash index for equality predicates
Decl prefer_hash_scan(table_id: i64, column_id: i64, index_id: i64).

prefer_hash_scan(T, C, I) :-
    scan_filter(_, T, C, "eq"),
    index_def(I, T, C, 0).  // 0 = HASH

// Prefer B-tree index for range predicates
Decl prefer_range_scan(table_id: i64, column_id: i64, index_id: i64).

prefer_range_scan(T, C, I) :-
    scan_filter(_, T, C, Op),
    Op != "eq",
    index_def(I, T, C, 1).  // 1 = BTREE

// ============================================================================
// Predicate Pushdown Rules
// ============================================================================

// A filter predicate can be pushed below a join
Decl pushable_predicate(predicate_id: i64, target_table: i64).

pushable_predicate(P, T) :-
    filter_predicate(P, T, _, _),
    join_node(_, T, _),
    !predicate_references_both(P).

// Predicate references columns from both join sides (cannot push)
Decl predicate_references_both(predicate_id: i64).

predicate_references_both(P) :-
    predicate_column(P, T1, _),
    predicate_column(P, T2, _),
    T1 != T2.

// ============================================================================
// Join Ordering Rules
// ============================================================================

// Estimated join cardinality (simplified)
Decl join_selectivity(table1: i64, table2: i64, selectivity: f64).

join_selectivity(T1, T2, Sel) :-
    rel_schema(_, T1, T2),
    table_cardinality(T1, Card1),
    table_cardinality(T2, Card2),
    Sel = 1.0 / fn:max_f64(fn:to_float(Card1), fn:to_float(Card2)).

// Small table should be on build side of hash join
Decl hash_join_build_side(join_id: i64, build_table: i64).

hash_join_build_side(J, T1) :-
    join_tables(J, T1, T2),
    table_cardinality(T1, C1),
    table_cardinality(T2, C2),
    C1 <= C2.

hash_join_build_side(J, T2) :-
    join_tables(J, T1, T2),
    table_cardinality(T1, C1),
    table_cardinality(T2, C2),
    C2 < C1.

// ============================================================================
// Scan Strategy Rules
// ============================================================================

// Full table scan is preferred when selectivity is low
Decl prefer_full_scan(table_id: i64).

prefer_full_scan(T) :-
    scan_filter(_, T, C, _),
    column_stats(T, C, DistinctCount, _),
    table_cardinality(T, TotalRows),
    TotalRows > 0,
    Selectivity = fn:to_float(DistinctCount) / fn:to_float(TotalRows),
    Selectivity > 0.3.

// Index scan preferred for highly selective predicates
Decl prefer_index_scan(table_id: i64, index_id: i64).

prefer_index_scan(T, I) :-
    index_applicable(T, C, I),
    column_stats(T, C, DistinctCount, _),
    table_cardinality(T, TotalRows),
    TotalRows > 0,
    Selectivity = fn:to_float(DistinctCount) / fn:to_float(TotalRows),
    Selectivity <= 0.3.

// ============================================================================
// Aggregation Optimization
// ============================================================================

// Aggregation can use index for MIN/MAX
Decl agg_uses_index(agg_id: i64, index_id: i64).

agg_uses_index(A, I) :-
    aggregation(A, T, C, AggType),
    index_def(I, T, C, 1),  // B-tree index
    AggType = "min".

agg_uses_index(A, I) :-
    aggregation(A, T, C, AggType),
    index_def(I, T, C, 1),
    AggType = "max".

// ============================================================================
// Base Fact Declarations
// ============================================================================

Decl scan_filter(filter_id: i64, table_id: i64, column_id: i64, op: String).
Decl filter_predicate(pred_id: i64, table_id: i64, column_id: i64, op: String).
Decl predicate_column(pred_id: i64, table_id: i64, column_id: i64).
Decl join_tables(join_id: i64, table1: i64, table2: i64).
Decl aggregation(agg_id: i64, table_id: i64, column_id: i64, agg_type: String).

