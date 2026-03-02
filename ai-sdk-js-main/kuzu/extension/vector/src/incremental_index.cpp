/**
 * Incremental Vector Index Updates
 * 
 * P1-47: Delta Updates for Vector Indexes
 * 
 * This module provides incremental update capabilities for vector indexes,
 * allowing efficient insert/update/delete operations without full index rebuilds.
 * 
 * Problem:
 * Traditional vector indexes (HNSW, IVF) are expensive to rebuild.
 * Full rebuilds can take hours for large datasets.
 * 
 * Solution:
 * Maintain a write-optimized delta buffer that is periodically merged
 * into the main index during compaction.
 * 
 * Architecture:
 * ┌────────────────────────────────────────────────────────────────┐
 * │                     Query Path                                 │
 * │  Query ─┬─> Main Index (HNSW/IVF) ──> Results ─┬─> Merge      │
 * │         │                                      │               │
 * │         └─> Delta Buffer (Flat Scan) ──────────┘               │
 * └────────────────────────────────────────────────────────────────┘
 * 
 * ┌────────────────────────────────────────────────────────────────┐
 * │                     Write Path                                 │
 * │  Insert ──> Delta Buffer ──> [Threshold?] ──> Compact to Main │
 * │  Delete ──> Tombstone Set ──> [Compact?] ──> Apply to Main    │
 * │  Update ──> Delete + Insert                                    │
 * └────────────────────────────────────────────────────────────────┘
 * 
 * Key Features:
 * - O(1) inserts via delta buffer
 * - Lazy compaction to main index
 * - Tombstone-based deletes
 * - Atomic batch operations
 * - Concurrent read/write support
 */

#include <cstdint>
#include <vector>
#include <unordered_set>
#include <mutex>
#include <shared_mutex>
#include <atomic>
#include <algorithm>
#include <memory>

namespace kuzu {
namespace extension {
namespace vector {

/**
 * Configuration for incremental index
 */
struct IncrementalIndexConfig {
    size_t dimension;              // Vector dimension
    size_t deltaThreshold;         // Compact when delta exceeds this
    size_t deleteThreshold;        // Compact when deletes exceed this
    float compactionRatio;         // Compact if deletes > ratio * total
    bool autoCompact;              // Enable automatic compaction
    
    IncrementalIndexConfig(size_t dim = 1536)
        : dimension(dim), deltaThreshold(10000), deleteThreshold(5000),
          compactionRatio(0.1f), autoCompact(true) {}
};

/**
 * Delta entry representing a newly inserted vector
 */
struct DeltaEntry {
    uint64_t id;                   // Vector ID
    std::vector<float> vector;     // Vector data
    uint64_t timestamp;            // Insert timestamp for MVCC
    
    DeltaEntry(uint64_t id, const float* vec, size_t dim, uint64_t ts)
        : id(id), vector(vec, vec + dim), timestamp(ts) {}
};

/**
 * Search result from index
 */
struct SearchResult {
    uint64_t id;
    float distance;
    
    bool operator<(const SearchResult& other) const {
        return distance < other.distance;
    }
};

/**
 * Abstract interface for main vector index
 * Implementations: HNSW, IVF, Flat
 */
class VectorIndex {
public:
    virtual ~VectorIndex() = default;
    
    // Search for k nearest neighbors
    virtual std::vector<SearchResult> search(
        const float* query, size_t k) const = 0;
    
    // Bulk insert vectors (used during compaction)
    virtual void bulkInsert(
        const std::vector<uint64_t>& ids,
        const std::vector<float>& vectors) = 0;
    
    // Remove vectors by ID (used during compaction)
    virtual void remove(const std::vector<uint64_t>& ids) = 0;
    
    // Get current index size
    virtual size_t size() const = 0;
};

/**
 * Incremental Vector Index with Delta Buffer
 * 
 * Wraps a main index and adds incremental update support.
 */
class IncrementalVectorIndex {
public:
    IncrementalVectorIndex(
        std::unique_ptr<VectorIndex> mainIndex,
        const IncrementalIndexConfig& config)
        : mainIndex_(std::move(mainIndex)),
          config_(config),
          nextTimestamp_(1),
          compacting_(false) {}
    
