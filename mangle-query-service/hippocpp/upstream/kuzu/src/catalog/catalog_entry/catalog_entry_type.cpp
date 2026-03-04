#include "catalog/catalog_entry/catalog_entry_type.h"

/**
 * P3-152: CatalogEntryType - Entry Type Utilities
 * 
 * Purpose:
 * Provides string conversion utilities for CatalogEntryType enum values.
 * Used for debugging, logging, error messages, and user-facing output.
 * 
 * CatalogEntryType Enum:
 * ```
 * Table Types:
 *   NODE_TABLE_ENTRY         - Node/vertex tables
 *   REL_GROUP_ENTRY          - Relationship/edge tables
 *   FOREIGN_TABLE_ENTRY      - External tables (attached DBs)
 * 
 * Function Types:
 *   SCALAR_FUNCTION_ENTRY    - Scalar functions (upper, length)
 *   AGGREGATE_FUNCTION_ENTRY - Aggregates (sum, count, avg)
 *   TABLE_FUNCTION_ENTRY     - Table-returning (read_csv)
 *   STANDALONE_TABLE_FUNCTION_ENTRY - Special table functions
 *   REWRITE_FUNCTION_ENTRY   - Query rewrite functions
 *   COPY_FUNCTION_ENTRY      - COPY FROM functions
 *   SCALAR_MACRO_ENTRY       - User-defined macros
 * 
 * Other Types:
 *   SEQUENCE_ENTRY           - Auto-increment sequences
 *   INDEX_ENTRY              - Secondary indexes
 *   TYPE_ENTRY               - User-defined types
 *   DUMMY_ENTRY              - Placeholder/internal
 * ```
 * 
 * Utility Classes:
 * 
 * 1. CatalogEntryTypeUtils::toString(type)
 *    - Returns internal enum name (e.g., "NODE_TABLE_ENTRY")
 *    - Used for debugging, serialization, logging
 * 
 * 2. FunctionEntryTypeUtils::toString(type)
 *    - Returns user-friendly function type names
 *    - Used in error messages shown to users
 *    - Examples:
 *      * SCALAR_MACRO_ENTRY → "MACRO FUNCTION"
 *      * AGGREGATE_FUNCTION_ENTRY → "AGGREGATE FUNCTION"
 *      * SCALAR_FUNCTION_ENTRY → "SCALAR FUNCTION"
 *      * TABLE_FUNCTION_ENTRY → "TABLE FUNCTION"
 * 
 * Usage Examples:
 * ```
 * // Debug logging
 * log("Created entry of type: " + CatalogEntryTypeUtils::toString(type));
 * 
 * // User error message
 * throw Exception("Cannot DROP " + FunctionEntryTypeUtils::toString(type));
 * ```
 * 
 * Type Categories (for dispatching):
 * - isTableType(): NODE_TABLE_ENTRY, REL_GROUP_ENTRY, FOREIGN_TABLE_ENTRY
 * - isFunctionType(): *_FUNCTION_ENTRY, SCALAR_MACRO_ENTRY
 * - isSerializable(): Most types (not DUMMY_ENTRY)
 */

#include "common/assert.h"

namespace kuzu {
namespace catalog {

std::string CatalogEntryTypeUtils::toString(CatalogEntryType type) {
    switch (type) {
    case CatalogEntryType::NODE_TABLE_ENTRY:
        return "NODE_TABLE_ENTRY";
    case CatalogEntryType::REL_GROUP_ENTRY:
        return "REL_GROUP_ENTRY";
    case CatalogEntryType::FOREIGN_TABLE_ENTRY:
        return "FOREIGN_TABLE_ENTRY";
    case CatalogEntryType::SCALAR_MACRO_ENTRY:
        return "SCALAR_MACRO_ENTRY";
    case CatalogEntryType::AGGREGATE_FUNCTION_ENTRY:
        return "AGGREGATE_FUNCTION_ENTRY";
    case CatalogEntryType::SCALAR_FUNCTION_ENTRY:
        return "SCALAR_FUNCTION_ENTRY";
    case CatalogEntryType::REWRITE_FUNCTION_ENTRY:
        return "REWRITE_FUNCTION_ENTRY";
    case CatalogEntryType::TABLE_FUNCTION_ENTRY:
        return "TABLE_FUNCTION_ENTRY";
    case CatalogEntryType::STANDALONE_TABLE_FUNCTION_ENTRY:
        return "STANDALONE_TABLE_FUNCTION_ENTRY";
    case CatalogEntryType::COPY_FUNCTION_ENTRY:
        return "COPY_FUNCTION_ENTRY";
    case CatalogEntryType::DUMMY_ENTRY:
        return "DUMMY_ENTRY";
    case CatalogEntryType::SEQUENCE_ENTRY:
        return "SEQUENCE_ENTRY";
    default:
        KU_UNREACHABLE;
    }
}

std::string FunctionEntryTypeUtils::toString(CatalogEntryType type) {
    switch (type) {
    case CatalogEntryType::SCALAR_MACRO_ENTRY:
        return "MACRO FUNCTION";
    case CatalogEntryType::AGGREGATE_FUNCTION_ENTRY:
        return "AGGREGATE FUNCTION";
    case CatalogEntryType::SCALAR_FUNCTION_ENTRY:
        return "SCALAR FUNCTION";
    case CatalogEntryType::REWRITE_FUNCTION_ENTRY:
        return "REWRITE FUNCTION";
    case CatalogEntryType::TABLE_FUNCTION_ENTRY:
        return "TABLE FUNCTION";
    case CatalogEntryType::STANDALONE_TABLE_FUNCTION_ENTRY:
        return "STANDALONE TABLE FUNCTION";
    case CatalogEntryType::COPY_FUNCTION_ENTRY:
        return "COPY FUNCTION";
    default:
        KU_UNREACHABLE;
    }
}

} // namespace catalog
} // namespace kuzu
