#include "storage/table/version_record_handler.h"

/**
 * P2-116: Version Record Handler - MVCC Rollback Interface
 * 
 * Purpose:
 * Provides the abstract interface for MVCC (Multi-Version Concurrency Control)
 * rollback operations. Enables transaction rollback to undo uncommitted changes
 * without affecting other concurrent transactions.
 * 
 * Architecture:
 * ```
 * VersionRecordHandler (abstract base)
 *   │
 *   └── applyFuncToChunkedGroups()  // Abstract: route to correct storage
 *   │
 *   └── rollbackInsert()            // Concrete: undo insert operation
 * 
 * Concrete Implementations:
 *   ├── NodeTableVersionRecordHandler  // For node tables
 *   └── RelTableVersionRecordHandler   // For relationship tables
 * ```
 * 
 * Rollback Flow:
 * ```
 * 1. Transaction aborts or rolls back
 * 2. Undo buffer iterated for uncommitted changes
 * 3. For each insert record:
 *    a. rollbackInsert() called with nodeGroupIdx, startRow, numRows
 *    b. applyFuncToChunkedGroups() routes to correct storage
 *    c. ChunkedNodeGroup::rollbackInsert() marks rows as invalid
 * 4. Visibility checks exclude rolled-back rows
 * ```
 * 
 * Function Pointer Pattern:
 * ```cpp
 * using version_record_handler_op_t = void (ChunkedNodeGroup::*)(
 *     row_idx_t startRow,
 *     row_idx_t numRows, 
 *     transaction_t commitTS
 * );
 * 
 * // Allows generic application of any member function:
 * applyFuncToChunkedGroups(&ChunkedNodeGroup::rollbackInsert, ...)
 * applyFuncToChunkedGroups(&ChunkedNodeGroup::commitInsert, ...)   // hypothetical
 * applyFuncToChunkedGroups(&ChunkedNodeGroup::commitDelete, ...)   // hypothetical
 * ```
 * 
 * Why Abstract Base Class?
 * - NodeTable and RelTable have different storage layouts
 * - NodeTable: Direct node group access
 * - RelTable: CSR-based relationship storage
 * - Handler routes to correct underlying structure
 * 
 * Undo Buffer Integration:
 * ```
 * Transaction maintains:
 *   undoBuffer: list<UndoRecord>
 *     ├── INSERT_RECORD: {handler, nodeGroupIdx, startRow, numRows}
 *     └── DELETE_RECORD: {handler, nodeGroupIdx, startRow, numRows}
 * 
 * On rollback:
 *   for each INSERT_RECORD:
 *       handler->rollbackInsert(context, nodeGroupIdx, startRow, numRows)
 * ```
 * 
 * Visibility After Rollback:
 * - Rolled-back rows have commitTS set appropriately
 * - isVisible() checks exclude uncommitted rows from other transactions
 * - Committed transactions see consistent snapshot
 * 
 * Performance Characteristics:
 * - Rollback is O(n) where n = number of inserted rows
 * - No disk I/O required (changes only in memory until commit)
 * - Undo records are small (just ranges, not data copies)
 * 
 * Extension for Delete Rollback:
 * Similar pattern could be used for delete rollback:
 * ```cpp
 * void VersionRecordHandler::rollbackDelete(context, nodeGroupIdx, startRow, numRows) {
 *     applyFuncToChunkedGroups(&ChunkedNodeGroup::rollbackDelete, 
 *                              nodeGroupIdx, startRow, numRows, commitTS);
 * }
 * ```
 */

#include "main/client_context.h"
#include "storage/table/chunked_node_group.h"

namespace kuzu::storage {

void VersionRecordHandler::rollbackInsert(main::ClientContext* context,
    common::node_group_idx_t nodeGroupIdx, common::row_idx_t startRow,
    common::row_idx_t numRows) const {
    applyFuncToChunkedGroups(&ChunkedNodeGroup::rollbackInsert, nodeGroupIdx, startRow, numRows,
        transaction::Transaction::Get(*context)->getCommitTS());
}

} // namespace kuzu::storage
