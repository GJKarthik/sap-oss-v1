#include "main/connection.h"

/**
 * P3-154: Connection - Client Connection Interface
 * 
 * Purpose:
 * Represents a client connection to a Kuzu database. Provides the primary
 * interface for executing queries, preparing statements, and managing
 * session-specific settings.
 * 
 * Architecture:
 * ```
 * Connection
 *   ├── database: Database*           // Parent database
 *   ├── clientContext: ClientContext  // Session state
 *   └── dbLifeCycleManager: shared_ptr // Lifecycle tracking
 * ```
 * 
 * Query Execution Flow:
 * ```
 * conn.query("MATCH (n) RETURN n")
 *   │
 *   ├── 1. Check database not closed
 *   ├── 2. clientContext->query()
 *   │     ├── Parse query
 *   │     ├── Bind/semantic analysis
 *   │     ├── Plan generation
 *   │     ├── Execute plan
 *   │     └── Return QueryResult
 *   └── 3. Set lifecycle manager on result
 * ```
 * 
 * Prepared Statement Flow:
 * ```
 * auto stmt = conn.prepare("MATCH (n) WHERE n.id = $id RETURN n");
 * conn.executeWithParams(stmt, {{"id", Value(42)}});
 *   │
 *   ├── prepare(): Parse + Bind + Plan (cached)
 *   └── executeWithParams(): Execute with parameter substitution
 * ```
 * 
 * Key Methods:
 * | Method | Description |
 * |--------|-------------|
 * | query() | Execute query string, return results |
 * | queryAsArrow() | Execute and return Arrow format |
 * | queryWithID() | Execute with explicit query ID |
 * | prepare() | Prepare a statement for later execution |
 * | executeWithParams() | Execute prepared statement with params |
 * | interrupt() | Cancel running query |
 * | setQueryTimeOut() | Set timeout in milliseconds |
 * | setMaxNumThreadForExec() | Set parallel thread count |
 * 
 * UDF Registration:
 * ```
 * conn.addScalarFunction("my_func", definitions);
 * conn.removeScalarFunction("my_func");
 * ```
 * 
 * Thread Safety:
 * - Connection is NOT thread-safe
 * - Use one Connection per thread
 * - Multiple Connections can share one Database
 * 
 * Lifecycle:
 * - Checks dbLifeCycleManager->isDatabaseClosed before each operation
 * - Destructor prevents transaction rollback if DB already closed
 * 
 * Usage:
 * ```cpp
 * Database db("./mydb");
 * Connection conn(&db);
 * 
 * // Simple query
 * auto result = conn.query("MATCH (n:Person) RETURN n.name");
 * 
 * // Prepared statement with params
 * auto stmt = conn.prepare("MATCH (n) WHERE n.id = $id RETURN n");
 * auto result = conn.executeWithParams(stmt.get(), {{"id", Value(5)}});
 * ```
 */

#include <utility>

#include "common/random_engine.h"

using namespace kuzu::parser;
using namespace kuzu::binder;
using namespace kuzu::common;
using namespace kuzu::planner;
using namespace kuzu::processor;
using namespace kuzu::transaction;

namespace kuzu {
namespace main {

Connection::Connection(Database* database) {
    KU_ASSERT(database != nullptr);
    this->database = database;
    this->dbLifeCycleManager = database->dbLifeCycleManager;
    clientContext = std::make_unique<ClientContext>(database);
}

Connection::~Connection() {
    clientContext->preventTransactionRollbackOnDestruction = dbLifeCycleManager->isDatabaseClosed;
}

void Connection::setMaxNumThreadForExec(uint64_t numThreads) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    clientContext->setMaxNumThreadForExec(numThreads);
}

uint64_t Connection::getMaxNumThreadForExec() {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    return clientContext->getMaxNumThreadForExec();
}

std::unique_ptr<PreparedStatement> Connection::prepare(std::string_view query) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    return clientContext->prepareWithParams(query);
}

std::unique_ptr<PreparedStatement> Connection::prepareWithParams(std::string_view query,
    std::unordered_map<std::string, std::unique_ptr<common::Value>> inputParams) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    return clientContext->prepareWithParams(query, std::move(inputParams));
}

std::unique_ptr<QueryResult> Connection::query(std::string_view queryStatement) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    auto queryResult = clientContext->query(queryStatement);
    queryResult->setDBLifeCycleManager(dbLifeCycleManager);
    return queryResult;
}

std::unique_ptr<QueryResult> Connection::queryAsArrow(std::string_view query, int64_t chunkSize) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    auto queryResult = clientContext->query(query, std::nullopt,
        {QueryResultType::ARROW, ArrowResultConfig{chunkSize}});
    queryResult->setDBLifeCycleManager(dbLifeCycleManager);
    return queryResult;
}

std::unique_ptr<QueryResult> Connection::queryWithID(std::string_view queryStatement,
    uint64_t queryID) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    auto queryResult = clientContext->query(queryStatement, queryID);
    queryResult->setDBLifeCycleManager(dbLifeCycleManager);
    return queryResult;
}

void Connection::interrupt() {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    clientContext->interrupt();
}

void Connection::setQueryTimeOut(uint64_t timeoutInMS) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    clientContext->setQueryTimeOut(timeoutInMS);
}

std::unique_ptr<QueryResult> Connection::executeWithParams(PreparedStatement* preparedStatement,
    std::unordered_map<std::string, std::unique_ptr<Value>> inputParams) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    auto queryResult = clientContext->executeWithParams(preparedStatement, std::move(inputParams));
    queryResult->setDBLifeCycleManager(dbLifeCycleManager);
    return queryResult;
}

std::unique_ptr<QueryResult> Connection::executeWithParamsWithID(
    PreparedStatement* preparedStatement,
    std::unordered_map<std::string, std::unique_ptr<Value>> inputParams, uint64_t queryID) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    auto queryResult =
        clientContext->executeWithParams(preparedStatement, std::move(inputParams), queryID);
    queryResult->setDBLifeCycleManager(dbLifeCycleManager);
    return queryResult;
}

void Connection::addScalarFunction(std::string name, function::function_set definitions) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    clientContext->addScalarFunction(name, std::move(definitions));
}

void Connection::removeScalarFunction(std::string name) {
    dbLifeCycleManager->checkDatabaseClosedOrThrow();
    clientContext->removeScalarFunction(name);
}

} // namespace main
} // namespace kuzu