    /**
     * Insert a new vector
     * O(1) - just append to delta buffer
     */
    void insert(uint64_t id, const float* vector) {
        std::unique_lock<std::shared_mutex> lock(mutex_);
        
        uint64_t timestamp = nextTimestamp_++;
        deltaBuffer_.emplace_back(id, vector, config_.dimension, timestamp);
        
        // Check if compaction needed
        if (config_.autoCompact && shouldCompact()) {
            lock.unlock();
            compact();
        }
    }
    
    /**
     * Insert multiple vectors
     */
    void insertBatch(const std::vector<uint64_t>& ids,
                     const std::vector<float>& vectors) {
        std::unique_lock<std::shared_mutex> lock(mutex_);
        
        for (size_t i = 0; i < ids.size(); i++) {
            uint64_t timestamp = nextTimestamp_++;
            deltaBuffer_.emplace_back(
                ids[i],
                vectors.data() + i * config_.dimension,
                config_.dimension,
                timestamp);
        }
        
        if (config_.autoCompact && shouldCompact()) {
            lock.unlock();
            compact();
        }
    }
    
    /**
     * Delete a vector by ID
     * O(1) - just add to tombstone set
     */
    void remove(uint64_t id) {
        std::unique_lock<std::shared_mutex> lock(mutex_);
        tombstones_.insert(id);
        
        if (config_.autoCompact && shouldCompact()) {
            lock.unlock();
            compact();
        }
    }
    
    /**
     * Update a vector (delete + insert)
     */
    void update(uint64_t id, const float* newVector) {
        std::unique_lock<std::shared_mutex> lock(mutex_);
        
        tombstones_.insert(id);
        uint64_t timestamp = nextTimestamp_++;
        deltaBuffer_.emplace_back(id, newVector, config_.dimension, timestamp);
        
        if (config_.autoCompact && shouldCompact()) {
            lock.unlock();
            compact();
        }
    }
    
    /**
     * Search for k nearest neighbors
     * Searches both main index and delta buffer, merges results
     */
    std::vector<SearchResult> search(const float* query, size_t k) const {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        
        // Search main index
        auto mainResults = mainIndex_->search(query, k);
        
        // Filter out tombstoned results
        mainResults.erase(
            std::remove_if(mainResults.begin(), mainResults.end(),
                [this](const SearchResult& r) {
                    return tombstones_.count(r.id) > 0;
                }),
            mainResults.end());
        
        // Search delta buffer (flat scan)
        auto deltaResults = searchDelta(query, k);
        
        // Merge results
        std::vector<SearchResult> merged;
        merged.reserve(mainResults.size() + deltaResults.size());
        merged.insert(merged.end(), mainResults.begin(), mainResults.end());
        merged.insert(merged.end(), deltaResults.begin(), deltaResults.end());
        
        // Sort and take top-k
        std::partial_sort(merged.begin(), 
                         merged.begin() + std::min(k, merged.size()),
                         merged.end());
        
        if (merged.size() > k) {
            merged.resize(k);
        }
        
        return merged;
    }
    
    /**
     * Compact delta buffer into main index
     */
    void compact() {
        // Prevent concurrent compactions
        bool expected = false;
        if (!compacting_.compare_exchange_strong(expected, true)) {
            return;
        }
        
        std::unique_lock<std::shared_mutex> lock(mutex_);
        
        // Apply tombstones to main index
        if (!tombstones_.empty()) {
            std::vector<uint64_t> toRemove(tombstones_.begin(), tombstones_.end());
            mainIndex_->remove(toRemove);
            tombstones_.clear();
        }
        
        // Bulk insert delta buffer to main index
        if (!deltaBuffer_.empty()) {
            std::vector<uint64_t> ids;
            std::vector<float> vectors;
            ids.reserve(deltaBuffer_.size());
            vectors.reserve(deltaBuffer_.size() * config_.dimension);
            
            for (const auto& entry : deltaBuffer_) {
                // Skip if tombstoned
                if (tombstones_.count(entry.id) == 0) {
                    ids.push_back(entry.id);
                    vectors.insert(vectors.end(), 
                                  entry.vector.begin(), 
                                  entry.vector.end());
                }
            }
            
            if (!ids.empty()) {
                mainIndex_->bulkInsert(ids, vectors);
            }
            deltaBuffer_.clear();
        }
        
        compacting_ = false;
    }
    
