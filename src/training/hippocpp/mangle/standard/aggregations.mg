# HippoCPP Mangle Standard - Aggregations
# Standard aggregation operations for storage metrics and statistics
# Reference documentation for aggregation syntax

# =============================================================================
# AGGREGATION SYNTAX
# =============================================================================
#
# Aggregations use set comprehension syntax:
#   result = agg { pattern : condition1, condition2 }
#
# Where:
#   - agg is the aggregation function (count, sum, max, min, avg)
#   - pattern is the expression to aggregate
#   - conditions filter what gets aggregated

# =============================================================================
# PAGE AGGREGATIONS
# =============================================================================

# Count pages by state
# Decl page_count_by_state(file_id: string, state: string, count: integer) :-
#   file_handle(file_id, _, _, _, _, _),
#   page(_, file_id, state, _),
#   count = count { page(_, file_id, state, _) }.

# Total pages in file
# Decl total_pages(file_id: string, count: integer) :-
#   file_handle(file_id, _, _, _, _, _),
#   count = count { page(_, file_id, _, _) }.

# Dirty pages count
# Decl dirty_page_count(file_id: string, count: integer) :-
#   file_handle(file_id, _, _, _, _, _),
#   count = count { page(idx, file_id, "dirty", _) : page(idx, file_id, "dirty", _) }.

# =============================================================================
# TABLE AGGREGATIONS
# =============================================================================

# Total rows across all tables
# Decl total_rows_all_tables(total: integer) :-
#   total = sum { table(_, _, _, _, rows) : rows }.

# Tables per type
# Decl table_count_by_type(type: string, count: integer) :-
#   table(_, _, type, _, _),
#   count = count { table(_, _, type, _, _) }.

# Columns per table
# Decl column_count(table_id: integer, count: integer) :-
#   table(table_id, _, _, _, _),
#   count = count { column(table_id, _, _, _, _) }.

# Max rows in any table
# Decl max_table_rows(max_rows: integer) :-
#   max_rows = max { table(_, _, _, _, rows) : rows }.

# Average table size
# Decl avg_table_rows(avg_rows: float) :-
#   avg_rows = avg { table(_, _, _, _, rows) : rows }.

# =============================================================================
# COLUMN STATISTICS AGGREGATIONS
# =============================================================================

# Total nulls per table
# Decl table_total_nulls(table_id: integer, total: integer) :-
#   table(table_id, _, _, _, _),
#   total = sum { column_stats(table_id, _, nulls, _, _, _) : nulls }.

# Max distinct values in any column of a table
# Decl table_max_distinct(table_id: integer, max_distinct: integer) :-
#   table(table_id, _, _, _, _),
#   max_distinct = max { column_stats(table_id, _, _, distinct, _, _) : distinct }.

# Average selectivity across columns
# Decl table_avg_selectivity(table_id: integer, avg_sel: float) :-
#   table(table_id, _, _, _, _),
#   avg_sel = avg { column_selectivity(table_id, _, sel) : sel }.

# =============================================================================
# BUFFER POOL AGGREGATIONS
# =============================================================================

# Total buffer pool usage
# Decl total_buffer_usage(total_bytes: integer) :-
#   total_bytes = sum { buffer_pool(_, _, used, _) : used }.

# Total buffer capacity
# Decl total_buffer_capacity(total_bytes: integer) :-
#   total_bytes = sum { buffer_pool(_, capacity, _, _) : capacity }.

# Pinned frames count
# Decl pinned_frame_count(pool_id: string, count: integer) :-
#   buffer_pool(pool_id, _, _, _),
#   count = count { buffer_frame(_, pool_id, _, true, _, _) }.

# Dirty frames count
# Decl dirty_frame_count(pool_id: string, count: integer) :-
#   buffer_pool(pool_id, _, _, _),
#   count = count { buffer_frame(_, pool_id, _, _, true, _) }.

# Average access count per frame
# Decl avg_frame_access(pool_id: string, avg_access: float) :-
#   buffer_pool(pool_id, _, _, _),
#   avg_access = avg { buffer_frame(_, pool_id, _, _, _, access) : access }.

# =============================================================================
# WAL AGGREGATIONS
# =============================================================================

# WAL records by type
# Decl wal_record_count_by_type(wal_id: string, type: string, count: integer) :-
#   wal(wal_id, _, _, _, _),
#   wal_record(_, wal_id, type, _, _, _),
#   count = count { wal_record(_, wal_id, type, _, _, _) }.

# Total WAL records
# Decl total_wal_records(wal_id: string, count: integer) :-
#   wal(wal_id, _, _, _, _),
#   count = count { wal_record(_, wal_id, _, _, _, _) }.

# Pending WAL records (not flushed)
# Decl pending_wal_records(wal_id: string, count: integer) :-
#   wal(wal_id, _, _, flushed, _),
#   count = count { wal_record(lsn, wal_id, _, _, _, _) : lsn > flushed }.

# =============================================================================
# TRANSACTION AGGREGATIONS
# =============================================================================

# Active transaction count
# Decl active_tx_count(count: integer) :-
#   count = count { transaction(_, _, _, "active", _) }.

# Committed transaction count
# Decl committed_tx_count(count: integer) :-
#   count = count { transaction(_, _, _, "committed", _) }.

# Read-only transaction count
# Decl read_only_tx_count(count: integer) :-
#   count = count { transaction(_, _, _, _, true) }.

# Tables accessed by transaction
# Decl tx_table_access_count(tx_id: integer, count: integer) :-
#   transaction(tx_id, _, _, _, _),
#   count = count { transaction_table_access(tx_id, _, _) }.

# =============================================================================
# INDEX AGGREGATIONS
# =============================================================================

# Indexes per table
# Decl index_count_per_table(table_id: integer, count: integer) :-
#   table(table_id, _, _, _, _),
#   count = count { index(_, table_id, _, _, _) }.

# Indexes by type
# Decl index_count_by_type(type: string, count: integer) :-
#   index(_, _, _, type, _),
#   count = count { index(_, _, _, type, _) }.

# =============================================================================
# CHECKPOINT AGGREGATIONS
# =============================================================================

# Successful checkpoints count
# Decl successful_checkpoint_count(database_id: string, count: integer) :-
#   database(database_id, _, _, _),
#   count = count { checkpoint(_, database_id, _, _, _, true) }.

# Failed checkpoints count
# Decl failed_checkpoint_count(database_id: string, count: integer) :-
#   database(database_id, _, _, _),
#   count = count { checkpoint(_, database_id, _, _, _, false) }.

# Total pages written in checkpoints
# Decl total_checkpoint_pages(database_id: string, total: integer) :-
#   database(database_id, _, _, _),
#   total = sum { checkpoint(_, database_id, _, _, pages, true) : pages }.

# =============================================================================
# I/O STATISTICS AGGREGATIONS
# =============================================================================

# Total reads across all files
# Decl total_io_reads(total: integer) :-
#   total = sum { page_io_stat(_, reads, _, _, _) : reads }.

# Total writes across all files
# Decl total_io_writes(total: integer) :-
#   total = sum { page_io_stat(_, _, writes, _, _) : writes }.

# Total bytes read
# Decl total_bytes_read(total: integer) :-
#   total = sum { page_io_stat(_, _, _, read_bytes, _) : read_bytes }.

# Total bytes written
# Decl total_bytes_written(total: integer) :-
#   total = sum { page_io_stat(_, _, _, _, write_bytes) : write_bytes }.