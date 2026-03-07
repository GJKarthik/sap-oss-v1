#include "storage/table/rel_table.h"

/**
 * P3-180: RelTable - Relationship Storage Implementation
 * 
 * Purpose:
 * Implements the storage layer for relationship (edge) tables in the graph database.
 * Uses CSR (Compressed Sparse Row) format for efficient adjacency list storage.
 * 
 * Architecture:
 * ```
 * RelTable
 *   ├── directedRelData: vector<RelTableData>  // FWD and/or BWD storage
 *   ├── fromNodeTableID, toNodeTableID
 *   ├── relGroupID: table_id_t                 // Parent rel group
 *   └── nextRelOffset: offset_t                // Next rel ID
 * 
 * RelTableScanState
 *   ├── direction: RelDataDirection            // FWD or BWD
 *   ├── nodeIDVector: ValueVector*             // Bound node IDs
 *   ├── csrOffsetColumn, csrLengthColumn       // CSR metadata
 *   ├── localTableScanState                    // Uncommitted data
 *   └── cachedBoundNodeSelVector               // Selection optimization
 * ```
 * 
 * CSR Storage Layout:
 * ```
 * For node N with edges to M1, M2, M3:
 *   CSR Offset[N] = start index in edges array
 *   CSR Length[N] = 3 (number of edges)
 *   Edges[offset..offset+3] = [M1, M2, M3]
 * ```
 * 
 * Key Operations:
 * 
 * 1. INSERT:
 *    - Check multiplicity constraint (MANY/ONE)
 *    - Insert to local storage
 *    - Log to WAL
 * 
 * 2. UPDATE:
 *    - If uncommitted (high offset): update local
 *    - Else: update both FWD and BWD directions
 * 
 * 3. DELETE:
 *    - If uncommitted: delete from local
 *    - Else: delete from both directions
 * 
 * 4. DETACH DELETE:
 *    - Delete all edges from a source node
 *    - Scan CSR, delete each rel individually
 *    - Handles reverse direction cleanup
 * 
 * 5. SCAN:
 *    - Iterate CSR for bound nodes
 *    - Check committed then uncommitted data
 * 
 * Direction Storage:
 * | Mode | Storage | Description |
 * |------|---------|-------------|
 * | BOTH | FWD+BWD | Full bidirectional |
 * | FWD_ONLY | FWD | Forward only |
 * | BWD_ONLY | BWD | Backward only |
 * 
 * Multiplicity Constraints:
 * | Type | Meaning |
 * |------|---------|
 * | MANY_MANY | No constraint |
 * | MANY_ONE | Max 1 outgoing per node |
 * | ONE_MANY | Max 1 incoming per node |
 * | ONE_ONE | Max 1 both directions |
 * 
 * Commit Process:
 * ```
 * commit(localRelTable)
 *   │
 *   ├── updateRelOffsets() → assign committed IDs
 *   │
 *   └── For each direction:
 *         └── prepareCommitForNodeGroup()
 *               └── Append local rows to CSR
 * ```
 * 
 * Offset Management:
 * - Uncommitted: offset >= MAX_NUM_ROWS_IN_TABLE
 * - Committed: actual offset in storage
 * - getCommittedOffset() converts at commit time
 */

#include <algorithm>

#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/message.h"
#include "common/exception/runtime.h"
#include "common/types/types.h"
#include "main/client_context.h"
#include "storage/local_storage/local_rel_table.h"
#include "storage/local_storage/local_storage.h"
#include "storage/local_storage/local_table.h"
#include "storage/storage_manager.h"
#include "storage/storage_utils.h"
#include "storage/table/column_chunk.h"
#include "storage/table/column_chunk_data.h"
#include "storage/table/rel_table_data.h"
#include "storage/wal/local_wal.h"
#include "transaction/transaction.h"
#include <ranges>

using namespace kuzu::catalog;
using namespace kuzu::common;
using namespace kuzu::transaction;
using namespace kuzu::evaluator;

