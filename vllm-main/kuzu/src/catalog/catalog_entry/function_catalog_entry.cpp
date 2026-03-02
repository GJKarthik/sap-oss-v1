#include "catalog/catalog_entry/function_catalog_entry.h"

/**
 * P3-146: FunctionCatalogEntry - Function Metadata
 * 
 * Purpose:
 * Catalog entry for registered functions in the database.
 * Stores function name and the function_set containing all overloads.
 * 
 * Function Types (via CatalogEntryType):
 * ```
 * SCALAR_FUNCTION_ENTRY    → Scalar functions (length, upper, etc.)
 * AGGREGATE_FUNCTION_ENTRY → Aggregate functions (sum, count, avg)
 * TABLE_FUNCTION_ENTRY     → Table-returning functions (read_csv, etc.)
 * REWRITE_FUNCTION_ENTRY   → Query rewrite functions
 * ```
 * 
 * Architecture:
 * ```
 * CatalogEntry (base)
 *   └── FunctionCatalogEntry
 *         └── functionSet: function_set (vector of Function*)
 *               └── Overloads with different signatures
 * ```
 * 
 * Function Set (Overloading):
 * ```
 * Example: "add" function has multiple overloads
 *   functionSet[0] = add(INT64, INT64) → INT64
 *   functionSet[1] = add(DOUBLE, DOUBLE) → DOUBLE
 *   functionSet[2] = add(INT128, INT128) → INT128
 * 
 * During binding:
 *   ExpressionBinder::matchFunction(functionSet, inputTypes)
 *   → Selects best matching overload
 * ```
 * 
 * Registration:
 * ```
 * // Built-in functions (registered at startup)
 * BuiltInFunctionUtils::registerScalarFunctions()
 *   → Creates FunctionCatalogEntry for each function
 *   → Adds to catalog's scalarFunctions set
 * 
 * // Extension functions
 * extension->registerFunctions(catalog)
 *   → Adds custom FunctionCatalogEntry
 * ```
 * 
 * Key Properties:
 * - name: Function name (case-insensitive lookup)
 * - functionSet: All overloads for this function name
 * - type: Distinguishes scalar/aggregate/table/rewrite
 * 
 * Usage in Query Processing:
 * ```
 * SELECT upper(name) FROM Person
 *         │
 *         ├── 1. ExpressionBinder looks up "upper"
 *         ├── 2. Gets FunctionCatalogEntry from catalog
 *         ├── 3. Matches signature: upper(STRING) → STRING
 *         └── 4. Creates FunctionExpression with matched function
 * ```
 * 
 * Constructor:
 * - Takes entryType, name, and function_set
 * - Moves function_set for efficiency
 * 
 * Not Serialized:
 * - Functions are re-registered at startup
 * - Extensions re-register when loaded
 * 
 * Entry Types:
 * - SCALAR_FUNCTION_ENTRY
 * - AGGREGATE_FUNCTION_ENTRY  
 * - TABLE_FUNCTION_ENTRY
 * - REWRITE_FUNCTION_ENTRY
 */

namespace kuzu {
namespace catalog {

FunctionCatalogEntry::FunctionCatalogEntry(CatalogEntryType entryType, std::string name,
    function::function_set functionSet)
    : CatalogEntry{entryType, std::move(name)}, functionSet{std::move(functionSet)} {}

} // namespace catalog
} // namespace kuzu
