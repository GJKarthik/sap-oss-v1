# HippoCPP Mangle Standard - Rules
# Derived predicates for database invariants, consistency checks, and state transitions

# =============================================================================
# PAGE MANAGEMENT RULES
# =============================================================================
# Derived predicates for page state

Decl page_allocated(page_idx: integer, file_id: string) :-
  page(page_idx, file_id, state, _),
  state = "allocated"; state = "dirty".

Decl page_free(page_idx: integer, file_id: string) :-
  page(page_idx, file_id, "free", _).

Decl page_dirty(page_idx: integer, file_id: string) :-
  page(page_idx, file_id, "dirty", _).

Decl page_pending_free(page_idx: integer, file_id: string) :-
  page(page_idx, file_id, "pending_free", _).

# Page with shadow copy
Decl page_has_shadow(page_idx: integer) :-
  shadow_page(page_idx, _, _, _).

# Shadow page is dirty
Decl shadow_is_dirty(page_idx: integer) :-
  shadow_page(page_idx, _, _, "dirty").

# =============================================================================
# FILE MANAGEMENT RULES
# =============================================================================
# Derived predicates for file state

Decl file_in_memory(file_id: string) :-
  file_handle(file_id, _, "in_memory", _, _, _).

Decl file_persistent(file_id: string) :-
  file_handle(file_id, _, "persistent", _, _, _).

Decl file_writable(file_id: string) :-
  file_handle(file_id, _, _, _, _, false).

Decl file_read_only(file_id: string) :-
  file_handle(file_id, _, _, _, _, true).

# File utilization ratio
Decl file_page_utilization(file_id: string, ratio: float) :-
  file_handle(file_id, _, _, _, num_pages, _),
  allocated = count { page_allocated(_, file_id) },
  num_pages > 0,
  let ratio = fn:to_float(allocated) / fn:to_float(num_pages).

# =============================================================================
# TABLE RULES
# =============================================================================
# Derived predicates for table state

Decl is_node_table(table_id: integer) :-
  table(table_id, _, "node", _, _).

Decl is_rel_table(table_id: integer) :-
  table(table_id, _, "rel", _, _).

# Node table with serial primary key
Decl node_has_serial_pk(table_id: integer) :-
  node_table(table_id, _, true).

# Relationship connects node tables
Decl rel_connects(rel_id: integer, src_table: integer, dst_table: integer) :-
  rel_table(rel_id, _, src_table, dst_table).

# Tables in same rel group
Decl same_rel_group(rel_id1: integer, rel_id2: integer) :-
  rel_table(rel_id1, group_id, _, _),
  rel_table(rel_id2, group_id, _, _),
  rel_id1 != rel_id2.

# Empty table
Decl table_empty(table_id: integer) :-
  table(table_id, _, _, _, 0).

# Table has rows
Decl table_has_data(table_id: integer) :-
  table(table_id, _, _, _, num_rows),
  num_rows > 0.

# =============================================================================
# COLUMN RULES
# =============================================================================
# Derived predicates for column state

Decl column_nullable(table_id: integer, column_id: integer) :-
  column(table_id, column_id, _, _, true).

Decl column_not_null(table_id: integer, column_id: integer) :-
  column(table_id, column_id, _, _, false).

# Column has nulls
Decl column_has_nulls(table_id: integer, column_id: integer) :-
  column_stats(table_id, column_id, num_nulls, _, _, _),
  num_nulls > 0.

# Column selectivity (distinct / total)
Decl column_selectivity(table_id: integer, column_id: integer, selectivity: float) :-
  column_stats(table_id, column_id, _, num_distinct, _, _),
  table(table_id, _, _, _, num_rows),
  num_rows > 0,
  let selectivity = fn:to_float(num_distinct) / fn:to_float(num_rows).

# High cardinality column (> 90% distinct)
Decl high_cardinality_column(table_id: integer, column_id: integer) :-
  column_selectivity(table_id, column_id, sel),
  sel > 0.9.

# Low cardinality column (< 10% distinct)
Decl low_cardinality_column(table_id: integer, column_id: integer) :-
  column_selectivity(table_id, column_id, sel),
  sel < 0.1.

# =============================================================================
# INDEX RULES
# =============================================================================
# Derived predicates for index state

Decl has_primary_key(table_id: integer) :-
  index(_, table_id, _, "primary_key", _).

Decl has_vector_index(table_id: integer) :-
  index(_, table_id, _, "hnsw", _).

Decl has_fts_index(table_id: integer) :-
  index(_, table_id, _, "fts", _).

# Index covers column
Decl index_covers_column(index_id: integer, column_id: integer) :-
  index(index_id, _, _, _, column_ids),
  fn:string_contains(column_ids, fn:to_string(column_id)).

# =============================================================================
# BUFFER MANAGER RULES
# =============================================================================
# Derived predicates for buffer pool state

