// Mangle: Rules - Derived Relations and Query Rules
//
// Converted from: kuzu query semantics
//
// Purpose:
// Defines derived relations (intensional database) computed from base facts.
// Implements graph traversals, pattern matching, and query operators.

// ============================================================================
// Graph Traversal Rules
// ============================================================================

// Direct neighbor via any edge
// neighbor(NodeA, NodeB)
Decl neighbor(node_a: i64, node_b: i64).

neighbor(A, B) :- edge(_, _, A, B).
neighbor(A, B) :- edge(_, _, B, A).  // undirected

// One-hop outgoing neighbor
// out_neighbor(Src, Dst)
Decl out_neighbor(src: i64, dst: i64).

out_neighbor(S, D) :- edge(_, _, S, D).

// One-hop incoming neighbor
// in_neighbor(Src, Dst) - Dst has edge pointing to Src
Decl in_neighbor(src: i64, dst: i64).

in_neighbor(S, D) :- edge(_, _, D, S).

// Two-hop path
// two_hop(Start, End)
Decl two_hop(start: i64, end: i64).

two_hop(A, C) :-
    edge(_, _, A, B),
    edge(_, _, B, C).

// Three-hop path
// three_hop(Start, End)
Decl three_hop(start: i64, end: i64).

three_hop(A, D) :-
    edge(_, _, A, B),
    edge(_, _, B, C),
    edge(_, _, C, D).

// ============================================================================
// Variable-Length Path Rules
// ============================================================================

// Reachable within N hops (transitive closure)
// reachable(Src, Dst)
Decl reachable(src: i64, dst: i64).

// Base case: direct edge
reachable(S, D) :- edge(_, _, S, D).

// Recursive case: transitivity
reachable(S, D) :-
    edge(_, _, S, M),
    reachable(M, D).

// Reachable via specific relationship type
// reachable_via(Src, RelType, Dst)
Decl reachable_via(src: i64, rel_type: String, dst: i64).

reachable_via(S, RT, D) :-
    edge(E, _, S, D),
    edge_type(E, RT).

reachable_via(S, RT, D) :-
    edge(E, _, S, M),
    edge_type(E, RT),
    reachable_via(M, RT, D).

// ============================================================================
// Typed Path Rules
// ============================================================================

// Nodes connected by specific edge type
// connected_by(NodeA, EdgeType, NodeB)
Decl connected_by(node_a: i64, edge_type_name: String, node_b: i64).

connected_by(A, T, B) :-
    edge(E, _, A, B),
    edge_type(E, T).

// Pattern: (A:Label1)-[r:Type]->(B:Label2)
// typed_pattern(SrcNodeID, SrcLabel, EdgeType, DstNodeID, DstLabel)
Decl typed_pattern(src_id: i64, src_label: String, edge_type: String, dst_id: i64, dst_label: String).

typed_pattern(S, SL, ET, D, DL) :-
    node_label(S, SL),
    edge(E, _, S, D),
    edge_type(E, ET),
    node_label(D, DL).

// ============================================================================
// Filtering Rules
// ============================================================================

// Nodes with property equal to value
// node_with_int_property(Label, PropertyName, Value, NodeID)
Decl node_with_int_property(label: String, prop: String, value: i64, node_id: i64).

node_with_int_property(L, P, V, N) :-
    node_label(N, L),
    node_property_int(N, P, V).

// Nodes with property greater than value
// node_gt_property(Label, PropertyName, Threshold, NodeID)
Decl node_gt_property(label: String, prop: String, threshold: i64, node_id: i64).

node_gt_property(L, P, T, N) :-
    node_label(N, L),
    node_property_int(N, P, V),
    V > T.

// Nodes with property less than value
// node_lt_property(Label, PropertyName, Threshold, NodeID)
Decl node_lt_property(label: String, prop: String, threshold: i64, node_id: i64).

node_lt_property(L, P, T, N) :-
    node_label(N, L),
    node_property_int(N, P, V),
    V < T.

// Nodes with property in range
// node_in_range(Label, PropertyName, Min, Max, NodeID)
Decl node_in_range(label: String, prop: String, min_val: i64, max_val: i64, node_id: i64).

node_in_range(L, P, MinV, MaxV, N) :-
    node_label(N, L),
    node_property_int(N, P, V),
    V >= MinV,
    V <= MaxV.

// ============================================================================
// Join Rules
// ============================================================================

// Inner join on property
// join_on_property(Label1, Prop1, Label2, Prop2, Node1ID, Node2ID)
Decl join_on_property(l1: String, p1: String, l2: String, p2: String, n1: i64, n2: i64).

join_on_property(L1, P, L2, P, N1, N2) :-
    node_label(N1, L1),
    node_property_int(N1, P, V),
    node_label(N2, L2),
    node_property_int(N2, P, V),
    N1 != N2.

