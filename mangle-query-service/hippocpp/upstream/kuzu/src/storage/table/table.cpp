#include "storage/table/table.h"

/**
 * P3-219: Table - Extended Implementation Details
 * 
 * Additional Details (see P2-115 for architecture overview)
 * 
 * TableScanState Methods:
 * ```
 * resetOutVectors():
 *   FOR each outputVector:
 *     outputVector.resetAuxiliaryBuffer()  // Clear string/list buffers
 *   outState.selVector.setToUnfiltered()   // Reset selection
 * 
 * setToTable(tx, table, columnIDs, predicates, direction):
 *   this.table = table
 *   this.columnIDs = columnIDs
 *   this.columnPredicateSets = predicates
 *   nodeGroupScanState.chunkStates.resize(columnIDs.size())
 * ```
 * 
 * State Object Constructors:
 * ```
 * TableInsertState(propertyVectors):
 *   this.propertyVectors = propertyVectors
 *   this.logToWAL = true  // Default: durable
 * 
 * TableUpdateState(columnID, propertyVector):
 *   this.columnID = columnID
 *   this.propertyVector = propertyVector
 *   this.logToWAL = true
 * 
 * TableDeleteState():
 *   this.logToWAL = true
 * ```
 * 
 * Table Constructor:
 * ```
 * Table(tableEntry, storageManager, memoryManager):
 *   tableType = tableEntry.getTableType()
 *   tableID = tableEntry.getTableID()
 *   tableName = tableEntry.getName()
 *   enableCompression = storageManager.compressionEnabled()
 *   memoryManager = memoryManager
 *   shadowFile = &storageManager.getShadowFile()
 *   hasChanges = false  // No dirty data yet
 * ```
 * 
 * scan() Pattern:
 * ```
 * scan(transaction, scanState):
 *   RETURN scanInternal(transaction, scanState)  // Template method
 * 
 * // scanInternal is pure virtual - implemented by:
 * // - NodeTable::scanInternal
 * // - RelTable::scanInternal
 * ```
 * 
 * constructDataChunk() Utility:
 * ```
 * constructDataChunk(mm, types):
 *   chunk = DataChunk(types.size())
 *   FOR i in 0..types.size():
 *     vector = new ValueVector(types[i], mm)
 *     chunk.insert(i, vector)
 *   RETURN chunk
 * ```
 * 
 * ====================================
 * 
 * P2-115: Base Table Class - Abstract Storage Interface
 * 
 * Purpose:
 * Defines the abstract base class and state objects for all table types
 * in the storage layer. Provides common infrastructure for NodeTable
 * and RelTable implementations.
 * 
 * Class Hierarchy:
 * ```
 * Table (abstract base)
 *   ├── NodeTable      // Vertex storage
 *   └── RelTable       // Edge storage
 * 
 * TableScanState (base scan state)
 *   ├── NodeTableScanState
 *   └── RelTableScanState
 * 
 * TableInsertState / TableUpdateState / TableDeleteState
 *   ├── NodeTable variants
 *   └── RelTable variants
 * ```
 * 
 * Table Base Class Members:
 * ```
 * Table
 *   ├── tableType: TableType       // NODE or REL
 *   ├── tableID: table_id_t        // Unique identifier
 *   ├── tableName: string          // Human-readable name
 *   ├── enableCompression: bool    // Storage compression flag
 *   ├── memoryManager: MemoryManager*
 *   ├── shadowFile: ShadowFile*    // Write-ahead logging
 *   └── hasChanges: bool           // Dirty flag for checkpoint
 * ```
 * 
 * TableScanState:
 * - outputVectors: Target vectors for scan results
 * - outState: Shared state for output vectors
 * - table: Reference to table being scanned
 * - columnIDs: Which columns to scan
 * - columnPredicateSets: Filter predicates per column
 * - nodeGroupScanState: Current node group scan position
 * 
 * Key Abstract Methods (implemented by subclasses):
 * - scan(): Iterate through table rows
 * - initScanState(): Prepare scan state
 * - insert(): Add new rows
 * - update(): Modify existing rows
 * - delete_(): Remove rows
 * - checkpoint(): Persist changes to disk
 * - commit(): Apply transaction changes
 * 
 * State Object Lifecycle:
 * ```
 * 1. InsertState created with property vectors
 * 2. Passed to table.insert(transaction, state)
 * 3. State tracks logToWAL flag for durability
 * 4. State destroyed after operation
 * ```
 * 
 * Common Utilities:
 * 
 * 1. resetOutVectors():
 *    Clears auxiliary buffers and resets selection vectors.
 *    Called before each scan batch.
 * 
 * 2. setToTable():
 *    Binds scan state to specific table and columns.
 *    Initializes chunk states for each column.
 * 
 * 3. constructDataChunk():
 *    Creates DataChunk with typed ValueVectors.
 *    Used for bulk data transfer operations.
 * 
 * Design Patterns:
 * 
 * 1. Template Method Pattern:
 *    scan() calls scanInternal() which is overridden.
 * 
 * 2. State Object Pattern:
 *    Operations take state objects rather than many parameters.
 *    Enables flexible configuration and future extension.
 * 
 * 3. WAL Integration:
 *    logToWAL flag on state objects controls durability.
 *    Can be disabled for bulk operations.
 * 
 * Thread Safety:
 * - Table objects are NOT thread-safe by themselves
 * - Transactions provide isolation
 * - Concurrent access via transaction isolation
 * 
 * Extension Points:
 * - New table types can inherit from Table
 * - State objects can be extended with type-specific data
 * - Predicate pushdown via columnPredicateSets
 */

