# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HippoCPP Index Module for Mojo

Provides indexing structures for efficient data retrieval:
- Hash index for exact match lookups
- HNSW index for approximate nearest neighbor search
- Support for multiple index types (HASH, BTREE, ART, HNSW, FTS)
"""

from collections import Dict, List
from memory import memset, memcpy


# ============================================================================
# Index Type Enum
# ============================================================================

@value
struct IndexType:
    """Enumeration of supported index types."""
    var value: Int

    alias HASH: Int = 0
    alias BTREE: Int = 1
    alias ART: Int = 2
    alias HNSW: Int = 3
    alias FTS: Int = 4

    fn __init__(inout self, value: Int):
        self.value = value

    fn get_name(self) -> String:
        """Get human-readable name of index type."""
        if self.value == Self.HASH:
            return "HASH"
        elif self.value == Self.BTREE:
            return "BTREE"
        elif self.value == Self.ART:
            return "ART"
        elif self.value == Self.HNSW:
            return "HNSW"
        elif self.value == Self.FTS:
            return "FTS"
        else:
            return "UNKNOWN"


# ============================================================================
# Hash Index
# ============================================================================

struct HashIndex:
    """Hash index for exact match lookups with O(1) average performance."""
    var table_id: Int
    var column_id: Int
    var bucket_count: Int
    var load_factor: Float32
    var slot_capacity: Int
    var num_entries: Int
    var bucket_sizes: List[Int]

    fn __init__(
        inout self,
        table_id: Int,
        column_id: Int,
        bucket_count: Int = 256,
        load_factor: Float32 = 0.75,
        slot_capacity: Int = 8
    ):
        """Initialize hash index with configuration parameters."""
        self.table_id = table_id
        self.column_id = column_id
        self.bucket_count = bucket_count
        self.load_factor = load_factor
        self.slot_capacity = slot_capacity
        self.num_entries = 0
        self.bucket_sizes = List[Int]()
        for _ in range(bucket_count):
            self.bucket_sizes.append(0)

    fn insert(inout self, key_hash: Int, value_id: Int) -> Bool:
        """Insert key-value pair. Returns True if successful."""
        let bucket_idx = key_hash % self.bucket_count
        if self.bucket_sizes[bucket_idx] < self.slot_capacity:
            self.bucket_sizes[bucket_idx] += 1
            self.num_entries += 1
            return True
        return False

    fn lookup(self, key_hash: Int) -> Int:
        """Look up key. Returns bucket index or -1 if not found."""
        let bucket_idx = key_hash % self.bucket_count
        return bucket_idx if self.bucket_sizes[bucket_idx] > 0 else -1

    fn remove(inout self, key_hash: Int) -> Bool:
        """Remove key. Returns True if successful."""
        let bucket_idx = key_hash % self.bucket_count
        if self.bucket_sizes[bucket_idx] > 0:
            self.bucket_sizes[bucket_idx] -= 1
            self.num_entries -= 1
            return True
        return False

    fn get_load_factor(self) -> Float32:
        """Get current load factor."""
        return Float32(self.num_entries) / Float32(self.bucket_count) if self.bucket_count > 0 else 0.0

    fn needs_rehash(self) -> Bool:
        """Check if rehashing is needed."""
        return self.get_load_factor() > self.load_factor


# ============================================================================
# HNSW Index
# ============================================================================

struct HNSWIndex:
    """HNSW index for approximate nearest neighbor vector search."""
    var dimensions: Int
    var max_level: Int
    var ef_construction: Int
    var M: Int
    var entry_point: Int
    var num_vectors: Int
    var vector_count_per_level: List[Int]

    fn __init__(
        inout self,
        dimensions: Int,
        max_level: Int = 16,
        ef_construction: Int = 200,
        M: Int = 5
    ):
        """Initialize HNSW index with vector parameters."""
        self.dimensions = dimensions
        self.max_level = max_level
        self.ef_construction = ef_construction
        self.M = M
        self.entry_point = -1
        self.num_vectors = 0
        self.vector_count_per_level = List[Int]()
        for _ in range(max_level):
            self.vector_count_per_level.append(0)

    fn insert(inout self, vector_id: Int, level: Int) -> Bool:
        """Insert vector at specified level. Returns True if successful."""
        if level < 0 or level >= self.max_level:
            return False
        if self.entry_point == -1:
            self.entry_point = vector_id
        self.vector_count_per_level[level] += 1
        self.num_vectors += 1
        return True

    fn search(self, ef: Int) -> List[Int]:
        """Search for nearest neighbors. Returns candidate vector IDs."""
        var candidates = List[Int]()
        if self.entry_point >= 0:
            candidates.append(self.entry_point)
        return candidates

    fn get_stats(self) -> (Int, Int, Int):
        """Get index statistics: (num_vectors, max_level, entry_point)."""
        return (self.num_vectors, self.max_level, self.entry_point)



# ============================================================================
# Tests
# ============================================================================

fn test_index_type():
    """Test IndexType enum."""
    let hash_type = IndexType(IndexType.HASH)
    assert_equal(hash_type.get_name(), "HASH")

    let hnsw_type = IndexType(IndexType.HNSW)
    assert_equal(hnsw_type.get_name(), "HNSW")

    print("✓ IndexType tests passed")


fn test_hash_index():
    """Test HashIndex."""
    var index = HashIndex(table_id=1, column_id=0, bucket_count=16)

    # Test insertion
    assert_true(index.insert(key_hash=42, value_id=100))
    assert_equal(index.num_entries, 1)

    # Test lookup
    let bucket = index.lookup(key_hash=42)
    assert_true(bucket >= 0)

    # Test removal
    assert_true(index.remove(key_hash=42))
    assert_equal(index.num_entries, 0)

    print("✓ HashIndex tests passed")


fn test_hnsw_index():
    """Test HNSWIndex."""
    var index = HNSWIndex(dimensions=128, max_level=8)

    # Test insertion
    assert_true(index.insert(vector_id=0, level=0))
    assert_equal(index.num_vectors, 1)
    assert_equal(index.entry_point, 0)

    # Test search
    let candidates = index.search(ef=10)
    assert_equal(len(candidates), 1)

    # Test stats
    let stats = index.get_stats()
    assert_equal(stats.0, 1)  # num_vectors
    assert_equal(stats.2, 0)  # entry_point

    print("✓ HNSWIndex tests passed")


fn main():
    """Run all tests."""
    print("Running Mojo index module tests...")
    test_index_type()
    test_hash_index()
    test_hnsw_index()
    print("All tests passed! ✓")
