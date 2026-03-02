#pragma once

#include "aggregate_function.h"
#include "catalog/catalog_entry/catalog_entry_type.h"
#include "function.h"

namespace kuzu {
namespace transaction {
class Transaction;
} // namespace transaction

namespace catalog {
class FunctionCatalogEntry;
} // namespace catalog

namespace function {

/**
 * P2-57: Function Matching Utilities
 * 
 * This class provides utilities for resolving function calls to specific
 * function implementations based on name and argument types.
 * 
 * Current Design:
 * The class has separate methods for different function types:
 * - matchFunction(): For scalar and table functions
 * - matchAggregateFunction(): For aggregate functions with isDistinct parameter
 * 
 * Why Not Unified Yet:
 * Aggregate functions have additional matching criteria (isDistinct flag)
 * that don't apply to scalar/table functions. A truly unified interface would need:
 * 
 * Option A: Generic parameters
 *   matchFunction<FunctionType>(name, types, ...extraArgs)
 *   - Pros: Type-safe, compile-time checking
 *   - Cons: Complex template metaprogramming, harder to extend
 * 
 * Option B: Config struct
 *   struct MatchConfig { bool isDistinct; FunctionType type; ... };
 *   matchFunction(name, types, config)
 *   - Pros: Flexible, easy to extend
 *   - Cons: Runtime overhead, looser type safety
 * 
 * Option C: Visitor pattern
 *   FunctionMatcher visitor(name, types);
 *   catalogEntry->accept(visitor);
 *   - Pros: Clean OO design, extensible
 *   - Cons: More classes, indirection overhead
 * 
 * Current Decision:
 * Keep separate methods as they work correctly and the extra parameter for
 * aggregates (isDistinct) would complicate a unified interface. The cognitive
 * overhead of understanding two methods is minimal compared to understanding
 * a complex unified interface.
 * 
 * If we add more function types (e.g., window functions) with their own
 * matching criteria, revisiting this design would be worthwhile.
 */
class BuiltInFunctionsUtils {
public:
    /**
     * Match a function by name and input types.
     * For scalar and table functions.
     */
    static KUZU_API Function* matchFunction(const std::string& name,
        const catalog::FunctionCatalogEntry* catalogEntry) {
        return matchFunction(name, {}, catalogEntry);
    }
    static KUZU_API Function* matchFunction(const std::string& name,
        const std::vector<common::LogicalType>& inputTypes,
        const catalog::FunctionCatalogEntry* functionEntry);

    static AggregateFunction* matchAggregateFunction(const std::string& name,
        const std::vector<common::LogicalType>& inputTypes, bool isDistinct,
        const catalog::FunctionCatalogEntry* functionEntry);

    static KUZU_API uint32_t getCastCost(common::LogicalTypeID inputTypeID,
        common::LogicalTypeID targetTypeID);

    static KUZU_API std::string getFunctionMatchFailureMsg(const std::string name,
        const std::vector<common::LogicalType>& inputTypes, const std::string& supportedInputs,
        bool isDistinct = false);

private:
    /**
     * P2-58: Casting Cost Functions Placement
     * 
     * These functions calculate the "cost" of implicit type casting, used for
     * function overload resolution. A lower cost means a better match.
     * 
     * Why Keep in BuiltInFunctionsUtils (not move to binder):
     * 
     * 1. Function Matching Dependency:
     *    These functions are called from matchFunction() and getAggregateFunctionCost()
     *    which are core to function resolution. Moving to binder would create
     *    circular dependencies or require awkward parameter passing.
     * 
     * 2. Domain Alignment:
     *    Casting cost is fundamentally about function matching, not expression binding.
     *    The binder needs to know WHICH function to call; it doesn't need to know
     *    the internal cost calculations.
     * 
     * 3. Encapsulation:
     *    Keeping cast cost private within this class maintains encapsulation.
     *    Only matchFunction() results are needed externally, not the cost details.
     * 
     * 4. Performance:
     *    Current design allows efficient inline cost calculations during matching.
     *    Moving to binder would add indirection.
     * 
     * Cast Cost Rules:
     * | Cast Type | Cost | Example |
     * |-----------|------|---------|
     * | Exact match | 0 | INT64 → INT64 |
     * | Widening | 1-10 | INT32 → INT64 |
     * | Narrowing | High | INT64 → INT32 |
     * | String conversion | Higher | INT64 → STRING |
     * | Invalid | UINT32_MAX | Cannot cast |
     * 
     * The binder uses these costs indirectly via matchFunction() to:
     * - Resolve overloaded function calls
     * - Insert implicit cast operators when needed
     * - Generate helpful error messages on ambiguity
     */
    static uint32_t getTargetTypeCost(common::LogicalTypeID typeID);

    static uint32_t castInt64(common::LogicalTypeID targetTypeID);

    static uint32_t castInt32(common::LogicalTypeID targetTypeID);

    static uint32_t castInt16(common::LogicalTypeID targetTypeID);

    static uint32_t castInt8(common::LogicalTypeID targetTypeID);

    static uint32_t castUInt64(common::LogicalTypeID targetTypeID);

    static uint32_t castUInt32(common::LogicalTypeID targetTypeID);

    static uint32_t castUInt16(common::LogicalTypeID targetTypeID);

    static uint32_t castUInt8(common::LogicalTypeID targetTypeID);

    static uint32_t castInt128(common::LogicalTypeID targetTypeID);

    static uint32_t castDouble(common::LogicalTypeID targetTypeID);

    static uint32_t castFloat(common::LogicalTypeID targetTypeID);

    static uint32_t castDecimal(common::LogicalTypeID targetTypeID);

    static uint32_t castDate(common::LogicalTypeID targetTypeID);

    static uint32_t castSerial(common::LogicalTypeID targetTypeID);

    static uint32_t castTimestamp(common::LogicalTypeID targetTypeID);

    static uint32_t castFromString(common::LogicalTypeID inputTypeID);

    static uint32_t castUUID(common::LogicalTypeID targetTypeID);

    static uint32_t castList(common::LogicalTypeID targetTypeID);

    static uint32_t castArray(common::LogicalTypeID targetTypeID);

    static Function* getBestMatch(std::vector<Function*>& functions);

    static uint32_t getFunctionCost(const std::vector<common::LogicalType>& inputTypes,
        Function* function, catalog::CatalogEntryType type);
    static uint32_t matchParameters(const std::vector<common::LogicalType>& inputTypes,
        const std::vector<common::LogicalTypeID>& targetTypeIDs);
    static uint32_t matchVarLengthParameters(const std::vector<common::LogicalType>& inputTypes,
        common::LogicalTypeID targetTypeID);
    static uint32_t getAggregateFunctionCost(const std::vector<common::LogicalType>& inputTypes,
        bool isDistinct, AggregateFunction* function);

    static void validateSpecialCases(std::vector<Function*>& candidateFunctions,
        const std::string& name, const std::vector<common::LogicalType>& inputTypes,
        const function::function_set& set);
};

} // namespace function
} // namespace kuzu