#include "storage/storage_manager.h"
#include "storage/table/node_table.h"
#include "storage/table/rel_table.h"

using namespace kuzu::common;

namespace kuzu {
namespace storage {

TableScanState::~TableScanState() = default;

// NOLINTNEXTLINE(readability-make-member-function-const): Semantically non-const.
void TableScanState::resetOutVectors() {
    for (const auto& outputVector : outputVectors) {
        KU_ASSERT(outputVector->state.get() == outState.get());
        KU_UNUSED(outputVector);
        outputVector->resetAuxiliaryBuffer();
    }
    outState->getSelVectorUnsafe().setToUnfiltered();
}

void TableScanState::setToTable(const transaction::Transaction*, Table* table_,
    std::vector<column_id_t> columnIDs_, std::vector<ColumnPredicateSet> columnPredicateSets_,
    RelDataDirection) {
    table = table_;
    columnIDs = std::move(columnIDs_);
    columnPredicateSets = std::move(columnPredicateSets_);
    nodeGroupScanState->chunkStates.resize(columnIDs.size());
}

TableInsertState::TableInsertState(std::vector<ValueVector*> propertyVectors)
    : propertyVectors{std::move(propertyVectors)}, logToWAL{true} {}
TableInsertState::~TableInsertState() = default;
TableUpdateState::TableUpdateState(column_id_t columnID, ValueVector& propertyVector)
    : columnID{columnID}, propertyVector{propertyVector}, logToWAL{true} {}
TableUpdateState::~TableUpdateState() = default;
TableDeleteState::TableDeleteState() : logToWAL{true} {}
TableDeleteState::~TableDeleteState() = default;

Table::Table(const catalog::TableCatalogEntry* tableEntry, const StorageManager* storageManager,
    MemoryManager* memoryManager)
    : tableType{tableEntry->getTableType()}, tableID{tableEntry->getTableID()},
      tableName{tableEntry->getName()}, enableCompression{storageManager->compressionEnabled()},
      memoryManager{memoryManager}, shadowFile{&storageManager->getShadowFile()},
      hasChanges{false} {}

Table::~Table() = default;

bool Table::scan(transaction::Transaction* transaction, TableScanState& scanState) {
    return scanInternal(transaction, scanState);
}

DataChunk Table::constructDataChunk(MemoryManager* mm, std::vector<LogicalType> types) {
    DataChunk dataChunk(types.size());
    for (auto i = 0u; i < types.size(); i++) {
        auto valueVector = std::make_unique<ValueVector>(std::move(types[i]), mm);
        dataChunk.insert(i, std::move(valueVector));
    }
    return dataChunk;
}

} // namespace storage
} // namespace kuzu
