#include "storage/table/version_record_handler.h"

/**
 * P3-220: VersionRecordHandler - Extended Implementation Details
 * 
 * Additional Details (see P2-116 for architecture overview)
 * 
 * rollbackInsert() Implementation:
 * ```
 * rollbackInsert(context, nodeGroupIdx, startRow, numRows):
 *   commitTS = Transaction::Get(context).getCommitTS()
 *   applyFuncToChunkedGroups(
 *     &ChunkedNodeGroup::rollbackInsert,
 *     nodeGroupIdx,
 *     startRow,
 *     numRows,
 *     commitTS
 *   )
 * ```
 * 
 * applyFuncToChunkedGroups Pattern:
 * ```
 * // Abstract method - implemented by concrete handlers:
 * 
 * NodeTableVersionRecordHandler:
 *   applyFuncToChunkedGroups(func, nodeGroupIdx, startRow, numRows, commitTS):
 *     nodeGroup = nodeGroupCollection.getGroup(nodeGroupIdx)
 *     (nodeGroup.*func)(startRow, numRows, commitTS)
 * 
 * RelTableVersionRecordHandler:
 *   applyFuncToChunkedGroups(func, nodeGroupIdx, startRow, numRows, commitTS):
 *     csrGroup = relTableData.getCSRGroup(direction, nodeGroupIdx)
 *     (csrGroup.*func)(startRow, numRows, commitTS)
 * ```
 * 
 * Member Function Pointer Type:
 * ```
 * using version_record_handler_op_t = void (ChunkedNodeGroup::*)(
 *     row_idx_t startRow,
 *     row_idx_t numRows,
 *     transaction_t commitTS
 * );
 * 
 * // Enables generic dispatch:
 * &ChunkedNodeGroup::rollbackInsert  // Undo insert
 * &ChunkedNodeGroup::commitInsert    // Finalize insert
 * ```
 * 
 * Transaction Integration:
 * ```
 * Transaction abort sequence:
 *   1. UndoBuffer.rollback()
 *   2. FOR each INSERT_RECORD:
 *        handler->rollbackInsert(ctx, nodeGroupIdx, startRow, numRows)
 *   3. FOR each DELETE_RECORD:
 *        // Similar rollback pattern
 *   4. Local storage cleanup
 *   5. Transaction marked aborted
 * ```
 * 
 * Commit Timestamp Usage:
 * ```
 * commitTS passed to ChunkedNodeGroup functions:
 * - rollbackInsert: Mark version invalid at commitTS
 * - Visibility check: row visible if ts <= queryTS
 * - Garbage collection: Can remove if no tx needs version
 * ```
 * 
 * ====================================
 * 
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
