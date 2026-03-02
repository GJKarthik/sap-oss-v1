#include "storage/predicate/null_predicate.h"

/**
 * P3-206: ColumnNullPredicate - NULL Predicate Zone Map Filtering
 * 
 * Purpose:
 * Implements zone map filtering for IS NULL and IS NOT NULL predicates.
 * Uses null statistics to skip chunks where predicate cannot match.
 * 
 * Class:
 * ```
 * ColumnNullPredicate : ColumnPredicate {
 *   expressionType: IS_NULL | IS_NOT_NULL
 * }
 * ```
 * 
 * Statistics Used:
 * | Statistic | Description |
 * |-----------|-------------|
 * | guaranteedNoNulls | All values in chunk are non-null |
 * | guaranteedAllNulls | All values in chunk are null |
 * 
 * checkZoneMap() Logic:
 * ```
 * checkZoneMap(mergedStats):
 *   IF expressionType == IS_NULL:
 *     // Looking for null values
 *     IF guaranteedNoNulls:
 *       RETURN SKIP_SCAN  // No nulls exist, skip
 *     ELSE:
 *       RETURN ALWAYS_SCAN  // Might have nulls
 *   
 *   ELSE IF expressionType == IS_NOT_NULL:
 *     // Looking for non-null values
 *     IF guaranteedAllNulls:
 *       RETURN SKIP_SCAN  // All are null, skip
 *     ELSE:
 *       RETURN ALWAYS_SCAN  // Might have non-nulls
 * ```
 * 
 * Truth Table:
 * | Predicate | guaranteedNoNulls | guaranteedAllNulls | Result |
 * |-----------|-------------------|-------------------|--------|
 * | IS NULL | true | - | SKIP_SCAN |
 * | IS NULL | false | - | ALWAYS_SCAN |
 * | IS NOT NULL | - | true | SKIP_SCAN |
 * | IS NOT NULL | - | false | ALWAYS_SCAN |
 * 
 * Examples:
 * 
 * Query: SELECT * FROM t WHERE name IS NULL
 * ```
 * Chunk A: guaranteedNoNulls=true  → SKIP_SCAN (no nulls)
 * Chunk B: guaranteedNoNulls=false → ALWAYS_SCAN (might have nulls)
 * ```
 * 
 * Query: SELECT * FROM t WHERE name IS NOT NULL
 * ```
 * Chunk A: guaranteedAllNulls=true  → SKIP_SCAN (all null)
 * Chunk B: guaranteedAllNulls=false → ALWAYS_SCAN (might have values)
 * ```
 * 
 * Integration:
 * - Used by ColumnPredicateSet::checkZoneMap()
 * - Created by ColumnPredicateUtil::tryConvertToIsNull/IsNotNull
 * - Statistics from column chunk metadata
 */

#include "storage/table/column_chunk_stats.h"

namespace kuzu::storage {
common::ZoneMapCheckResult ColumnNullPredicate::checkZoneMap(
    const MergedColumnChunkStats& mergedStats) const {
    const bool statToCheck = (expressionType == common::ExpressionType::IS_NULL) ?
                                 mergedStats.guaranteedNoNulls :
                                 mergedStats.guaranteedAllNulls;
    return statToCheck ? common::ZoneMapCheckResult::SKIP_SCAN :
                         common::ZoneMapCheckResult::ALWAYS_SCAN;
}

} // namespace kuzu::storage
