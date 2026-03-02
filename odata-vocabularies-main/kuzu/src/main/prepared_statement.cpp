#include "main/prepared_statement.h"

/**
 * P3-156: PreparedStatement - Cached Query Plans
 * 
 * Purpose:
 * Represents a prepared (compiled) query statement. Stores parameter metadata
 * and summary information. Works with CachedPreparedStatement for plan reuse.
 * 
 * Architecture:
 * ```
 * PreparedStatement                 CachedPreparedStatement
 *   ├── success: bool                 ├── parsedStatement: shared_ptr
 *   ├── errMsg: string                ├── columns: vector<Expression*>
 *   ├── readOnly: bool                ├── logicalPlan: unique_ptr
 *   ├── parameterMap                  └── useInternalCatalogEntry
 *   ├── unknownParameters
 *   └── preparedSummary
 * ```
 * 
 * Prepared Statement Flow:
 * ```
 * conn.prepare("MATCH (n) WHERE n.id = $id RETURN n")
 *   │
 *   ├── Parse query
 *   ├── Bind (with parameter placeholders)
 *   ├── Create logical plan
 *   └── Return PreparedStatement
 * 
 * conn.executeWithParams(stmt, {{"id", Value(42)}})
 *   │
 *   ├── Rebind parameters with actual values
 *   ├── Execute logical plan
 *   └── Return QueryResult
 * ```
 * 
 * Parameter Types:
 * - Known: Parameters with values provided during prepare
 * - Unknown: Parameters to be bound during execute
 * 
 * Key Methods:
 * | Method | Description |
 * |--------|-------------|
 * | isSuccess() | Check if prepare succeeded |
 * | getErrorMessage() | Get error if failed |
 * | isReadOnly() | Check if read-only query |
 * | getStatementType() | Get statement type |
 * | getKnownParameters() | Get parameters with values |
 * | getUnknownParameters() | Get unbound parameters |
 * | updateParameter() | Update existing param value |
 * | addParameter() | Add new parameter value |
 * 
 * Validation:
 * - Dataframe pointers must match between prepare and execute
 * - Prevents subtle bugs from different dataframe references
 * 
 * CachedPreparedStatement:
 * - Stores parsed statement and logical plan
 * - Managed by cachedPreparedStatementManager in ClientContext
 * - Enables plan reuse across multiple executions
 * 
 * Usage:
 * ```cpp
 * auto stmt = conn.prepare("MATCH (n:Person {id: $id}) RETURN n.name");
 * auto result = conn.executeWithParams(stmt.get(), {{"id", Value(5)}});
 * // Can execute multiple times with different parameters
 * result = conn.executeWithParams(stmt.get(), {{"id", Value(10)}});
 * ```
 */

#include "binder/expression/expression.h" // IWYU pragma: keep
#include "common/exception/binder.h"
#include "common/types/value/value.h"
#include "planner/operator/logical_plan.h" // IWYU pragma: keep

using namespace kuzu::common;

namespace kuzu {
namespace main {

CachedPreparedStatement::CachedPreparedStatement() = default;
CachedPreparedStatement::~CachedPreparedStatement() = default;

std::vector<std::string> CachedPreparedStatement::getColumnNames() const {
    std::vector<std::string> names;
    for (auto& column : columns) {
        names.push_back(column->toString());
    }
    return names;
}

std::vector<LogicalType> CachedPreparedStatement::getColumnTypes() const {
    std::vector<LogicalType> types;
    for (auto& column : columns) {
        types.push_back(column->getDataType().copy());
    }
    return types;
}

bool PreparedStatement::isSuccess() const {
    return success;
}

std::string PreparedStatement::getErrorMessage() const {
    return errMsg;
}

bool PreparedStatement::isReadOnly() const {
    return readOnly;
}

StatementType PreparedStatement::getStatementType() const {
    return preparedSummary.statementType;
}

static void validateParam(const std::string& paramName, Value* newVal, Value* oldVal) {
    if (newVal->getDataType().getLogicalTypeID() == LogicalTypeID::POINTER &&
        newVal->getValue<uint8_t*>() != oldVal->getValue<uint8_t*>()) {
        throw BinderException(stringFormat(
            "When preparing the current statement the dataframe passed into parameter "
            "'{}' was different from the one provided during prepare. Dataframes parameters "
            "are only used during prepare; please make sure that they are either not passed into "
            "execute or they match the one passed during prepare.",
            paramName));
    }
}

std::unordered_set<std::string> PreparedStatement::getKnownParameters() {
    std::unordered_set<std::string> result;
    for (auto& [k, _] : parameterMap) {
        result.insert(k);
    }
    return result;
}

void PreparedStatement::updateParameter(const std::string& name, Value* value) {
    KU_ASSERT(parameterMap.contains(name));
    validateParam(name, value, parameterMap.at(name).get());
    *parameterMap.at(name) = std::move(*value);
}

void PreparedStatement::addParameter(const std::string& name, Value* value) {
    parameterMap.insert({name, std::make_shared<Value>(*value)});
}

PreparedStatement::~PreparedStatement() = default;

std::unique_ptr<PreparedStatement> PreparedStatement::getPreparedStatementWithError(
    const std::string& errorMessage) {
    auto preparedStatement = std::make_unique<PreparedStatement>();
    preparedStatement->success = false;
    preparedStatement->errMsg = errorMessage;
    return preparedStatement;
}

} // namespace main
} // namespace kuzu
