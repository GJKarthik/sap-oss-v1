# HippoCPP Mangle Standard - Facts
# Base predicates for the graph database storage layer
# Declarative representation of database schema and state

# =============================================================================
# DATABASE
# =============================================================================
# Database-level facts

Decl database(
  id: string,
  path: string,
  version: integer,
  created_at: datetime
).

Decl database_config(
  database_id: string,
  buffer_pool_size: integer,
  max_threads: integer,
  compression_enabled: boolean,
  checksums_enabled: boolean
).

Decl database_header(
  database_id: string,
  magic: integer,
  storage_version: integer,
  checkpoint_id: integer,
  catalog_page_idx: integer
).

# =============================================================================
# STORAGE
# =============================================================================
# Storage layer facts

Decl page(
  page_idx: integer,
  file_id: string,
  state: string,                      # free|allocated|dirty|pending_free
  version: integer
).

Decl file_handle(
  file_id: string,
  path: string,
  mode: string,                       # persistent|in_memory
  size_bytes: integer,
  num_pages: integer,
  read_only: boolean
).

Decl shadow_page(
  page_idx: integer,
  original_checksum: integer,
  shadow_checksum: integer,
  state: string                       # clean|dirty|committed
).

# =============================================================================
# TABLE
# =============================================================================
# Table-level facts

Decl table(
  table_id: integer,
  name: string,
  type: string,                       # node|rel
  num_columns: integer,
  num_rows: integer
).

Decl node_table(
  table_id: integer,
  primary_key_column: string,
  has_serial_pk: boolean
).

Decl rel_table(
  table_id: integer,
  rel_group_id: integer,
  src_table_id: integer,
  dst_table_id: integer
).

Decl rel_group(
  rel_group_id: integer,
  name: string,
  num_rel_tables: integer
).

# =============================================================================
# COLUMN
# =============================================================================
# Column-level facts

Decl column(
  table_id: integer,
  column_id: integer,
  name: string,
  type: string,
  nullable: boolean
).

Decl column_stats(
  table_id: integer,
  column_id: integer,
  num_nulls: integer,
  num_distinct: integer,
  min_value: string,
  max_value: string
).

Decl column_chunk(
  table_id: integer,
  column_id: integer,
  chunk_idx: integer,
  start_offset: integer,
  num_values: integer,
  compressed: boolean
).

# =============================================================================
# INDEX
# =============================================================================
# Index facts

Decl index(
  index_id: integer,
  table_id: integer,
  name: string,
  type: string,                       # primary_key|hash|hnsw|fts
  column_ids: string                  # comma-separated list
).

Decl index_type(
  type_name: string,
  supports_equality: boolean,
  supports_range: boolean,
  supports_similarity: boolean
).

Decl primary_key_index(
  table_id: integer,
  column_id: integer,
  num_entries: integer
).

Decl hnsw_index(
  index_id: integer,
  dimension: integer,
  m: integer,
  ef_construction: integer
).

# =============================================================================
# BUFFER MANAGER
# =============================================================================
# Buffer pool facts

Decl buffer_pool(
  pool_id: string,
  capacity_bytes: integer,
  used_bytes: integer,
  num_pages: integer
).

Decl buffer_frame(
  frame_id: integer,
  pool_id: string,
  page_idx: integer,
  pinned: boolean,
  dirty: boolean,
  access_count: integer
).

# =============================================================================
# WAL (Write-Ahead Log)
# =============================================================================
# WAL facts

Decl wal(
  wal_id: string,
  database_id: string,
  current_lsn: integer,
  flushed_lsn: integer,
  checkpoint_lsn: integer
).

Decl wal_record(
  lsn: integer,
  wal_id: string,
  type: string,                       # insert|update|delete|checkpoint|commit
  table_id: integer,
  page_idx: integer,
  timestamp: datetime
).

# =============================================================================
# TRANSACTION
# =============================================================================
# Transaction facts

Decl transaction(
  tx_id: integer,
  start_timestamp: integer,
  commit_timestamp: integer,
  state: string,                      # active|committed|aborted
  read_only: boolean
).

Decl transaction_table_access(
  tx_id: integer,
  table_id: integer,
  access_type: string                 # read|write
).

# =============================================================================
# CHECKPOINT
# =============================================================================
# Checkpoint facts

Decl checkpoint(
  checkpoint_id: integer,
  database_id: string,
  started_at: datetime,
  completed_at: datetime,
  num_pages_written: integer,
  success: boolean
).

# =============================================================================
# METRICS
# =============================================================================
# Performance metrics

Decl storage_metric(
  database_id: string,
  metric_name: string,
  value: float,
  timestamp: datetime
) temporal.

Decl page_io_stat(
  file_id: string,
  reads: integer,
  writes: integer,
  read_bytes: integer,
  write_bytes: integer
).