Decl buffer_pool_full(pool_id: string) :-
  buffer_pool(pool_id, capacity, used, _),
  used >= capacity.

Decl buffer_pool_utilization(pool_id: string, ratio: float) :-
  buffer_pool(pool_id, capacity, used, _),
  capacity > 0,
  let ratio = fn:to_float(used) / fn:to_float(capacity).

# Buffer pool needs eviction (> 90% full)
Decl buffer_needs_eviction(pool_id: string) :-
  buffer_pool_utilization(pool_id, ratio),
  ratio > 0.9.

# Frame is evictable (not pinned, not dirty)
Decl frame_evictable(frame_id: integer) :-
  buffer_frame(frame_id, _, _, false, false, _).

# Frame is pinned
Decl frame_pinned(frame_id: integer) :-
  buffer_frame(frame_id, _, _, true, _, _).

# Hot frame (high access count)
Decl frame_hot(frame_id: integer) :-
  buffer_frame(frame_id, _, _, _, _, access_count),
  access_count > 100.

# Cold frame (low access count)
Decl frame_cold(frame_id: integer) :-
  buffer_frame(frame_id, _, _, _, _, access_count),
  access_count < 10.

# =============================================================================
# WAL RULES
# =============================================================================
# Derived predicates for WAL state

Decl wal_needs_flush(wal_id: string) :-
  wal(wal_id, _, current, flushed, _),
  current > flushed.

Decl wal_behind_checkpoint(wal_id: string) :-
  wal(wal_id, _, current, _, checkpoint),
  current - checkpoint > 1000.

# WAL record is committed
Decl wal_record_committed(lsn: integer) :-
  wal_record(lsn, wal_id, _, _, _, _),
  wal(wal_id, _, _, flushed, _),
  lsn <= flushed.

# WAL record pending
Decl wal_record_pending(lsn: integer) :-
  wal_record(lsn, wal_id, _, _, _, _),
  wal(wal_id, _, _, flushed, _),
  lsn > flushed.

# =============================================================================
# TRANSACTION RULES
# =============================================================================
# Derived predicates for transaction state

Decl tx_active(tx_id: integer) :-
  transaction(tx_id, _, _, "active", _).

Decl tx_committed(tx_id: integer) :-
  transaction(tx_id, _, _, "committed", _).

Decl tx_aborted(tx_id: integer) :-
  transaction(tx_id, _, _, "aborted", _).

Decl tx_read_only(tx_id: integer) :-
  transaction(tx_id, _, _, _, true).

Decl tx_read_write(tx_id: integer) :-
  transaction(tx_id, _, _, _, false).

# Transaction reads table
Decl tx_reads(tx_id: integer, table_id: integer) :-
  transaction_table_access(tx_id, table_id, "read").

# Transaction writes table
Decl tx_writes(tx_id: integer, table_id: integer) :-
  transaction_table_access(tx_id, table_id, "write").

# Transaction conflicts (two active transactions write same table)
Decl tx_conflict(tx1: integer, tx2: integer, table_id: integer) :-
  tx_active(tx1),
  tx_active(tx2),
  tx1 != tx2,
  tx_writes(tx1, table_id),
  tx_writes(tx2, table_id).

# Long running transaction (> 1 hour)
Decl tx_long_running(tx_id: integer) :-
  transaction(tx_id, start_ts, _, "active", _),
  let hours = fn:hours_between(start_ts, fn:now()),
  hours > 1.0.

# =============================================================================
# CHECKPOINT RULES
# =============================================================================
# Derived predicates for checkpoint state

Decl checkpoint_success(checkpoint_id: integer) :-
  checkpoint(checkpoint_id, _, _, _, _, true).

Decl checkpoint_failed(checkpoint_id: integer) :-
  checkpoint(checkpoint_id, _, _, _, _, false).

Decl checkpoint_in_progress(checkpoint_id: integer) :-
  checkpoint(checkpoint_id, _, started, completed, _, _),
  started != completed.

# Database needs checkpoint
Decl database_needs_checkpoint(database_id: string) :-
  wal(wal_id, database_id, current, _, checkpoint),
  current - checkpoint > 10000.

# =============================================================================
# STORAGE HEALTH RULES
# =============================================================================
# High-level health checks

Decl storage_healthy(database_id: string) :-
  database(database_id, _, _, _),
  !database_needs_checkpoint(database_id),
  !wal_needs_flush(_).

Decl storage_needs_attention(database_id: string, reason: string) :-
  database_needs_checkpoint(database_id),
  let reason = "checkpoint_overdue".

Decl storage_needs_attention(database_id: string, reason: string) :-
  wal(wal_id, database_id, _, _, _),
  wal_needs_flush(wal_id),
  let reason = "wal_needs_flush".

Decl storage_needs_attention(database_id: string, reason: string) :-
  buffer_pool(pool_id, _, _, _),
  buffer_needs_eviction(pool_id),
  let reason = "buffer_pool_full".