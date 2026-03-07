#include "main/query_result.h"

/**
 * P3-157: QueryResult - Query Execution Results
 * 
 * Purpose:
 * Represents the result of executing a query. Provides iteration over result
 * rows, access to column metadata, and Arrow format conversion.
 * 
 * Architecture:
 * ```
 * QueryResult (base)
 *   ├── MaterializedQueryResult  // All rows in memory
 *   └── ArrowQueryResult         // Arrow batch format
 * 
 * QueryResult
 *   ├── type: QueryResultType    // FTABLE or ARROW
 *   ├── columnNames: vector<string>
 *   ├── columnTypes: vector<LogicalType>
 *   ├── tuple: shared_ptr<FlatTuple>
 *   ├── querySummary: unique_ptr<QuerySummary>
 *   └── nextQueryResult: unique_ptr<QueryResult>  // Chained results
 * ```
 * 
 * Iteration Patterns:
 * ```cpp
 * // Pattern 1: Direct iteration
 * while (result->hasNext()) {
 *     auto tuple = result->getNext();
 *     auto val = tuple->getValue(0);
 * }
 * 
 * // Pattern 2: Arrow batches
 * while (result->hasNextArrowChunk()) {
 *     auto chunk = result->getNextArrowChunk();
 *     // Process Arrow format
 * }
 * 
 * // Pattern 3: Multiple statements
 * while (result->hasNextQueryResult()) {
 *     result = result->getNextQueryResult();
 *     // Process next statement's result
 * }
 * ```
 * 
 * Key Methods:
 * | Method | Description |
 * |--------|-------------|
 * | isSuccess() | Check if query succeeded |
 * | getErrorMessage() | Get error if failed |
 * | getNumColumns() | Number of result columns |
 * | getColumnNames() | Column name list |
 * | getColumnDataTypes() | Column type list |
 * | getQuerySummary() | Timing and statistics |
 * | getArrowSchema() | Arrow schema |
 * | hasNext() | Check for more rows |
 * | getNext() | Get next result row |
 * 
 * QuerySummary:
 * ```
 * QuerySummary {
 *   compilingTime: double   // Parse + Bind + Plan time
 *   executionTime: double   // Physical plan execution time
 * }
 * ```
 * 
 * Lifecycle Management:
 * - Tracks dbLifeCycleManager to detect closed database
 * - Throws if database closed during iteration
 * - Prevents use-after-free scenarios
 * 
 * Result Chaining:
 * - Multiple statements produce linked results
 * - nextQueryResult links results together
 * - QueryResultIterator traverses chain
 */

#include "common/arrow/arrow_converter.h"
#include "main/query_result/materialized_query_result.h"
#include "processor/result/flat_tuple.h"

using namespace kuzu::common;
using namespace kuzu::processor;

