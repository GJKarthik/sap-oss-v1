#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <vector>

namespace kuzu {
namespace common {

/**
 * HyperLogLog (HLL) implementation for cardinality estimation.
 * 
 * HLL is a probabilistic data structure that estimates the number of distinct
 * elements in a multiset with O(1) space complexity (relative to precision).
 * 
 * This implementation uses 14-bit precision (16384 registers) by default,
 * providing ~1% standard error with only 12KB memory usage.
 * 
 * References:
 * - Flajolet et al., "HyperLogLog: the analysis of a near-optimal cardinality estimation algorithm"
 * - Google's HyperLogLog++ paper for bias correction
 */
class HyperLogLog {
public:
    // 14-bit precision = 16384 registers, ~1% standard error
    static constexpr uint8_t DEFAULT_PRECISION = 14;
    static constexpr uint8_t MIN_PRECISION = 4;
    static constexpr uint8_t MAX_PRECISION = 18;
    
    explicit HyperLogLog(uint8_t precision = DEFAULT_PRECISION);
    ~HyperLogLog() = default;
    
    // Copy/move semantics
    HyperLogLog(const HyperLogLog& other);
    HyperLogLog& operator=(const HyperLogLog& other);
    HyperLogLog(HyperLogLog&& other) noexcept = default;
    HyperLogLog& operator=(HyperLogLog&& other) noexcept = default;
    
    /**
     * Add a hashed value to the HLL sketch.
     * @param hash A 64-bit hash of the element to add
     */
    void add(uint64_t hash);
    
    /**
     * Add an element by computing its hash internally.
     * @param data Pointer to the data
     * @param len Length of the data in bytes
     */
    void addData(const void* data, size_t len);
    
    /**
     * Estimate the cardinality (number of distinct elements).
     * @return Estimated count of distinct elements
     */
    uint64_t estimate() const;
    
    /**
     * Merge another HLL into this one.
     * Both HLLs must have the same precision.
     * @param other The HLL to merge
     */
    void merge(const HyperLogLog& other);
    
    /**
     * Reset the HLL to empty state.
     */
    void clear();
    
    /**
     * Get the precision (number of bits for register indexing).
     */
    uint8_t getPrecision() const { return precision_; }
    
    /**
     * Get the number of registers.
     */
    uint32_t getNumRegisters() const { return numRegisters_; }
    
    /**
     * Get memory usage in bytes.
     */
    size_t getMemoryUsage() const { return registers_.size(); }
    
private:
    // Hash function (MurmurHash3 finalizer)
    static uint64_t murmur64(uint64_t h);
    
    // Count leading zeros + 1 (the "rho" function)
    static uint8_t countLeadingZerosPlus1(uint64_t value, uint8_t precision);
    
    // Alpha constant for bias correction
    static double getAlpha(uint32_t m);
    
    // Linear counting for small cardinalities
    double linearCounting(uint32_t numZeroRegisters) const;
    
    uint8_t precision_;
    uint32_t numRegisters_;
    std::vector<uint8_t> registers_;
};

/**
 * HyperLogLog estimator for group-by cardinality.
 * Maintains HLL sketches per grouping key combination.
 */
class HLLCardinalityEstimator {
public:
    HLLCardinalityEstimator() = default;
    
    /**
     * Create or get HLL for a specific grouping key.
     * @param keyHash Hash of the grouping key combination
     * @return Reference to the HLL for that key
     */
    HyperLogLog& getOrCreateHLL(uint64_t keyHash);
    
    /**
     * Estimate total distinct groups.
     * @return Estimated number of distinct grouping key combinations
     */
    uint64_t estimateTotalGroups() const;
    
    /**
     * Get the estimated cardinality for a specific group.
     * @param keyHash Hash of the grouping key
     * @return Estimated cardinality, or 0 if group doesn't exist
     */
    uint64_t estimateForGroup(uint64_t keyHash) const;
    
    /**
     * Merge all HLLs into a single estimate.
     * @return Combined cardinality estimate
     */
    uint64_t estimateCombined() const;
    
    void clear();
    
private:
    std::unordered_map<uint64_t, HyperLogLog> groupHLLs_;
    HyperLogLog globalHLL_;  // For tracking distinct groups
};

} // namespace common
} // namespace kuzu