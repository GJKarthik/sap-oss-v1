// Mangle: Catalog Schema Rules
//
// Purpose:
// Defines invariants and derived relations for database catalog/schema management.
// Ensures referential integrity, schema consistency, and DDL validation.

// ============================================================================
// Schema Completeness Rules
// ============================================================================

// A node table is complete if it has a primary key
Decl node_table_complete(table_id: i64).

node_table_complete(T) :-
    table_schema(T, _, 0),  // 0 = NODE
    property_def(T, _, _, _, true).

// An incomplete node table (missing primary key)
Decl node_table_incomplete(table_id: i64, reason: String).

node_table_incomplete(T, "missing_primary_key") :-
    table_schema(T, _, 0),
    !has_primary_key_prop(T).

Decl has_primary_key_prop(table_id: i64).

has_primary_key_prop(T) :-
    property_def(T, _, _, _, true).

// ============================================================================
// Referential Integrity Rules
// ============================================================================

// Relationship table references valid source and destination tables
Decl rel_integrity_valid(rel_table_id: i64).

rel_integrity_valid(R) :-
    rel_schema(R, Src, Dst),
    table_schema(Src, _, 0),  // source must be NODE
    table_schema(Dst, _, 0).  // dest must be NODE

// Dangling relationship (references non-existent table)
Decl dangling_rel(rel_table_id: i64, reason: String).

dangling_rel(R, "missing_source") :-
    rel_schema(R, Src, _),
    !table_schema(Src, _, _).

dangling_rel(R, "missing_destination") :-
    rel_schema(R, _, Dst),
    !table_schema(Dst, _, _).

dangling_rel(R, "source_not_node") :-
    rel_schema(R, Src, _),
    table_schema(Src, _, 1).  // 1 = REL (not a node table)

// ============================================================================
// Property Validation Rules
// ============================================================================

// Duplicate property name in same table
Decl duplicate_property(table_id: i64, prop_name: String).

duplicate_property(T, Name) :-
    property_def(T, P1, Name, _, _),
    property_def(T, P2, Name, _, _),
    P1 != P2.

// Multiple primary keys (only one allowed)
Decl multiple_primary_keys(table_id: i64).

multiple_primary_keys(T) :-
    property_def(T, P1, _, _, true),
    property_def(T, P2, _, _, true),
    P1 != P2.

// ============================================================================
// Schema Compatibility Rules
// ============================================================================

// Tables that can be joined (share a relationship)
Decl joinable_tables(table1: i64, table2: i64, via_rel: i64).

joinable_tables(Src, Dst, R) :-
    rel_schema(R, Src, Dst).

joinable_tables(Dst, Src, R) :-
    rel_schema(R, Src, Dst).

// Tables reachable via multi-hop relationships
Decl tables_reachable(src_table: i64, dst_table: i64).

tables_reachable(S, D) :-
    joinable_tables(S, D, _).

tables_reachable(S, D) :-
    joinable_tables(S, M, _),
    tables_reachable(M, D).

// ============================================================================
// DDL Validation Rules
// ============================================================================

// Table can be dropped safely (no relationships reference it)
Decl can_drop_table(table_id: i64).

can_drop_table(T) :-
    table_schema(T, _, 0),
    !table_referenced_by_rel(T).

Decl table_referenced_by_rel(table_id: i64).

table_referenced_by_rel(T) :-
    rel_schema(_, T, _).

table_referenced_by_rel(T) :-
    rel_schema(_, _, T).

// ============================================================================
// Schema Invariant Violations
// ============================================================================

Decl schema_violation(table_id: i64, violation: String).

schema_violation(T, "duplicate_property") :-
    duplicate_property(T, _).

schema_violation(T, "multiple_primary_keys") :-
    multiple_primary_keys(T).

schema_violation(T, "incomplete_node_table") :-
    node_table_incomplete(T, _).

schema_violation(R, "dangling_relationship") :-
    dangling_rel(R, _).

