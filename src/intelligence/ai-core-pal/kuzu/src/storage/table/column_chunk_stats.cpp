#include "storage/table/column_chunk_stats.h"

/**
 * P3-216: ColumnChunkStats - Zone Map Statistics Management
 * 
 * Purpose:
 * Maintains min/max statistics for column chunks to enable zone map filtering.
 * Tracks values during writes and provides merge operations for combining stats.
 * 
 * Architecture:
 * ```
 * ColumnChunkStats {
 *   min: optional<StorageValue>  // Minimum value seen
 *   max: optional<StorageValue>  // Maximum value seen
 * }
 * 
 * MergedColumnChunkStats {
 *   stats: ColumnChunkStats
 *   guaranteedNoNulls: bool     // All values non-null
 *   guaranteedAllNulls: bool    // All values null
 * }
 * ```
 * 
 * update() from ColumnChunkData:
 * ```
 * update(data, offset, numValues, physicalType):
 *   IF isStorageValueType(physicalType) OR physicalType == INTERNAL_ID:
 *     (minVal, maxVal) = getMinMaxStorageValue(data, offset, numValues)
 *     update(minVal, maxVal, physicalType)
 * ```
 * 
 * update() from ValueVector:
 * ```
 * update(vector, offset, numValues, physicalType):
 *   IF isStorageValueType(physicalType) OR physicalType == INTERNAL_ID:
 *     (minVal, maxVal) = getMinMaxStorageValue(vector, offset, numValues)
 *     update(minVal, maxVal, physicalType)
 * ```
 * 
 * update() with min/max:
 * ```
 * update(newMin, newMax, dataType):
 *   IF !min.has_value() OR (newMin AND min > newMin):
 *     min = newMin
 *   IF !max.has_value() OR (newMax AND newMax > max):
 *     max = newMax
 * ```
 * 
 * update() Single Value:
 * ```
 * update(val, dataType):
 *   IF !min.has_value() OR min > val:
 *     min = val
 *   IF !max.has_value() OR val > max:
 *     max = val
 * ```
 * 
 * MergedColumnChunkStats::merge():
 * ```
 * merge(other, dataType):
 *   stats.update(other.stats.min, other.stats.max, dataType)
 *   guaranteedNoNulls &= other.guaranteedNoNulls
 *   guaranteedAllNulls &= other.guaranteedAllNulls
 * ```
 * 
 * Type Support:
 * - StorageValueType: int8-64, uint8-64, float, double
 * - INTERNAL_ID: special handling
 * - Other types: stats not tracked
 * 
 * Usage for Zone Map Filtering:
 * ```
 * // During scan
 * IF predicate.checkZoneMap(mergedStats) == SKIP_SCAN:
 *   continue  // Skip entire chunk
 * ```
 */

#include "common/type_utils.h"
#include "common/types/types.h"
#include "common/vector/value_vector.h"
#include "storage/table/column_chunk_data.h"

namespace kuzu {
namespace storage {

void ColumnChunkStats::update(const ColumnChunkData& data, uint64_t offset, uint64_t numValues,
    common::PhysicalTypeID physicalType) {
    const bool isStorageValueType =
        common::TypeUtils::visit(physicalType, []<typename T>(T) { return StorageValueType<T>; });
    if (isStorageValueType || physicalType == common::PhysicalTypeID::INTERNAL_ID) {
        auto [minVal, maxVal] = getMinMaxStorageValue(data, offset, numValues, physicalType);
        update(minVal, maxVal, physicalType);
    }
}

void ColumnChunkStats::update(const common::ValueVector& data, uint64_t offset, uint64_t numValues,
    common::PhysicalTypeID physicalType) {
    const bool isStorageValueType =
        common::TypeUtils::visit(physicalType, []<typename T>(T) { return StorageValueType<T>; });
    if (isStorageValueType || physicalType == common::PhysicalTypeID::INTERNAL_ID) {
        auto [minVal, maxVal] = getMinMaxStorageValue(data, offset, numValues, physicalType);
        update(minVal, maxVal, physicalType);
    }
}

void ColumnChunkStats::update(std::optional<StorageValue> newMin,
    std::optional<StorageValue> newMax, common::PhysicalTypeID dataType) {
    if (!min.has_value() || (newMin.has_value() && min->gt(*newMin, dataType))) {
        min = newMin;
    }
    if (!max.has_value() || (newMax.has_value() && newMax->gt(*max, dataType))) {
        max = newMax;
    }
}

void ColumnChunkStats::update(StorageValue val, common::PhysicalTypeID dataType) {
    if (!min.has_value() || min->gt(val, dataType)) {
        min = val;
    }
    if (!max.has_value() || val.gt(*max, dataType)) {
        max = val;
    }
}

void ColumnChunkStats::reset() {
    *this = {};
}

void MergedColumnChunkStats::merge(const MergedColumnChunkStats& o,
    common::PhysicalTypeID dataType) {
    stats.update(o.stats.min, o.stats.max, dataType);
    guaranteedNoNulls = guaranteedNoNulls && o.guaranteedNoNulls;
    guaranteedAllNulls = guaranteedAllNulls && o.guaranteedAllNulls;
}

} // namespace storage
} // namespace kuzu
