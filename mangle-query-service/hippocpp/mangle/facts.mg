// Mangle: Facts - Base Relations for Query Engine
//
// Converted from: kuzu query semantics
//
// Purpose:
// Defines base facts (extensional database) for the graph query engine.
// These represent the stored data that queries operate on.

// ============================================================================
// Schema Facts
// ============================================================================

// Table schema definition
// table_schema(TableID, TableName, TableType)
// TableType: 0 = NODE, 1 = REL
Decl table_schema(table_id: i64, table_name: String, table_type: i32).

// Property/column definition
// property_def(TableID, PropertyID, PropertyName, DataType, IsPrimaryKey)
Decl property_def(table_id: i64, property_id: i64, property_name: String, data_type: i32, is_primary_key: bool).

// Relationship schema - source and destination
// rel_schema(RelTableID, SrcTableID, DstTableID)
Decl rel_schema(rel_table_id: i64, src_table_id: i64, dst_table_id: i64).

// ============================================================================
// Node Facts
// ============================================================================

// Node existence
// node(NodeID, TableID, Offset)
Decl node(node_id: i64, table_id: i64, offset: i64).

// Node label assignment
// node_label(NodeID, LabelName)
Decl node_label(node_id: i64, label_name: String).

// Node property values (polymorphic - different value types)
// node_property_int(NodeID, PropertyName, IntValue)
Decl node_property_int(node_id: i64, property_name: String, value: i64).

// node_property_float(NodeID, PropertyName, FloatValue)
Decl node_property_float(node_id: i64, property_name: String, value: f64).

// node_property_string(NodeID, PropertyName, StringValue)
Decl node_property_string(node_id: i64, property_name: String, value: String).

// node_property_bool(NodeID, PropertyName, BoolValue)
Decl node_property_bool(node_id: i64, property_name: String, value: bool).

// Null property marker
// node_property_null(NodeID, PropertyName)
Decl node_property_null(node_id: i64, property_name: String).

// ============================================================================
// Edge Facts
// ============================================================================

// Edge existence with source and destination
// edge(EdgeID, RelTableID, SrcNodeID, DstNodeID)
Decl edge(edge_id: i64, rel_table_id: i64, src_node_id: i64, dst_node_id: i64).

// Edge type assignment
// edge_type(EdgeID, TypeName)
Decl edge_type(edge_id: i64, type_name: String).

// Edge property values
// edge_property_int(EdgeID, PropertyName, IntValue)
Decl edge_property_int(edge_id: i64, property_name: String, value: i64).

// edge_property_float(EdgeID, PropertyName, FloatValue)
Decl edge_property_float(edge_id: i64, property_name: String, value: f64).

// edge_property_string(EdgeID, PropertyName, StringValue)
Decl edge_property_string(edge_id: i64, property_name: String, value: String).

// edge_property_bool(EdgeID, PropertyName, BoolValue)
Decl edge_property_bool(edge_id: i64, property_name: String, value: bool).

// ============================================================================
// Index Facts
// ============================================================================

// Index definition
// index_def(IndexID, TableID, PropertyID, IndexType)
// IndexType: 0 = HASH, 1 = BTREE, 2 = ART
Decl index_def(index_id: i64, table_id: i64, property_id: i64, index_type: i32).

// Index entry for integer keys
// index_entry_int(IndexID, KeyValue, NodeID)
Decl index_entry_int(index_id: i64, key_value: i64, node_id: i64).

// Index entry for string keys
// index_entry_string(IndexID, KeyValue, NodeID)
Decl index_entry_string(index_id: i64, key_value: String, node_id: i64).

// ============================================================================
// Transaction Facts
// ============================================================================

// Active transaction
// transaction(TxnID, TxnType, StartTimestamp)
// TxnType: 0 = READ_ONLY, 1 = WRITE
Decl transaction(txn_id: i64, txn_type: i32, start_ts: i64).

// Transaction visibility - which nodes are visible to transaction
// visible_node(TxnID, NodeID)
Decl visible_node(txn_id: i64, node_id: i64).

// visible_edge(TxnID, EdgeID)
Decl visible_edge(txn_id: i64, edge_id: i64).

// ============================================================================
// Statistics Facts
// ============================================================================

// Table cardinality
// table_cardinality(TableID, RowCount)
Decl table_cardinality(table_id: i64, row_count: i64).

// Column statistics
// column_stats(TableID, PropertyID, DistinctCount, NullCount, MinValue, MaxValue)
Decl column_stats(table_id: i64, property_id: i64, distinct_count: i64, null_count: i64).

// Histogram bucket for integer columns
// histogram_bucket_int(TableID, PropertyID, BucketID, LowValue, HighValue, Count)
Decl histogram_bucket_int(table_id: i64, property_id: i64, bucket_id: i32, low: i64, high: i64, count: i64).