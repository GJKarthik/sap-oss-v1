#include "storage/table/in_mem_chunked_node_group_collection.h"

/**
 * P2-111: In-Memory Chunked Node Group Collection - Batch Write Buffer
 * 
 * Purpose:
 * Provides a dynamically growing collection of in-memory chunked node groups
 * for batch write operations. Used during bulk inserts, COPY operations, and
 * batch updates before persistence to disk.
 * 
 * Architecture:
 * ```
 * InMemChunkedNodeGroupCollection
 *   ├── types: vector<LogicalType>         // Column schemas
 *   └── chunkedGroups: vector<unique_ptr<InMemChunkedNodeGroup>>
 *       └── InMemChunkedNodeGroup (each holds up to CHUNKED_NODE_GROUP_CAPACITY rows)
 *           └── ColumnChunks (one per column)
 * ```
 * 
 * Write Amplification Optimization:
 * Instead of writing single rows to disk, data accumulates in memory:
 * 1. Rows appended to current chunked group
 * 2. When full (CHUNKED_NODE_GROUP_CAPACITY), group is sealed
 * 3. New group allocated for subsequent writes
 * 4. On checkpoint, all groups flushed to disk in batch
 * 
 * Memory Management Strategy:
 * - setUnused(memoryManager) called when group is full
 * - Signals buffer manager that pages can be evicted if needed
 * - Enables memory pressure handling during large imports
 * 
 * Capacity Planning:
 * | Rows | Groups (64K/group) | Est. Memory (1KB/row) |
 * |------|--------------------|-----------------------|
 * | 1M | 16 | ~1GB |
 * | 10M | 153 | ~10GB |
 * | 100M | 1526 | ~100GB (needs spilling) |
 * 
 * Merge Operations:
 * - merge(chunkedGroup): Append single group to collection
 * - merge(other): Combine two collections (for parallel imports)
 * - Type validation ensures schema compatibility
 * 
 * Use Cases:
 * 1. COPY FROM: Bulk load from CSV/Parquet
 * 2. Batch INSERT: Multi-row insert statements
 * 3. Parallel Import: Each thread builds local collection, then merge
 * 4. Transaction Staging: Buffer uncommitted writes
 * 
 * Optimization Opportunities:
 * 
 * 1. Pre-allocation Based on Estimate:
 *    ```
 *    void reserve(row_idx_t estimatedRows) {
 *        auto numGroups = (estimatedRows + CAPACITY - 1) / CAPACITY;
 *        chunkedGroups.reserve(numGroups);
 *    }
 *    ```
 *    Reduces vector reallocation during large imports.
 * 
 * 2. Parallel Append with Lock Striping:
 *    ```
 *    // Multiple threads append to different chunks
 *    size_t getStripe(thread_id) { return thread_id % NUM_STRIPES; }
 *    void parallelAppend(vectors, thread_id) {
 *        stripes[getStripe(thread_id)]->append(vectors);
 *    }
 *    ```
 * 
 * 3. Compression During Accumulation:
 *    Enable compression for groups that hit full capacity:
 *    - Currently: enableCompression = false
 *    - Could compress sealed groups to reduce memory
 * 
 * 4. Spilling to Disk:
 *    For very large imports exceeding memory:
 *    - Spill oldest sealed groups to temp file
 *    - Read back during checkpoint
 */

#include "storage/buffer_manager/memory_manager.h"

using namespace kuzu::common;
using namespace kuzu::transaction;

namespace kuzu {
namespace storage {

void InMemChunkedNodeGroupCollection::append(MemoryManager& memoryManager,
    const std::vector<ValueVector*>& vectors, row_idx_t startRowInVectors,
    row_idx_t numRowsToAppend) {
    if (chunkedGroups.empty()) {
        chunkedGroups.push_back(std::make_unique<InMemChunkedNodeGroup>(memoryManager, types,
            false /*enableCompression*/, common::StorageConfig::CHUNKED_NODE_GROUP_CAPACITY,
            0 /*startOffset*/));
    }
    row_idx_t numRowsAppended = 0;
    while (numRowsAppended < numRowsToAppend) {
        auto& lastChunkedGroup = chunkedGroups.back();
        auto numRowsToAppendInGroup = std::min(numRowsToAppend - numRowsAppended,
            common::StorageConfig::CHUNKED_NODE_GROUP_CAPACITY - lastChunkedGroup->getNumRows());
        lastChunkedGroup->append(vectors, startRowInVectors, numRowsToAppendInGroup);
        if (lastChunkedGroup->getNumRows() == common::StorageConfig::CHUNKED_NODE_GROUP_CAPACITY) {
            lastChunkedGroup->setUnused(memoryManager);
            chunkedGroups.push_back(std::make_unique<InMemChunkedNodeGroup>(memoryManager, types,
                false /*enableCompression*/, common::StorageConfig::CHUNKED_NODE_GROUP_CAPACITY,
                0 /* startRowIdx */));
        }
        numRowsAppended += numRowsToAppendInGroup;
    }
}

void InMemChunkedNodeGroupCollection::merge(std::unique_ptr<InMemChunkedNodeGroup> chunkedGroup) {
    KU_ASSERT(chunkedGroup->getNumColumns() == types.size());
    for (auto i = 0u; i < chunkedGroup->getNumColumns(); i++) {
        KU_ASSERT(chunkedGroup->getColumnChunk(i).getDataType() == types[i]);
    }
    chunkedGroups.push_back(std::move(chunkedGroup));
}

void InMemChunkedNodeGroupCollection::merge(InMemChunkedNodeGroupCollection& other) {
    chunkedGroups.reserve(chunkedGroups.size() + other.chunkedGroups.size());
    for (auto& chunkedGroup : other.chunkedGroups) {
        merge(std::move(chunkedGroup));
    }
}

} // namespace storage
} // namespace kuzu