    /**
     * Get statistics about current state
     */
    struct Stats {
        size_t mainIndexSize;
        size_t deltaBufferSize;
        size_t tombstoneCount;
        float deletionRatio;
    };
    
    Stats getStats() const {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        Stats stats;
        stats.mainIndexSize = mainIndex_->size();
        stats.deltaBufferSize = deltaBuffer_.size();
        stats.tombstoneCount = tombstones_.size();
        stats.deletionRatio = stats.mainIndexSize > 0 ?
            static_cast<float>(stats.tombstoneCount) / stats.mainIndexSize : 0.0f;
        return stats;
    }

private:
    std::unique_ptr<VectorIndex> mainIndex_;
    IncrementalIndexConfig config_;
    
    // Delta buffer for new insertions
    std::vector<DeltaEntry> deltaBuffer_;
    
    // Tombstone set for deletions
    std::unordered_set<uint64_t> tombstones_;
    
    // Timestamp counter for MVCC
    std::atomic<uint64_t> nextTimestamp_;
    
    // Compaction flag
    std::atomic<bool> compacting_;
    
    // Reader-writer lock for concurrent access
    mutable std::shared_mutex mutex_;
    
    /**
     * Check if compaction should be triggered
     */
    bool shouldCompact() const {
        if (deltaBuffer_.size() >= config_.deltaThreshold) {
            return true;
        }
        if (tombstones_.size() >= config_.deleteThreshold) {
            return true;
        }
        size_t mainSize = mainIndex_->size();
        if (mainSize > 0 && 
            static_cast<float>(tombstones_.size()) / mainSize > config_.compactionRatio) {
            return true;
        }
        return false;
    }
    
    /**
     * Search delta buffer (flat scan)
     */
    std::vector<SearchResult> searchDelta(const float* query, size_t k) const {
        std::vector<SearchResult> results;
        
        for (const auto& entry : deltaBuffer_) {
            // Skip tombstoned entries
            if (tombstones_.count(entry.id) > 0) {
                continue;
            }
            
            float dist = l2DistanceSquared(query, entry.vector.data(), 
                                          config_.dimension);
            results.push_back({entry.id, dist});
        }
        
        // Partial sort to get top-k
        if (results.size() > k) {
            std::partial_sort(results.begin(), results.begin() + k, results.end());
            results.resize(k);
        } else {
            std::sort(results.begin(), results.end());
        }
        
        return results;
    }
    
    /**
     * Squared L2 distance
     */
    static float l2DistanceSquared(const float* a, const float* b, size_t dim) {
        float sum = 0.0f;
        for (size_t i = 0; i < dim; i++) {
            float diff = a[i] - b[i];
            sum += diff * diff;
        }
        return sum;
    }
};

} // namespace vector
} // namespace extension
} // namespace kuzu

/**
 * Usage Example:
 * 
 * // Create main index (HNSW implementation)
 * auto hnswIndex = std::make_unique<HNSWIndex>(config);
 * 
 * // Wrap with incremental support
 * IncrementalIndexConfig incConfig(1536);
 * IncrementalVectorIndex index(std::move(hnswIndex), incConfig);
 * 
 * // Operations are now incremental
 * index.insert(1, vector1);
 * index.insert(2, vector2);
 * index.remove(1);
 * index.update(2, newVector2);
 * 
 * // Search merges main index + delta buffer
 * auto results = index.search(query, 10);
 * 
 * // Manual compaction (or automatic)
 * index.compact();
 * 
 * Performance Characteristics:
 * | Operation | Complexity | Description |
 * |-----------|------------|-------------|
 * | Insert | O(1) | Append to delta buffer |
 * | Delete | O(1) | Add to tombstone set |
 * | Update | O(1) | Delete + Insert |
 * | Search | O(main) + O(delta) | Merged results |
 * | Compact | O(delta * log(main)) | Bulk merge |
 */