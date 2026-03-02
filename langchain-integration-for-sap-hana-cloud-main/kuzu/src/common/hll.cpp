#include "common/hll.h"

#include <algorithm>
#include <bit>
#include <stdexcept>

namespace kuzu {
namespace common {

// ============================================================================
// HyperLogLog Implementation
// ============================================================================

HyperLogLog::HyperLogLog(uint8_t precision)
    : precision_(precision),
      numRegisters_(1u << precision),
      registers_(numRegisters_, 0) {
    if (precision < MIN_PRECISION || precision > MAX_PRECISION) {
        throw std::invalid_argument(
            "HyperLogLog precision must be between " + std::to_string(MIN_PRECISION) +
            " and " + std::to_string(MAX_PRECISION));
    }
}

HyperLogLog::HyperLogLog(const HyperLogLog& other)
    : precision_(other.precision_),
      numRegisters_(other.numRegisters_),
      registers_(other.registers_) {}

HyperLogLog& HyperLogLog::operator=(const HyperLogLog& other) {
    if (this != &other) {
        precision_ = other.precision_;
        numRegisters_ = other.numRegisters_;
        registers_ = other.registers_;
    }
    return *this;
}

uint64_t HyperLogLog::murmur64(uint64_t h) {
    // MurmurHash3 finalizer
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL;
    h ^= h >> 33;
    return h;
}

uint8_t HyperLogLog::countLeadingZerosPlus1(uint64_t value, uint8_t precision) {
    // Shift out the index bits, then count leading zeros in remaining bits
    uint64_t w = value << precision;
    if (w == 0) {
        return 64 - precision + 1;
    }
    // Use compiler builtin for efficiency
#if defined(__GNUC__) || defined(__clang__)
    return static_cast<uint8_t>(__builtin_clzll(w) + 1);
#else
    // Fallback implementation
    uint8_t count = 1;
    while ((w & (1ULL << 63)) == 0 && count < 64) {
        w <<= 1;
        count++;
    }
    return count;
#endif
}

double HyperLogLog::getAlpha(uint32_t m) {
    // Alpha constants for bias correction
    switch (m) {
    case 16:
        return 0.673;
    case 32:
        return 0.697;
    case 64:
        return 0.709;
    default:
        // For m >= 128
        return 0.7213 / (1.0 + 1.079 / static_cast<double>(m));
    }
}

double HyperLogLog::linearCounting(uint32_t numZeroRegisters) const {
    return static_cast<double>(numRegisters_) * 
           std::log(static_cast<double>(numRegisters_) / 
                    static_cast<double>(numZeroRegisters));
}

void HyperLogLog::add(uint64_t hash) {
    // Use lower bits for register index
    uint32_t idx = hash & (numRegisters_ - 1);
    // Use remaining bits for the rho value (leading zeros)
    uint8_t rho = countLeadingZerosPlus1(hash, precision_);
    // Keep the maximum
    registers_[idx] = std::max(registers_[idx], rho);
}

void HyperLogLog::addData(const void* data, size_t len) {
    // Simple FNV-1a hash for arbitrary data
    uint64_t h = 0xcbf29ce484222325ULL; // FNV offset basis
    const uint8_t* bytes = static_cast<const uint8_t*>(data);
    for (size_t i = 0; i < len; ++i) {
        h ^= bytes[i];
        h *= 0x100000001b3ULL; // FNV prime
    }
    add(murmur64(h));
}

uint64_t HyperLogLog::estimate() const {
    // Calculate harmonic mean
    double sum = 0.0;
    uint32_t numZeroRegisters = 0;
    
    for (uint32_t i = 0; i < numRegisters_; ++i) {
        sum += 1.0 / static_cast<double>(1ULL << registers_[i]);
        if (registers_[i] == 0) {
            numZeroRegisters++;
        }
    }
    
    // Raw HLL estimate
    double alpha = getAlpha(numRegisters_);
    double m = static_cast<double>(numRegisters_);
    double estimate = alpha * m * m / sum;
    
    // Small range correction (linear counting)
    if (estimate <= 2.5 * m) {
        if (numZeroRegisters > 0) {
            estimate = linearCounting(numZeroRegisters);
        }
    }
    // Large range correction (for 32-bit hash, not needed for 64-bit)
    // We use 64-bit hashes, so no correction needed for large values
    
    return static_cast<uint64_t>(estimate + 0.5); // Round to nearest integer
}

void HyperLogLog::merge(const HyperLogLog& other) {
    if (precision_ != other.precision_) {
        throw std::invalid_argument("Cannot merge HyperLogLogs with different precisions");
    }
    for (uint32_t i = 0; i < numRegisters_; ++i) {
        registers_[i] = std::max(registers_[i], other.registers_[i]);
    }
}

void HyperLogLog::clear() {
    std::fill(registers_.begin(), registers_.end(), 0);
}

// ============================================================================
// HLLCardinalityEstimator Implementation
// ============================================================================

HyperLogLog& HLLCardinalityEstimator::getOrCreateHLL(uint64_t keyHash) {
    auto it = groupHLLs_.find(keyHash);
    if (it == groupHLLs_.end()) {
        auto [newIt, inserted] = groupHLLs_.emplace(keyHash, HyperLogLog());
        globalHLL_.add(keyHash);
        return newIt->second;
    }
    return it->second;
}

uint64_t HLLCardinalityEstimator::estimateTotalGroups() const {
    return globalHLL_.estimate();
}

uint64_t HLLCardinalityEstimator::estimateForGroup(uint64_t keyHash) const {
    auto it = groupHLLs_.find(keyHash);
    if (it == groupHLLs_.end()) {
        return 0;
    }
    return it->second.estimate();
}

uint64_t HLLCardinalityEstimator::estimateCombined() const {
    HyperLogLog combined;
    for (const auto& [key, hll] : groupHLLs_) {
        combined.merge(hll);
    }
    return combined.estimate();
}

void HLLCardinalityEstimator::clear() {
    groupHLLs_.clear();
    globalHLL_.clear();
}

} // namespace common
} // namespace kuzu