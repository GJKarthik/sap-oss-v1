#include "transaction/transaction_context.h"

/**
 * P3-138: Transaction Context - Per-Client Transaction State
 * 
 * Purpose:
 * Manages transaction state for each client connection. Provides the interface
 * between user-facing transaction commands (BEGIN, COMMIT, ROLLBACK) and the
 * underlying TransactionManager.
 * 
 * Architecture:
 * ```
 * TransactionContext (per ClientContext)
 *   ├── clientContext: ClientContext&   // Owning client
 *   ├── mode: TransactionMode           // AUTO or MANUAL
 *   ├── activeTransaction: Transaction* // Current transaction
 *   └── mtx: mutex                       // Thread safety
 * 
 * Owned by ClientContext → 1:1 relationship
 * ```
 * 
 * Transaction Modes:
 * 
 * | Mode | Description |
 * |------|-------------|
 * | AUTO | Transaction per statement, auto-commit |
 * | MANUAL | User-controlled BEGIN/COMMIT/ROLLBACK |
 * 
 * Lifecycle (MANUAL mode):
 * ```
 * BEGIN READ/WRITE
 *   │
 *   ├── beginReadTransaction()  → READ_ONLY tx
 *   └── beginWriteTransaction() → WRITE tx
 *   │
 * Execute statements...
 *   │
 * COMMIT/ROLLBACK
 *   ├── commit()   → TransactionManager::commit()
 *   └── rollback() → TransactionManager::rollback()
 *   │
 * clearTransaction() → Reset to AUTO mode
 * ```
 * 
 * Lifecycle (AUTO mode):
 * ```
 * Statement arrives
 *   │
 *   └── beginAutoTransaction(readOnlyStatement)
 *         ├── READ_ONLY if readOnlyStatement
 *         └── WRITE if write statement
 *   │
 * Execute statement
 *   │
 * Auto-commit at end
 * ```
 * 
 * Key Operations:
 * 
 * 1. beginReadTransaction():
 *    - Sets mode = MANUAL
 *    - Creates READ_ONLY transaction
 * 
 * 2. beginWriteTransaction():
 *    - Sets mode = MANUAL
 *    - Creates WRITE transaction
 * 
 * 3. beginAutoTransaction(readOnly):
 *    - Used for single-statement queries
 *    - Creates appropriate transaction type
 * 
 * 4. validateManualTransaction(readOnly):
 *    - Ensures write statements in write transactions
 *    - Throws if write in read-only transaction
 * 
 * 5. commit/rollback():
 *    - Delegates to TransactionManager
 *    - Calls clearTransaction() after
 * 
 * Static Access:
 * ```cpp
 * TransactionContext* ctx = TransactionContext::Get(clientContext);
 * ```
 * 
 * Thread Safety:
 * - Mutex protects state transitions
 * - One active transaction per context
 */

#include "common/exception/transaction_manager.h"
#include "main/client_context.h"
#include "main/database.h"
#include "transaction/transaction_manager.h"

using namespace kuzu::common;

namespace kuzu {
namespace transaction {

TransactionContext::TransactionContext(main::ClientContext& clientContext)
    : clientContext{clientContext}, mode{TransactionMode::AUTO}, activeTransaction{nullptr} {}

TransactionContext::~TransactionContext() = default;

void TransactionContext::beginReadTransaction() {
    std::unique_lock lck{mtx};
    mode = TransactionMode::MANUAL;
    beginTransactionInternal(TransactionType::READ_ONLY);
}

void TransactionContext::beginWriteTransaction() {
    std::unique_lock lck{mtx};
    mode = TransactionMode::MANUAL;
    beginTransactionInternal(TransactionType::WRITE);
}

void TransactionContext::beginAutoTransaction(bool readOnlyStatement) {
    // LCOV_EXCL_START
    if (hasActiveTransaction()) {
        throw TransactionManagerException(
            "Cannot start a new transaction while there is an active transaction.");
    }
    // LCOV_EXCL_STOP
    beginTransactionInternal(
        readOnlyStatement ? TransactionType::READ_ONLY : TransactionType::WRITE);
}

void TransactionContext::beginRecoveryTransaction() {
    std::unique_lock lck{mtx};
    mode = TransactionMode::MANUAL;
    beginTransactionInternal(TransactionType::RECOVERY);
}

void TransactionContext::validateManualTransaction(bool readOnlyStatement) const {
    KU_ASSERT(hasActiveTransaction());
    if (activeTransaction->isReadOnly() && !readOnlyStatement) {
        throw TransactionManagerException(
            "Can not execute a write query inside a read-only transaction.");
    }
}

void TransactionContext::commit() {
    if (!hasActiveTransaction()) {
        return;
    }
    clientContext.getDatabase()->getTransactionManager()->commit(clientContext, activeTransaction);
    clearTransaction();
}

void TransactionContext::rollback() {
    if (!hasActiveTransaction()) {
        return;
    }
    clientContext.getDatabase()->getTransactionManager()->rollback(clientContext,
        activeTransaction);
    clearTransaction();
}

void TransactionContext::clearTransaction() {
    activeTransaction = nullptr;
    mode = TransactionMode::AUTO;
}

TransactionContext* TransactionContext::Get(const main::ClientContext& context) {
    return context.transactionContext.get();
}

void TransactionContext::beginTransactionInternal(TransactionType transactionType) {
    KU_ASSERT(!activeTransaction);
    activeTransaction = clientContext.getDatabase()->getTransactionManager()->beginTransaction(
        clientContext, transactionType);
}

} // namespace transaction
} // namespace kuzu
