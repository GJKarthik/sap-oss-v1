// Mangle: Aggregations - Aggregate Functions for Query Engine
//
// Converted from: kuzu aggregate semantics
//
// Purpose:
// Defines aggregate operations (COUNT, SUM, AVG, MIN, MAX, etc.)
// These compute summary values over groups of tuples.

// ============================================================================
// COUNT Aggregations
// ============================================================================

// Count all nodes with a given label
// count_nodes(Label, Count)
Decl count_nodes(label: String, count: i64).

count_nodes(L, fn:count<N>) :-
    node_label(N, L).

// Count all edges with a given type
// count_edges(Type, Count)
Decl count_edges(type_name: String, count: i64).

count_edges(T, fn:count<E>) :-
    edge_type(E, T).

// Count distinct values of a property
// count_distinct_property(Label, PropertyName, Count)
Decl count_distinct_property(label: String, property_name: String, count: i64).

count_distinct_property(L, P, fn:count<V>) :-
    node_label(N, L),
    node_property_int(N, P, V).

count_distinct_property(L, P, fn:count<V>) :-
    node_label(N, L),
    node_property_string(N, P, V).

// ============================================================================
// SUM Aggregations
// ============================================================================

// Sum integer property values for nodes with label
// sum_property_int(Label, PropertyName, Sum)
Decl sum_property_int(label: String, property_name: String, sum_value: i64).

sum_property_int(L, P, fn:sum<V>) :-
    node_label(N, L),
    node_property_int(N, P, V).

// Sum float property values
// sum_property_float(Label, PropertyName, Sum)
Decl sum_property_float(label: String, property_name: String, sum_value: f64).

sum_property_float(L, P, fn:sum<V>) :-
    node_label(N, L),
    node_property_float(N, P, V).

// ============================================================================
// AVG Aggregations
// ============================================================================

// Average integer property values
// avg_property_int(Label, PropertyName, Average)
Decl avg_property_int(label: String, property_name: String, avg_value: f64).

avg_property_int(L, P, fn:avg<V>) :-
    node_label(N, L),
    node_property_int(N, P, V).

// Average float property values
// avg_property_float(Label, PropertyName, Average)
Decl avg_property_float(label: String, property_name: String, avg_value: f64).

avg_property_float(L, P, fn:avg<V>) :-
    node_label(N, L),
    node_property_float(N, P, V).

// ============================================================================
// MIN/MAX Aggregations
// ============================================================================

// Minimum integer property value
// min_property_int(Label, PropertyName, MinValue)
Decl min_property_int(label: String, property_name: String, min_value: i64).

min_property_int(L, P, fn:min<V>) :-
    node_label(N, L),
    node_property_int(N, P, V).

// Maximum integer property value
// max_property_int(Label, PropertyName, MaxValue)
Decl max_property_int(label: String, property_name: String, max_value: i64).

max_property_int(L, P, fn:max<V>) :-
    node_label(N, L),
    node_property_int(N, P, V).

// Minimum float property value
// min_property_float(Label, PropertyName, MinValue)
Decl min_property_float(label: String, property_name: String, min_value: f64).

min_property_float(L, P, fn:min<V>) :-
    node_label(N, L),
    node_property_float(N, P, V).

// Maximum float property value
// max_property_float(Label, PropertyName, MaxValue)
Decl max_property_float(label: String, property_name: String, max_value: f64).

max_property_float(L, P, fn:max<V>) :-
    node_label(N, L),
    node_property_float(N, P, V).

// ============================================================================
// GROUP BY Aggregations
// ============================================================================

// Count nodes grouped by a property value
// count_by_property_int(Label, GroupProperty, GroupValue, Count)
Decl count_by_property_int(label: String, group_prop: String, group_value: i64, count: i64).

count_by_property_int(L, GP, GV, fn:count<N>) :-
    node_label(N, L),
    node_property_int(N, GP, GV).

// Sum grouped by another property
// sum_by_group(Label, GroupProperty, GroupValue, SumProperty, Sum)
Decl sum_by_group(label: String, group_prop: String, group_value: i64, sum_prop: String, sum_value: i64).

sum_by_group(L, GP, GV, SP, fn:sum<SV>) :-
    node_label(N, L),
    node_property_int(N, GP, GV),
    node_property_int(N, SP, SV).

// ============================================================================
// Edge Aggregations
// ============================================================================

// Count outgoing edges per node
// out_degree(NodeID, Degree)
Decl out_degree(node_id: i64, degree: i64).

out_degree(N, fn:count<E>) :-
    edge(E, _, N, _).

// Count incoming edges per node
// in_degree(NodeID, Degree)
Decl in_degree(node_id: i64, degree: i64).

in_degree(N, fn:count<E>) :-
    edge(E, _, _, N).

// Total degree (in + out)
// total_degree(NodeID, Degree)
Decl total_degree(node_id: i64, degree: i64).

total_degree(N, InD + OutD) :-
    in_degree(N, InD),
    out_degree(N, OutD).

// ============================================================================
// Path Aggregations
// ============================================================================

// Count paths between two labels via relationship type
// path_count(SrcLabel, RelType, DstLabel, Count)
Decl path_count(src_label: String, rel_type: String, dst_label: String, count: i64).

path_count(SL, RT, DL, fn:count<E>) :-
    node_label(S, SL),
    edge(E, _, S, D),
    edge_type(E, RT),
    node_label(D, DL).

// Average property value along edges
// avg_edge_property(RelType, PropertyName, Average)
Decl avg_edge_property(rel_type: String, property_name: String, avg_value: f64).

avg_edge_property(RT, P, fn:avg<V>) :-
    edge_type(E, RT),
    edge_property_float(E, P, V).