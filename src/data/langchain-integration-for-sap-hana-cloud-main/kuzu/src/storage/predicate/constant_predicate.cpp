#include "storage/predicate/constant_predicate.h"

/**
 * P3-207: ColumnConstantPredicate - Constant Comparison Zone Map Filtering
 * 
 * Purpose:
 * Implements zone map filtering for comparison predicates against constants.
 * Uses min/max statistics to skip chunks where predicate cannot match.
 * 
 * Class:
 * ```
 * ColumnConstantPredicate : ColumnPredicate {
 *   value: Value        // Constant to compare against
 *   expressionType: ExpressionType  // =, <>, <, <=, >, >=
 * }
 * ```
 * 
 * inRange() Helper:
 * ```
 * inRange(min, max, val):
 *   RETURN val >= min AND val <= max
 * ```
 * 
 * checkZoneMapSwitch() Logic:
 * ```
 * checkZoneMapSwitch<T>(stats, expressionType, value):
 *   IF stats.min OR stats.max not available:
 *     RETURN ALWAYS_SCAN  // Can't optimize
 *   
 *   min = stats.min, max = stats.max, c = value
 *   
 *   SWITCH expressionType:
 *     EQUALS:
 *       IF c NOT in [min, max]: SKIP_SCAN
 *     
 *     NOT_EQUALS:
 *       IF min == max == c: SKIP_SCAN (all values equal c)
 *     
 *     GREATER_THAN:
 *       IF c >= max: SKIP_SCAN (no value > c)
 *     
 *     GREATER_THAN_EQUALS:
 *       IF c > max: SKIP_SCAN (no value >= c)
 *     
 *     LESS_THAN:
 *       IF c <= min: SKIP_SCAN (no value < c)
 *     
 *     LESS_THAN_EQUALS:
 *       IF c < min: SKIP_SCAN (no value <= c)
 *   
 *   RETURN ALWAYS_SCAN
 * ```
 * 
 * Zone Map Decision Table:
 * | Predicate | Condition for SKIP_SCAN |
 * |-----------|-------------------------|
 * | col = c | c < min OR c > max |
 * | col <> c | min == max == c |
 * | col > c | c >= max |
 * | col >= c | c > max |
 * | col < c | c <= min |
 * | col <= c | c < min |
 * 
 * Examples:
 * ```
 * Chunk stats: min=10, max=50
 * 
 * WHERE age = 5   → SKIP_SCAN (5 < 10)
 * WHERE age = 30  → ALWAYS_SCAN (30 in [10,50])
 * WHERE age > 60  → SKIP_SCAN (60 >= 50)
 * WHERE age < 5   → SKIP_SCAN (5 <= 10)
 * ```
 * 
 * Type Dispatch:
 * ```
 * checkZoneMap(stats):
 *   physicalType = value.getDataType().getPhysicalType()
 *   TypeUtils::visit(physicalType,
 *     [&]<StorageValueType T>() { checkZoneMapSwitch<T>(...) },
 *     [&](auto) { ALWAYS_SCAN }  // Non-storage types
 *   )
 * ```
 * 
 * toString() Formatting:
 * - STRING, LIST, STRUCT: wrap value in quotes
 * - UUID, TIMESTAMP, DATE: wrap in quotes
 * - Others: plain value
 */

#include "common/type_utils.h"
#include "function/comparison/comparison_functions.h"
#include "storage/compression/compression.h"
#include "storage/table/column_chunk_stats.h"

using namespace kuzu::common;
using namespace kuzu::function;

namespace kuzu {
namespace storage {

template<typename T>
bool inRange(T min, T max, T val) {
    auto a = GreaterThanEquals::operation<T>(val, min);
    auto b = LessThanEquals::operation<T>(val, max);
    return a && b;
}

template<typename T>
ZoneMapCheckResult checkZoneMapSwitch(const MergedColumnChunkStats& mergedStats,
    ExpressionType expressionType, const Value& value) {
    // If the chunk is casted from a non-storage value type
    // The stats will be empty, skip the zone map check in this case
    if (mergedStats.stats.min.has_value() && mergedStats.stats.max.has_value()) {
        auto max = mergedStats.stats.max->get<T>();
        auto min = mergedStats.stats.min->get<T>();
        auto constant = value.getValue<T>();
        switch (expressionType) {
        case ExpressionType::EQUALS: {
            if (!inRange<T>(min, max, constant)) {
                return ZoneMapCheckResult::SKIP_SCAN;
            }
        } break;
        case ExpressionType::NOT_EQUALS: {
            if (Equals::operation<T>(constant, min) && Equals::operation<T>(constant, max)) {
                return ZoneMapCheckResult::SKIP_SCAN;
            }
        } break;
        case ExpressionType::GREATER_THAN: {
            if (GreaterThanEquals::operation<T>(constant, max)) {
                return ZoneMapCheckResult::SKIP_SCAN;
            }
        } break;
        case ExpressionType::GREATER_THAN_EQUALS: {
            if (GreaterThan::operation<T>(constant, max)) {
                return ZoneMapCheckResult::SKIP_SCAN;
            }
        } break;
        case ExpressionType::LESS_THAN: {
            if (LessThanEquals::operation<T>(constant, min)) {
                return ZoneMapCheckResult::SKIP_SCAN;
            }
        } break;
        case ExpressionType::LESS_THAN_EQUALS: {
            if (LessThan::operation<T>(constant, min)) {
                return ZoneMapCheckResult::SKIP_SCAN;
            }
        } break;
        default:
            KU_UNREACHABLE;
        }
    }
    return ZoneMapCheckResult::ALWAYS_SCAN;
}

ZoneMapCheckResult ColumnConstantPredicate::checkZoneMap(
    const MergedColumnChunkStats& stats) const {
    auto physicalType = value.getDataType().getPhysicalType();
    return TypeUtils::visit(
        physicalType,
        [&]<StorageValueType T>(T) { return checkZoneMapSwitch<T>(stats, expressionType, value); },
        [&](auto) { return ZoneMapCheckResult::ALWAYS_SCAN; });
}

std::string ColumnConstantPredicate::toString() {
    std::string valStr;
    if (value.getDataType().getPhysicalType() == PhysicalTypeID::STRING ||
        value.getDataType().getPhysicalType() == PhysicalTypeID::LIST ||
        value.getDataType().getPhysicalType() == PhysicalTypeID::ARRAY ||
        value.getDataType().getPhysicalType() == PhysicalTypeID::STRUCT ||
        value.getDataType().getLogicalTypeID() == LogicalTypeID::UUID ||
        value.getDataType().getLogicalTypeID() == LogicalTypeID::TIMESTAMP ||
        value.getDataType().getLogicalTypeID() == LogicalTypeID::DATE ||
        value.getDataType().getLogicalTypeID() == LogicalTypeID::INTERVAL) {
        valStr = stringFormat("'{}'", value.toString());
    } else {
        valStr = value.toString();
    }
    return stringFormat("{} {}", ColumnPredicate::toString(), valStr);
}

} // namespace storage
} // namespace kuzu