namespace kuzu {
namespace main {

QueryResult::QueryResult()
    : type{QueryResultType::FTABLE}, nextQueryResult{nullptr}, queryResultIterator{this},
      dbLifeCycleManager{nullptr} {}

QueryResult::QueryResult(QueryResultType type)
    : type{type}, nextQueryResult{nullptr}, queryResultIterator{this}, dbLifeCycleManager{nullptr} {

}

QueryResult::QueryResult(QueryResultType type, std::vector<std::string> columnNames,
    std::vector<LogicalType> columnTypes)
    : type{type}, columnNames{std::move(columnNames)}, columnTypes{std::move(columnTypes)},
      nextQueryResult{nullptr}, queryResultIterator{this}, dbLifeCycleManager{nullptr} {
    tuple = std::make_shared<FlatTuple>(this->columnTypes);
}

QueryResult::~QueryResult() = default;

bool QueryResult::isSuccess() const {
    return success;
}

std::string QueryResult::getErrorMessage() const {
    return errMsg;
}

size_t QueryResult::getNumColumns() const {
    return columnTypes.size();
}

std::vector<std::string> QueryResult::getColumnNames() const {
    return columnNames;
}

std::vector<LogicalType> QueryResult::getColumnDataTypes() const {
    return LogicalType::copy(columnTypes);
}

QuerySummary* QueryResult::getQuerySummary() const {
    return querySummary.get();
}

QuerySummary* QueryResult::getQuerySummaryUnsafe() {
    return querySummary.get();
}

void QueryResult::checkDatabaseClosedOrThrow() const {
    if (!dbLifeCycleManager) {
        return;
    }
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
}

bool QueryResult::hasNextQueryResult() const {
    checkDatabaseClosedOrThrow();
    return queryResultIterator.hasNextQueryResult();
}

QueryResult* QueryResult::getNextQueryResult() {
    checkDatabaseClosedOrThrow();
    if (hasNextQueryResult()) {
        ++queryResultIterator;
        return queryResultIterator.getCurrentResult();
    }
    return nullptr;
}

std::unique_ptr<ArrowSchema> QueryResult::getArrowSchema() const {
    checkDatabaseClosedOrThrow();
    return ArrowConverter::toArrowSchema(getColumnDataTypes(), getColumnNames(),
        false /* fallbackExtensionTypes */);
}

void QueryResult::validateQuerySucceed() const {
    if (!success) {
        throw Exception(errMsg);
    }
}

void QueryResult::setColumnNames(std::vector<std::string> columnNames) {
    this->columnNames = std::move(columnNames);
}

void QueryResult::setColumnTypes(std::vector<LogicalType> columnTypes) {
    this->columnTypes = std::move(columnTypes);
    tuple = std::make_shared<FlatTuple>(this->columnTypes);
}

void QueryResult::addNextResult(std::unique_ptr<QueryResult> next_) {
    nextQueryResult = std::move(next_);
}

std::unique_ptr<QueryResult> QueryResult::moveNextResult() {
    return std::move(nextQueryResult);
}

void QueryResult::setQuerySummary(std::unique_ptr<QuerySummary> summary) {
    querySummary = std::move(summary);
}

void QueryResult::setDBLifeCycleManager(
    std::shared_ptr<DatabaseLifeCycleManager> dbLifeCycleManager) {
    this->dbLifeCycleManager = dbLifeCycleManager;
    if (nextQueryResult) {
        nextQueryResult->setDBLifeCycleManager(dbLifeCycleManager);
    }
}

/**
 * P2-63: Error Query Result Design Considerations
 * 
 * This function creates a QueryResult that represents an error condition.
 * 
 * Should We Introduce a Dedicated ErrorQueryResult Class?
 * 
 * Arguments FOR a dedicated class:
 * 1. Type Safety: Explicit ErrorQueryResult type prevents misuse
 * 2. API Clarity: `result->isError()` vs checking success flag
 * 3. Memory: Error results don't need column vectors, tuple buffers, etc.
 * 4. Interface: Error results could have specialized methods (error code, stack trace)
 * 
 * Arguments AGAINST (why current approach is acceptable):
 * 1. Simplicity: One QueryResult class is easier to understand and use
 * 2. Polymorphism: Client code treats all results uniformly via base class
 * 3. Existing Pattern: `isSuccess()` check is well-established
 * 4. Low Cost: Unused fields in error result have minimal memory impact
 * 
 * Current Implementation Analysis:
 * - Uses MaterializedQueryResult as the carrier (lightweight for errors)
 * - Sets success=false and errMsg
 * - Null columns/tuple are acceptable since nothing will be iterated
 * 
 * If We Were to Implement ErrorQueryResult:
 * ```cpp
 * class ErrorQueryResult : public QueryResult {
 * public:
 *     ErrorQueryResult(const std::string& errMsg, ErrorCode code = ErrorCode::UNKNOWN);
 *     ErrorCode getErrorCode() const;
 *     std::string getStackTrace() const;
 *     bool isError() const override { return true; }
 * private:
 *     ErrorCode errorCode;
 *     std::string stackTrace;
 * };
 * ```
 * 
 * Decision: Keep Current Approach
 * The current implementation works correctly and introduces minimal complexity.
 * A dedicated ErrorQueryResult class would add more code without significant benefit
 * since errors are already easily identified via isSuccess().
 */
std::unique_ptr<QueryResult> QueryResult::getQueryResultWithError(const std::string& errorMessage) {
    auto queryResult = std::make_unique<MaterializedQueryResult>();
    queryResult->success = false;
    queryResult->errMsg = errorMessage;
    queryResult->nextQueryResult = nullptr;
    queryResult->queryResultIterator = QueryResultIterator{queryResult.get()};
    return queryResult;
}

} // namespace main
} // namespace kuzu