// Semi-join: nodes that have at least one edge of type
// has_outgoing(NodeID, EdgeType)
Decl has_outgoing(node_id: i64, edge_type: String).

has_outgoing(N, T) :-
    edge(E, _, N, _),
    edge_type(E, T).

// Anti-join: nodes without any edges of type
// no_outgoing(NodeID, Label, EdgeType)
Decl no_outgoing(node_id: i64, label: String, edge_type: String).

no_outgoing(N, L, T) :-
    node_label(N, L),
    !has_outgoing(N, T).

// ============================================================================
// Projection Rules
// ============================================================================

// Project node with selected properties
// node_projection(NodeID, Label, PropName1, PropValue1, PropName2, PropValue2)
Decl node_projection_2(node_id: i64, label: String, p1: String, v1: i64, p2: String, v2: i64).

node_projection_2(N, L, P1, V1, P2, V2) :-
    node_label(N, L),
    node_property_int(N, P1, V1),
    node_property_int(N, P2, V2).

// ============================================================================
// Pattern Matching Rules
// ============================================================================

// Triangle pattern: A-B-C-A
// triangle(NodeA, NodeB, NodeC)
Decl triangle(a: i64, b: i64, c: i64).

triangle(A, B, C) :-
    edge(_, _, A, B),
    edge(_, _, B, C),
    edge(_, _, C, A),
    A < B, B < C.  // avoid duplicates

// Star pattern: central node connected to N others
// star_center(CenterNode, SatelliteCount)
Decl star_center(center: i64, count: i64).

star_center(C, fn:count<S>) :-
    edge(_, _, C, S).

// Chain pattern: A -> B -> C -> D (4-hop)
// chain_4(A, B, C, D)
Decl chain_4(a: i64, b: i64, c: i64, d: i64).

chain_4(A, B, C, D) :-
    edge(_, _, A, B),
    edge(_, _, B, C),
    edge(_, _, C, D).

// ============================================================================
// Shortest Path Rules
// ============================================================================

// Shortest path distance (BFS-style with level)
// shortest_distance(Src, Dst, Distance)
Decl shortest_distance(src: i64, dst: i64, distance: i64).

// Base: direct edge = distance 1
shortest_distance(S, D, 1) :- edge(_, _, S, D).

// Recursive: find minimum distance
// Note: Mangle handles stratification for aggregates over recursion
shortest_distance(S, D, Dist + 1) :-
    shortest_distance(S, M, Dist),
    edge(_, _, M, D),
    !shorter_path_exists(S, D, Dist + 1).

// Helper: check if shorter path exists
Decl shorter_path_exists(src: i64, dst: i64, max_dist: i64).

shorter_path_exists(S, D, MaxD) :-
    shortest_distance(S, D, D2),
    D2 < MaxD.

// ============================================================================
// Common Subgraph Rules
// ============================================================================

// Common neighbors of two nodes
// common_neighbor(NodeA, NodeB, CommonNode)
Decl common_neighbor(a: i64, b: i64, common: i64).

common_neighbor(A, B, C) :-
    edge(_, _, A, C),
    edge(_, _, B, C),
    A != B, A != C, B != C.

// Count of common neighbors (for similarity)
// common_neighbor_count(NodeA, NodeB, Count)
Decl common_neighbor_count(a: i64, b: i64, count: i64).

common_neighbor_count(A, B, fn:count<C>) :-
    common_neighbor(A, B, C).

// ============================================================================
// Subgraph Extraction Rules
// ============================================================================

// Induced subgraph - all nodes within N hops of seed
// subgraph_node(SeedNode, MaxHops, NodeInSubgraph)
Decl subgraph_node_1hop(seed: i64, node: i64).

subgraph_node_1hop(Seed, Seed).  // include seed
subgraph_node_1hop(Seed, N) :- edge(_, _, Seed, N).
subgraph_node_1hop(Seed, N) :- edge(_, _, N, Seed).

Decl subgraph_node_2hop(seed: i64, node: i64).

subgraph_node_2hop(Seed, N) :- subgraph_node_1hop(Seed, N).
subgraph_node_2hop(Seed, N2) :-
    subgraph_node_1hop(Seed, N1),
    edge(_, _, N1, N2).

// ============================================================================
// Query Result Rules
// ============================================================================

// Query result with ordering by property
// Descending order rank by property value
// top_nodes_by_property(Label, PropertyName, NodeID, Value, Rank)
Decl top_nodes_by_property(label: String, prop: String, node_id: i64, value: i64, rank: i64).

top_nodes_by_property(L, P, N, V, R) :-
    node_label(N, L),
    node_property_int(N, P, V),
    R = fn:dense_rank<V>.