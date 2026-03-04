#include "processor/operator/simple/import_db.h"

#include "common/exception/runtime.h"
#include "main/client_context.h"
#include "processor/execution_context.h"
#include "storage/buffer_manager/memory_manager.h"
#include "transaction/transaction_context.h"

using namespace kuzu::common;
using namespace kuzu::transaction;
using namespace kuzu::catalog;

namespace kuzu {
namespace processor {

static void validateQueryResult(main::QueryResult* queryResult) {
    auto currentResult = queryResult;
    while (currentResult) {
        if (!currentResult->isSuccess()) {
            throw RuntimeException("Import database failed: " + currentResult->getErrorMessage());
        }
        currentResult = currentResult->getNextQueryResult();
    }
}

/**
 * P2-79: Import DB Transaction Handling - Multi-Statement Limitation
 * 
 * This TODO notes that Import DB needs special transaction handling that should
 * be refactored once multi-statement transactions are supported.
 * 
 * Current Behavior:
 * 1. If user has active transaction, commit it first
 * 2. Execute each statement (DDL + COPY) with auto-transaction
 * 3. Each statement commits independently
 * 
 * Why This Is "Special":
 * - Normal queries run within a single transaction
 * - Import DB runs MULTIPLE transactions (one per statement)
 * - This breaks atomicity: partial import on failure
 * 
 * Current Limitation Impact:
 * | Scenario | What Happens |
 * |----------|--------------|
 * | All succeed | Database imported correctly |
 * | DDL fails | No tables created, error shown |
 * | COPY fails mid-way | Some tables have data, some don't |
 * | Index fails | Tables have data, no indexes |
 * 
 * Why Multi-Statement Transactions Would Help:
 * ```cpp
 * // Ideal implementation:
 * transactionContext->begin();
 * for (auto& stmt : allStatements) {
 *     clientContext->execute(stmt);
 *     if (failed) {
 *         transactionContext->rollback();  // Atomic rollback
 *         return;
 *     }
 * }
 * transactionContext->commit();  // All-or-nothing
 * ```
 * 
 * Current Workaround:
 * - Commit any active user transaction first
 * - Execute statements with auto-commit
 * - On failure: database may be in partial state
 * - User must manually clean up on error
 * 
 * Why This Works In Practice:
 * - Import DB is typically run on empty/new database
 * - Schema creation (DDL) rarely fails if export was valid
 * - COPY failures are usually data issues, not transaction issues
 * 
 * Future Refactor:
 * When multi-DDL/COPY transactions are supported, wrap entire import
 * in single transaction for atomicity.
 */
void ImportDB::executeInternal(ExecutionContext* context) {
    auto clientContext = context->clientContext;
    if (query.empty()) { // Export empty database.
        appendMessage("Imported database successfully.",
            storage::MemoryManager::Get(*clientContext));
        return;
    }
    // Special handling: commit active transaction, execute with auto-transactions
    // See P2-79 comment above for why this is needed
    auto transactionContext = transaction::TransactionContext::Get(*clientContext);
    if (transactionContext->hasActiveTransaction()) {
        transactionContext->commit();
    }
    auto res = clientContext->queryNoLock(query);
    validateQueryResult(res.get());
    if (!indexQuery.empty()) {
        res = clientContext->queryNoLock(indexQuery);
        validateQueryResult(res.get());
    }
    appendMessage("Imported database successfully.", storage::MemoryManager::Get(*clientContext));
}

} // namespace processor
} // namespace kuzu