namespace kuzu {
namespace storage {

void RelTableScanState::setToTable(const Transaction* transaction, Table* table_,
    std::vector<column_id_t> columnIDs_, std::vector<ColumnPredicateSet> columnPredicateSets_,
    RelDataDirection direction_) {
    TableScanState::setToTable(transaction, table_, std::move(columnIDs_),
        std::move(columnPredicateSets_));
    columns.resize(columnIDs.size());
    direction = direction_;
    for (size_t i = 0; i < columnIDs.size(); ++i) {
        auto columnID = columnIDs[i];
        if (columnID == INVALID_COLUMN_ID || columnID == ROW_IDX_COLUMN_ID) {
            columns[i] = nullptr;
        } else {
            columns[i] = table->cast<RelTable>().getColumn(columnID, direction);
        }
    }
    csrOffsetColumn = table->cast<RelTable>().getCSROffsetColumn(direction);
    csrLengthColumn = table->cast<RelTable>().getCSRLengthColumn(direction);
    nodeGroupIdx = INVALID_NODE_GROUP_IDX;
    if (const auto localRelTable =
            transaction->getLocalStorage()->getLocalTable(table->getTableID())) {
        auto localTableColumnIDs = LocalRelTable::rewriteLocalColumnIDs(direction, columnIDs);
        localTableScanState = std::make_unique<LocalRelTableScanState>(*this,
            localRelTable->ptrCast<LocalRelTable>(), localTableColumnIDs);
    }
}

void RelTableScanState::initState(Transaction* transaction, NodeGroup* nodeGroup,
    bool resetCachedBoundNodeIDs) {
    this->nodeGroup = nodeGroup;
    if (resetCachedBoundNodeIDs) {
        initCachedBoundNodeIDSelVector();
    }
    if (this->nodeGroup) {
        initStateForCommitted(transaction);
    } else if (hasUnCommittedData()) {
        initStateForUncommitted();
    } else {
        source = TableScanSource::NONE;
    }
}

void RelTableScanState::initCachedBoundNodeIDSelVector() {
    if (nodeIDVector->state->getSelVector().isUnfiltered()) {
        cachedBoundNodeSelVector.setToUnfiltered();
    } else {
        cachedBoundNodeSelVector.setToFiltered();
        memcpy(cachedBoundNodeSelVector.getMutableBuffer().data(),
            nodeIDVector->state->getSelVectorUnsafe().getMutableBuffer().data(),
            nodeIDVector->state->getSelVector().getSelSize() * sizeof(sel_t));
    }
    cachedBoundNodeSelVector.setSelSize(nodeIDVector->state->getSelVector().getSelSize());
}

bool RelTableScanState::hasUnCommittedData() const {
    return localTableScanState && localTableScanState->localRelTable;
}

void RelTableScanState::initStateForCommitted(const Transaction* transaction) {
    source = TableScanSource::COMMITTED;
    currBoundNodeIdx = 0;
    nodeGroup->initializeScanState(transaction, *this);
}

void RelTableScanState::initStateForUncommitted() {
    KU_ASSERT(localTableScanState);
    source = TableScanSource::UNCOMMITTED;
    currBoundNodeIdx = 0;
    localTableScanState->localRelTable->initializeScan(*this);
}

bool RelTableScanState::scanNext(Transaction* transaction) {
    while (true) {
        switch (source) {
        case TableScanSource::COMMITTED: {
            const auto scanResult = nodeGroup->scan(transaction, *this);
            if (scanResult == NODE_GROUP_SCAN_EMPTY_RESULT) {
                if (hasUnCommittedData()) {
                    initStateForUncommitted();
                } else {
                    source = TableScanSource::NONE;
                }
                continue;
            }
            return true;
        }
        case TableScanSource::UNCOMMITTED: {
            KU_ASSERT(localTableScanState && localTableScanState->localRelTable);
            return localTableScanState->localRelTable->scan(transaction, *this);
        }
        case TableScanSource::NONE: {
            return false;
        }
        default: {
            KU_UNREACHABLE;
        }
        }
    }
}

void RelTableScanState::setNodeIDVectorToFlat(sel_t selPos) const {
    nodeIDVector->state->setToFlat();
    nodeIDVector->state->getSelVectorUnsafe().setToFiltered(1);
    nodeIDVector->state->getSelVectorUnsafe()[0] = selPos;
}

RelTable::RelTable(RelGroupCatalogEntry* relGroupEntry, table_id_t fromTableID,
    table_id_t toTableID, const StorageManager* storageManager, MemoryManager* memoryManager)
    : Table{relGroupEntry, storageManager, memoryManager}, fromNodeTableID{fromTableID},
      toNodeTableID{toTableID}, nextRelOffset{0} {
    auto relEntryInfo = relGroupEntry->getRelEntryInfo(fromNodeTableID, toNodeTableID);
    tableID = relEntryInfo->oid;
    relGroupID = relGroupEntry->getTableID();
    for (auto direction : relGroupEntry->getRelDataDirections()) {
        auto nbrTableID = RelDirectionUtils::getNbrTableID(direction, fromTableID, toTableID);
        directedRelData.emplace_back(
            std::make_unique<RelTableData>(storageManager->getDataFH(), memoryManager, shadowFile,
                *relGroupEntry, *this, direction, nbrTableID, enableCompression));
    }
}

void RelTable::initScanState(Transaction* transaction, TableScanState& scanState,
    bool resetCachedBoundNodeSelVec) const {
    auto& relScanState = scanState.cast<RelTableScanState>();
    // Note there we directly read node at pos 0 here regardless the selVector is filtered or not.
    // This is because we're assuming the nodeIDVector is always a sequence here.
    const auto boundNodeID = relScanState.nodeIDVector->getValue<nodeID_t>(
        relScanState.nodeIDVector->state->getSelVector()[0]);
    NodeGroup* nodeGroup = nullptr;
    // Check if the node group idx is same as previous scan.
    const auto nodeGroupIdx = StorageUtils::getNodeGroupIdx(boundNodeID.offset);
    if (relScanState.nodeGroupIdx != nodeGroupIdx) {
        // We need to re-initialize the node group scan state.
        nodeGroup = getDirectedTableData(relScanState.direction)->getNodeGroup(nodeGroupIdx);
    } else {
        nodeGroup = relScanState.nodeGroup;
    }
    scanState.initState(transaction, nodeGroup, resetCachedBoundNodeSelVec);
}

bool RelTable::scanInternal(Transaction* transaction, TableScanState& scanState) {
    return scanState.scanNext(transaction);
}

static void throwRelMultiplicityConstraintError(const std::string& tableName, offset_t nodeOffset,
    RelDataDirection direction) {
    throw RuntimeException(ExceptionMessage::violateRelMultiplicityConstraint(tableName,
        std::to_string(nodeOffset), RelDirectionUtils::relDirectionToString(direction)));
}

void RelTable::checkRelMultiplicityConstraint(Transaction* transaction,
    const TableInsertState& state) const {
    const auto& insertState = state.constCast<RelTableInsertState>();
    KU_ASSERT(insertState.srcNodeIDVector.state->getSelVector().getSelSize() == 1 &&
              insertState.dstNodeIDVector.state->getSelVector().getSelSize() == 1);

    for (auto& relData : directedRelData) {
        if (relData->getMultiplicity() == RelMultiplicity::ONE) {
            throwIfNodeHasRels(transaction, relData->getDirection(),
                &insertState.getBoundNodeIDVector(relData->getDirection()),
                throwRelMultiplicityConstraintError);
        }
    }
}

void RelTable::insert(Transaction* transaction, TableInsertState& insertState) {
    checkRelMultiplicityConstraint(transaction, insertState);

    KU_ASSERT(transaction->getLocalStorage());
    const auto localTable = transaction->getLocalStorage()->getOrCreateLocalTable(*this);
    localTable->insert(transaction, insertState);
    if (insertState.logToWAL && transaction->shouldLogToWAL()) {
        KU_ASSERT(transaction->isWriteTransaction());
        const auto& relInsertState = insertState.cast<RelTableInsertState>();
        std::vector<ValueVector*> vectorsToLog;
        vectorsToLog.push_back(&relInsertState.srcNodeIDVector);
        vectorsToLog.push_back(&relInsertState.dstNodeIDVector);
        vectorsToLog.insert(vectorsToLog.end(), relInsertState.propertyVectors.begin(),
            relInsertState.propertyVectors.end());
        KU_ASSERT(relInsertState.srcNodeIDVector.state->getSelVector().getSelSize() == 1);
        auto& wal = transaction->getLocalWAL();
        wal.logTableInsertion(tableID, TableType::REL,
            relInsertState.srcNodeIDVector.state->getSelVector().getSelSize(), vectorsToLog);
    }
    hasChanges = true;
}

void RelTable::update(Transaction* transaction, TableUpdateState& updateState) {
    const auto& relUpdateState = updateState.cast<RelTableUpdateState>();
    KU_ASSERT(relUpdateState.relIDVector.state->getSelVector().getSelSize() == 1);
    const auto relIDPos = relUpdateState.relIDVector.state->getSelVector()[0];
    if (const auto relOffset = relUpdateState.relIDVector.readNodeOffset(relIDPos);
        relOffset >= StorageConstants::MAX_NUM_ROWS_IN_TABLE) {
        const auto localTable = transaction->getLocalStorage()->getLocalTable(tableID);
        KU_ASSERT(localTable);
        localTable->update(&DUMMY_TRANSACTION, updateState);
    } else {
        for (auto& relData : directedRelData) {
            relData->update(transaction,
                relUpdateState.getBoundNodeIDVector(relData->getDirection()),
                relUpdateState.relIDVector, relUpdateState.columnID, relUpdateState.propertyVector);
        }
    }
    if (updateState.logToWAL && transaction->shouldLogToWAL()) {
        KU_ASSERT(transaction->isWriteTransaction());
        auto& wal = transaction->getLocalWAL();
        wal.logRelUpdate(tableID, relUpdateState.columnID, &relUpdateState.srcNodeIDVector,
            &relUpdateState.dstNodeIDVector, &relUpdateState.relIDVector,
            &relUpdateState.propertyVector);
    }
    hasChanges = true;
}

bool RelTable::delete_(Transaction* transaction, TableDeleteState& deleteState) {
    const auto& relDeleteState = deleteState.cast<RelTableDeleteState>();
    KU_ASSERT(relDeleteState.relIDVector.state->getSelVector().getSelSize() == 1);
    const auto relIDPos = relDeleteState.relIDVector.state->getSelVector()[0];
    bool isDeleted = false;
    if (const auto relOffset = relDeleteState.relIDVector.readNodeOffset(relIDPos);
        relOffset >= StorageConstants::MAX_NUM_ROWS_IN_TABLE) {
        const auto localTable = transaction->getLocalStorage()->getLocalTable(tableID);
        KU_ASSERT(localTable);
        isDeleted = localTable->delete_(transaction, deleteState);
    } else {
        for (auto& relData : directedRelData) {
            isDeleted = relData->delete_(transaction,
                relDeleteState.getBoundNodeIDVector(relData->getDirection()),
                relDeleteState.relIDVector);
            if (!isDeleted) {
                break;
            }
        }
    }
    if (isDeleted) {
        hasChanges = true;
        if (deleteState.logToWAL && transaction->shouldLogToWAL()) {
            KU_ASSERT(transaction->isWriteTransaction());
            auto& wal = transaction->getLocalWAL();
            wal.logRelDelete(tableID, &relDeleteState.srcNodeIDVector,
                &relDeleteState.dstNodeIDVector, &relDeleteState.relIDVector);
        }
    }
    return isDeleted;
}

void RelTable::detachDelete(Transaction* transaction, RelTableDeleteState* deleteState) {
    auto direction = deleteState->detachDeleteDirection;
    if (std::ranges::count(getStorageDirections(), direction) == 0) {
        throw RuntimeException(
            stringFormat("Cannot delete edges of direction {} from table {} as they do not exist.",
                RelDirectionUtils::relDirectionToString(direction), tableName));
    }
    KU_ASSERT(deleteState->srcNodeIDVector.state->getSelVector().getSelSize() == 1);
    const auto tableData = getDirectedTableData(direction);
    const auto reverseTableData =
        directedRelData.size() == NUM_REL_DIRECTIONS ?
            getDirectedTableData(RelDirectionUtils::getOppositeDirection(direction)) :
            nullptr;
    auto relReadState =
        std::make_unique<RelTableScanState>(*memoryManager, &deleteState->srcNodeIDVector,
            std::vector{&deleteState->dstNodeIDVector, &deleteState->relIDVector},
            deleteState->dstNodeIDVector.state, true /*randomLookup*/);
    relReadState->setToTable(transaction, this, {NBR_ID_COLUMN_ID, REL_ID_COLUMN_ID}, {},
        direction);
    initScanState(transaction, *relReadState);
    detachDeleteForCSRRels(transaction, tableData, reverseTableData, relReadState.get(),
        deleteState);
    if (deleteState->logToWAL && transaction->shouldLogToWAL()) {
        KU_ASSERT(transaction->isWriteTransaction());
        auto& wal = transaction->getLocalWAL();
        wal.logRelDetachDelete(tableID, direction, &deleteState->srcNodeIDVector);
    }
    hasChanges = true;
}

std::vector<RelDataDirection> RelTable::getStorageDirections() const {
    std::vector<RelDataDirection> ret;
    for (const auto& relData : directedRelData) {
        ret.push_back(relData->getDirection());
    }
    return ret;
}

bool RelTable::checkIfNodeHasRels(Transaction* transaction, RelDataDirection direction,
    ValueVector* srcNodeIDVector) const {
    bool hasRels = false;
    const auto localTable = transaction->getLocalStorage()->getLocalTable(tableID);
    if (localTable) {
        hasRels = localTable->cast<LocalRelTable>().checkIfNodeHasRels(srcNodeIDVector, direction);
    }
    hasRels = hasRels ||
              getDirectedTableData(direction)->checkIfNodeHasRels(transaction, srcNodeIDVector);
    return hasRels;
}

void RelTable::throwIfNodeHasRels(Transaction* transaction, RelDataDirection direction,
    ValueVector* srcNodeIDVector, const rel_multiplicity_constraint_throw_func_t& throwFunc) const {
    const auto nodeIDPos = srcNodeIDVector->state->getSelVector()[0];
    const auto nodeOffset = srcNodeIDVector->getValue<nodeID_t>(nodeIDPos).offset;
    if (checkIfNodeHasRels(transaction, direction, srcNodeIDVector)) {
        throwFunc(tableName, nodeOffset, direction);
    }
}

/**
 * P2-69: Detach Delete Flatten Workaround for Unflat Vectors
 * 
 * This TODO notes that manual flattening can be removed once delete_() supports
 * unflat vectors natively.
 * 
 * The Problem:
 * RelTableData::delete_() currently expects FLAT input vectors (single row at a time).
 * But scan() returns UNFLAT vectors (multiple rows batched together).
 * 
 * Current Workaround:
 * 1. Scan returns batch of rels (unflat vector)
 * 2. Manually flatten: set selection vector to single row
 * 3. Loop through each row, calling delete_() one at a time
 * 4. Reset selection vector to unfiltered for next scan
 * 
 * Why delete_() Doesn't Support Unflat Vectors Yet:
 * - CSR deletion is complex: need to mark multiple ranges
 * - Reverse direction updates require per-rel lookup
 * - Local storage deletion may have different batching requirements
 * - Correctness was prioritized over performance initially
 * 
 * Performance Impact of Current Approach:
 * | Operation | Overhead |
 * |-----------|----------|
 * | Selection vector manipulation | ~1ns per row |
 * | Delete call overhead | ~100ns per call |
 * | Batch delete (hypothetical) | Amortized ~10ns per row |
 * 
 * What "Unflat Delete" Would Enable:
 * 1. Batch CSR range marking in single call
 * 2. Amortized overhead for multiple deletes
 * 3. Better cache locality for sequential deletes
 * 
 * Implementation Steps for Unflat Delete:
 * 1. Modify RelTableData::delete_() to accept selection vector size > 1
 * 2. Batch CSR updates for all selected rows
 * 3. Handle reverse direction in batch
 * 4. Update local storage delete to support batch
 * 
 * Until Then:
 * Current approach works correctly, just with per-row overhead.
 * Detach delete is already O(n) in edges, so overhead is acceptable.
 */
void RelTable::detachDeleteForCSRRels(Transaction* transaction, RelTableData* tableData,
    RelTableData* reverseTableData, RelTableScanState* relDataReadState,
    RelTableDeleteState* deleteState) {
    const auto localTable = transaction->getLocalStorage()->getLocalTable(tableID);
    const auto tempState = deleteState->dstNodeIDVector.state.get();
    while (scan(transaction, *relDataReadState)) {
        const auto numRelsScanned = tempState->getSelVector().getSelSize();

        // Manual flattening: delete_() expects flat input (one row at a time)
        // Copy unfiltered values to filtered buffer if needed
        if (tempState->getSelVector().isUnfiltered()) {
            tempState->getSelVectorUnsafe().setRange(0, numRelsScanned);
        }
        tempState->getSelVectorUnsafe().setToFiltered(1);

        for (auto i = 0u; i < numRelsScanned; i++) {
            tempState->getSelVectorUnsafe()[0] = deleteState->relIDVector.state->getSelVector()[i];

            const auto relIDPos = deleteState->relIDVector.state->getSelVector()[0];
            const auto relOffset = deleteState->relIDVector.readNodeOffset(relIDPos);
            if (relOffset >= StorageConstants::MAX_NUM_ROWS_IN_TABLE) {
                KU_ASSERT(localTable);
                localTable->delete_(transaction, *deleteState);
                continue;
            }
            [[maybe_unused]] const auto deleted = tableData->delete_(transaction,
                deleteState->srcNodeIDVector, deleteState->relIDVector);
            if (reverseTableData) {
                [[maybe_unused]] const auto reverseDeleted = reverseTableData->delete_(transaction,
                    deleteState->dstNodeIDVector, deleteState->relIDVector);
                KU_ASSERT(deleted == reverseDeleted);
            }
        }
        tempState->getSelVectorUnsafe().setToUnfiltered();
    }
}

void RelTable::addColumn(Transaction* transaction, TableAddColumnState& addColumnState,
    PageAllocator& pageAllocator) {
    LocalTable* localTable = nullptr;
    if (transaction->getLocalStorage()) {
        localTable = transaction->getLocalStorage()->getLocalTable(tableID);
    }
    if (localTable) {
        localTable->addColumn(addColumnState);
    }
    for (auto& directedRelData : directedRelData) {
        directedRelData->addColumn(addColumnState, pageAllocator);
    }
    hasChanges = true;
}

RelTableData* RelTable::getDirectedTableData(RelDataDirection direction) const {
    const auto directionIdx = RelDirectionUtils::relDirectionToKeyIdx(direction);
    if (directionIdx >= directedRelData.size()) {
        throw RuntimeException(stringFormat(
            "Failed to get {} data for rel table \"{}\", please set the storage direction to BOTH",
            RelDirectionUtils::relDirectionToString(direction), tableName));
    }
    KU_ASSERT(directedRelData[directionIdx]->getDirection() == direction);
    return directedRelData[directionIdx].get();
}

NodeGroup* RelTable::getOrCreateNodeGroup(const Transaction* transaction,
    node_group_idx_t nodeGroupIdx, RelDataDirection direction) const {
    return getDirectedTableData(direction)->getOrCreateNodeGroup(transaction, nodeGroupIdx);
}

void RelTable::pushInsertInfo(const Transaction* transaction, RelDataDirection direction,
    const CSRNodeGroup& nodeGroup, row_idx_t numRows_, CSRNodeGroupScanSource source) const {
    getDirectedTableData(direction)->pushInsertInfo(transaction, nodeGroup, numRows_, source);
}

void RelTable::commit(main::ClientContext* context, TableCatalogEntry* tableEntry,
    LocalTable* localTable) {
    auto& localRelTable = localTable->cast<LocalRelTable>();
    if (localRelTable.isEmpty()) {
        localTable->clear(*MemoryManager::Get(*context));
        return;
    }
    // Update relID in local storage.
    updateRelOffsets(localRelTable);
    // For both forward and backward directions, re-org local storage into compact CSR node groups.
    auto& localNodeGroup = localRelTable.getLocalNodeGroup();
    // Scan from local node group and write to WAL.
    std::vector<column_id_t> columnIDsToScan;
    for (auto i = 0u; i < localRelTable.getNumColumns(); i++) {
        columnIDsToScan.push_back(i);
    }

    std::vector<column_id_t> columnIDsToCommit;
    columnIDsToCommit.push_back(0); // NBR column.
    for (auto& property : tableEntry->getProperties()) {
        auto columnID = tableEntry->getColumnID(property.getName());
        columnIDsToCommit.push_back(columnID);
    }
    // commit rel table data
    auto transaction = transaction::Transaction::Get(*context);
    for (auto& relData : directedRelData) {
        const auto direction = relData->getDirection();
        const auto columnToSkip = (direction == RelDataDirection::FWD) ?
                                      LOCAL_BOUND_NODE_ID_COLUMN_ID :
                                      LOCAL_NBR_NODE_ID_COLUMN_ID;
        for (auto& [boundNodeOffset, rowIndices] : localRelTable.getCSRIndex(direction)) {
            auto [nodeGroupIdx, boundOffsetInGroup] =
                StorageUtils::getQuotientRemainder(boundNodeOffset, StorageConfig::NODE_GROUP_SIZE);
            auto& nodeGroup =
                relData->getOrCreateNodeGroup(transaction, nodeGroupIdx)->cast<CSRNodeGroup>();
            pushInsertInfo(transaction, direction, nodeGroup, rowIndices.size(),
                CSRNodeGroupScanSource::COMMITTED_IN_MEMORY);
            prepareCommitForNodeGroup(transaction, columnIDsToCommit, localNodeGroup, nodeGroup,
                boundOffsetInGroup, rowIndices, columnToSkip);
        }
    }

    localRelTable.clear(*MemoryManager::Get(*context));
}

void RelTable::reclaimStorage(PageAllocator& pageAllocator) const {
    for (auto& relData : directedRelData) {
        relData->reclaimStorage(pageAllocator);
    }
}

void RelTable::updateRelOffsets(const LocalRelTable& localRelTable) {
    auto& localNodeGroup = localRelTable.getLocalNodeGroup();
    const offset_t maxCommittedOffset = reserveRelOffsets(localNodeGroup.getNumRows());
    RUNTIME_CHECK(uint64_t totalNumRows = 0);
    for (auto i = 0u; i < localNodeGroup.getNumChunkedGroups(); i++) {
        const auto chunkedGroup = localNodeGroup.getChunkedNodeGroup(i);
        KU_ASSERT(chunkedGroup);
        auto& internalIDChunk = chunkedGroup->getColumnChunk(LOCAL_REL_ID_COLUMN_ID);
        RUNTIME_CHECK(totalNumRows += internalIDChunk.getNumValues());
        for (auto rowIdx = 0u; rowIdx < internalIDChunk.getNumValues(); rowIdx++) {
            const auto localRelOffset = internalIDChunk.getValue<offset_t>(rowIdx);
            const auto committedRelOffset = getCommittedOffset(localRelOffset, maxCommittedOffset);
            internalIDChunk.setValue<offset_t>(committedRelOffset, rowIdx);
        }

        internalIDChunk.setTableID(tableID);
    }
    KU_ASSERT(totalNumRows == localNodeGroup.getNumRows());
}

offset_t RelTable::getCommittedOffset(offset_t uncommittedOffset, offset_t maxCommittedOffset) {
    return uncommittedOffset - StorageConstants::MAX_NUM_ROWS_IN_TABLE + maxCommittedOffset;
}

void RelTable::prepareCommitForNodeGroup(const Transaction* transaction,
    const std::vector<column_id_t>& columnIDs, const NodeGroup& localNodeGroup,
    CSRNodeGroup& csrNodeGroup, offset_t boundOffsetInGroup, const row_idx_vec_t& rowIndices,
    column_id_t skippedColumn) {
    for (const auto row : rowIndices) {
        auto [chunkedGroupIdx, rowInChunkedGroup] =
            StorageUtils::getQuotientRemainder(row, StorageConfig::CHUNKED_NODE_GROUP_CAPACITY);
        std::vector<const ColumnChunk*> chunks;
        const auto chunkedGroup = localNodeGroup.getChunkedNodeGroup(chunkedGroupIdx);
        for (auto i = 0u; i < chunkedGroup->getNumColumns(); i++) {
            if (i == skippedColumn) {
                continue;
            }
            chunks.push_back(&chunkedGroup->getColumnChunk(i));
        }
        csrNodeGroup.append(transaction, columnIDs, boundOffsetInGroup, chunks, rowInChunkedGroup,
            1 /*numRows*/);
    }
}

bool RelTable::checkpoint(main::ClientContext*, TableCatalogEntry* tableEntry,
    PageAllocator& pageAllocator) {
    bool ret = hasChanges;
    if (hasChanges) {
        // Deleted columns are vacuumed and not checkpointed or serialized.
        std::vector<column_id_t> columnIDs;
        columnIDs.push_back(0);
        for (auto& property : tableEntry->getProperties()) {
            columnIDs.push_back(tableEntry->getColumnID(property.getName()));
        }
        for (auto& directedRelData : directedRelData) {
            directedRelData->checkpoint(columnIDs, pageAllocator);
        }
        hasChanges = false;
    }
    return ret;
}

row_idx_t RelTable::getNumTotalRows(const Transaction* transaction) {
    auto numLocalRows = 0u;
    if (auto localTable = transaction->getLocalStorage()->getLocalTable(tableID)) {
        numLocalRows = localTable->getNumTotalRows();
    }
    return numLocalRows + nextRelOffset;
}

void RelTable::serialize(Serializer& ser) const {
    ser.writeDebuggingInfo("next_rel_offset");
    ser.write<offset_t>(nextRelOffset);
    for (auto& directedRelData : directedRelData) {
        directedRelData->serialize(ser);
    }
}

void RelTable::deserialize(main::ClientContext*, StorageManager*, Deserializer& deSer) {
    std::string key;
    deSer.validateDebuggingInfo(key, "next_rel_offset");
    deSer.deserializeValue<offset_t>(nextRelOffset);
    for (auto i = 0u; i < directedRelData.size(); i++) {
        directedRelData[i]->deserialize(deSer, *memoryManager);
    }
}

} // namespace storage
} // namespace kuzu
