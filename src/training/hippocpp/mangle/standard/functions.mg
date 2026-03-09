# HippoCPP Mangle Standard - Functions
# Built-in functions for storage operations
# Reference documentation for available functions

# =============================================================================
# PAGE FUNCTIONS
# =============================================================================

# fn:page_offset(page_idx: integer) -> integer
# Calculate byte offset for a page index
# Example: let offset = fn:page_offset(42)  // Returns 42 * 4096

# fn:page_idx_from_offset(offset: integer) -> integer
# Calculate page index from byte offset
# Example: let idx = fn:page_idx_from_offset(172032)  // Returns 42

# fn:pages_needed(size_bytes: integer) -> integer
# Calculate number of pages needed for given byte size
# Example: let pages = fn:pages_needed(100000)  // Returns 25

# =============================================================================
# CHECKSUM FUNCTIONS
# =============================================================================

# fn:crc32(data: string) -> integer
# Compute CRC32 checksum of data
# Example: let checksum = fn:crc32(page_data)

# fn:xxhash64(data: string) -> integer
# Compute xxHash64 checksum of data
# Example: let hash = fn:xxhash64(page_data)

# fn:checksum_valid(data: string, expected: integer) -> boolean
# Verify checksum matches expected value
# Example: fn:checksum_valid(page_data, stored_checksum)

# =============================================================================
# COMPRESSION FUNCTIONS
# =============================================================================

# fn:compress_ratio(original_size: integer, compressed_size: integer) -> float
# Calculate compression ratio
# Example: let ratio = fn:compress_ratio(4096, 1024)  // Returns 0.25

# fn:estimated_compressed_size(data_type: string, num_values: integer) -> integer
# Estimate compressed size for given data type and count
# Example: let est = fn:estimated_compressed_size("int64", 1000)

# fn:bitpacking_bits_needed(min_val: integer, max_val: integer) -> integer
# Calculate bits needed for bitpacking compression
# Example: let bits = fn:bitpacking_bits_needed(0, 255)  // Returns 8

# =============================================================================
# UUID FUNCTIONS
# =============================================================================

# fn:uuid_generate() -> string
# Generate a new UUID v4
# Example: let id = fn:uuid_generate()

# fn:uuid_parse(uuid_str: string) -> string
# Parse and validate a UUID string
# Example: let validated = fn:uuid_parse("550e8400-e29b-41d4-a716-446655440000")

# fn:uuid_to_bytes(uuid_str: string) -> string
# Convert UUID to 16-byte binary representation
# Example: let bytes = fn:uuid_to_bytes(uuid)

# =============================================================================
# STORAGE SIZE FUNCTIONS
# =============================================================================

# fn:format_bytes(bytes: integer) -> string
# Format byte count as human-readable string
# Example: fn:format_bytes(1073741824)  // Returns "1 GB"

# fn:parse_bytes(size_str: string) -> integer
# Parse human-readable size to bytes
# Example: fn:parse_bytes("256 MB")  // Returns 268435456

# fn:storage_overhead(data_size: integer, page_size: integer) -> float
# Calculate storage overhead ratio
# Example: let overhead = fn:storage_overhead(data_size, 4096)

# =============================================================================
# LSN (Log Sequence Number) FUNCTIONS
# =============================================================================

# fn:lsn_compare(lsn1: integer, lsn2: integer) -> integer
# Compare two LSNs (-1, 0, 1)
# Example: let cmp = fn:lsn_compare(100, 200)  // Returns -1

# fn:lsn_distance(lsn1: integer, lsn2: integer) -> integer
# Calculate distance between two LSNs
# Example: let dist = fn:lsn_distance(100, 150)  // Returns 50

# fn:lsn_valid(lsn: integer) -> boolean
# Check if LSN is valid (not max value)
# Example: fn:lsn_valid(12345)  // Returns true

# =============================================================================
# TRANSACTION FUNCTIONS
# =============================================================================

# fn:tx_visible(tx_id: integer, start_ts: integer, commit_ts: integer) -> boolean
# Check if transaction's changes are visible at given timestamp
# Example: fn:tx_visible(tx_id, read_timestamp, commit_timestamp)

# fn:tx_serializable(tx1_start: integer, tx1_end: integer, tx2_start: integer, tx2_end: integer) -> boolean
# Check if two transactions are serializable
# Example: fn:tx_serializable(100, 200, 150, 250)

# =============================================================================
# TABLE ID FUNCTIONS
# =============================================================================

# fn:table_id_valid(table_id: integer) -> boolean
# Check if table ID is valid
# Example: fn:table_id_valid(42)

# fn:internal_id_create(table_id: integer, offset: integer) -> string
# Create internal ID from table ID and offset
# Example: let id = fn:internal_id_create(1, 1000)

# fn:internal_id_table(internal_id: string) -> integer
# Extract table ID from internal ID
# Example: let table_id = fn:internal_id_table(id)

# fn:internal_id_offset(internal_id: string) -> integer
# Extract offset from internal ID
# Example: let offset = fn:internal_id_offset(id)

# =============================================================================
# BUFFER POOL FUNCTIONS
# =============================================================================

# fn:eviction_score(access_count: integer, age: integer, dirty: boolean) -> float
# Calculate eviction score for LRU-K or similar policy
# Example: let score = fn:eviction_score(10, 1000, false)

# fn:clock_hand_advance(current: integer, num_frames: integer) -> integer
# Advance clock hand for clock eviction algorithm
# Example: let next = fn:clock_hand_advance(current, 1024)

# =============================================================================
# INDEX FUNCTIONS
# =============================================================================

# fn:hash_key(key: string) -> integer
# Compute hash of index key
# Example: let hash = fn:hash_key("primary_key_value")

# fn:hash_slot(hash: integer, num_slots: integer) -> integer
# Calculate slot index from hash
# Example: let slot = fn:hash_slot(hash, 1024)

# fn:hnsw_distance(vec1: string, vec2: string, metric: string) -> float
# Calculate distance between vectors for HNSW
# Example: let dist = fn:hnsw_distance(v1, v2, "cosine")

# fn:hnsw_layer(num_elements: integer, m: integer) -> integer
# Calculate HNSW layer for new element
# Example: let layer = fn:hnsw_layer(10000, 16)

# =============================================================================
# STATISTICS FUNCTIONS
# =============================================================================

# fn:hyperloglog_estimate(hll_state: string) -> integer
# Estimate cardinality from HyperLogLog state
# Example: let estimate = fn:hyperloglog_estimate(hll)

# fn:histogram_bucket(value: float, num_buckets: integer, min_val: float, max_val: float) -> integer
# Calculate histogram bucket for value
# Example: let bucket = fn:histogram_bucket(42.5, 100, 0.0, 100.0)

# fn:sample_rate(table_size: integer, target_samples: integer) -> float
# Calculate sampling rate for statistics
# Example: let rate = fn:sample_rate(1000000, 10000)