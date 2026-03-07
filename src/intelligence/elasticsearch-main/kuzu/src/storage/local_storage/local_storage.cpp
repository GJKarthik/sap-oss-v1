#include "storage/local_storage/local_storage.h"

/**
 * P3-202: LocalStorage - Per-Transaction Local Storage Manager
 * 
 * Purpose:
 * Manages transaction-local storage for uncommitted changes.
 * Each transaction has its own LocalStorage containing LocalTables
 * for modified tables. Changes are committed to main storage on success.
 * 
 * Architecture:
 * ```
 * LocalStorage (per transaction)
 *   ├── clientContext: ClientContext&  // Transaction context
 *   ├── tables: map<table_id_t, unique_ptr<LocalTable>>
 *   │     ├── LocalNodeTable (for node tables)
 *   │     └── LocalRelTable (for rel tables)
 *   ├── optimisticAllocators: vector<unique_ptr<OptimisticAllocator>>
 *   └── mtx: mutex  // Thread safety for allocators
 * ```
 * 
 * getOrCreateLocalTable() Flow:
 * ```
 * getOrCreateLocalTable(table):
 *   tableID = table.getTableID()
 *   IF !tables.contains(tableID):
 *     SWITCH table.getTableType():
 *       NODE:
 *         entry = catalog.getTableCatalogEntry(tableID)
 *         tables[tableID] = new LocalNodeTable(entry, table, mm)
 *       REL:
 *         entry = catalog.getEntry(table.getRelGroupID())
 *         tables[tableID] = new LocalRelTable(entry, table, mm)
 *   RETURN tables[tableID]
 * ```
 * 
 * addOptimisticAllocator() Flow:
 * ```
 * addOptimisticAllocator():
 *   dataFH = StorageManager.getDataFH()
 *   IF dataFH.isInMemoryMode():
 *     RETURN dataFH.getPageManager()  // Reuse existing
 *   LOCK mtx
 *   optimisticAllocators.add(new OptimisticAllocator(pageManager))
 *   RETURN optimisticAllocators.back()
 * ```
 * 
 * commit() Flow:
 * ```
 * commit():
 *   // Phase 1: Commit node tables first (for FK references)
 *   FOR each localTable WHERE type == NODE:
 *     entry = catalog.getEntry(tableID)
 *     table = storageManager.getTable(tableID)
 *     table.commit(context, entry, localTable)
 *   
 *   // Phase 2: Commit rel tables (may reference nodes)
 *   FOR each localTable WHERE type == REL:
 *     table = storageManager.getTable(tableID)
 *     entry = catalog.getEntry(table.getRelGroupID())
 *     table.commit(context, entry, localTable)
 *   
 *   // Phase 3: Commit page allocations
 *   FOR each optimisticAllocator:
 *     allocator.commit()
 * ```
 * 
 * rollback() Flow:
 * ```
 * rollback():
 *   mm = MemoryManager.Get(context)
 *   FOR each localTable:
 *     localTable.clear(mm)  // Discard local changes
 *   FOR each optimisticAllocator:
 *     allocator.rollback()  // Free allocated pages
 *   PageManager.clearEvictedBMEntriesIfNeeded()
 * ```
 * 
 * Optimistic Allocation:
 * - Pages allocated optimistically during transaction
 * - OptimisticAllocator tracks pending allocations
 * - commit(): Makes allocations permanent
 * - rollback(): Returns allocated pages to free list
 * 
 * Thread Safety:
 * - Local tables are single-writer (transaction owns)
 * - Allocator list protected by mutex (copy-on-write pattern)
 * 
 * Usage in Transaction:
 * ```cpp
 * // During INSERT/UPDATE/DELETE
 * auto* localStorage = Transaction::Get(ctx)->getLocalStorage();
 * auto* localTable = localStorage->getOrCreateLocalTable(table);
 * localTable->insert(...) / update(...) / delete(...)
 * 
 * // On COMMIT
 * localStorage->commit();
 * 
 * // On ROLLBACK
 * localStorage->rollback();
 * ```
 */

#include "storage/local_storage/local_node_table.h"
#include "storage/local_storage/local_rel_table.h"
#include "storage/local_storage/local_table.h"
#include "storage/storage_manager.h"
#include "storage/table/rel_table.h"
#include "storage/table/table.h"

using namespace kuzu::common;
using namespace kuzu::transaction;

namespace kuzu {
namespace storage {

LocalTable* LocalStorage::getOrCreateLocalTable(Table& table) {
    const auto tableID = table.getTableID();
    auto catalog = catalog::Catalog::Get(clientContext);
    auto transaction = transaction::Transaction::Get(clientContext);
    auto& mm = *MemoryManager::Get(clientContext);
    if (!tables.contains(tableID)) {
        switch (table.getTableType()) {
        case TableType::NODE: {
            auto tableEntry = catalog->getTableCatalogEntry(transaction, table.getTableID());
            tables[tableID] = std::make_unique<LocalNodeTable>(tableEntry, table, mm);
        } break;
        case TableType::REL: {
            // We have to fetch the rel group entry from the catalog to based on the relGroupID.
            auto tableEntry =
                catalog->getTableCatalogEntry(transaction, table.cast<RelTable>().getRelGroupID());
            tables[tableID] = std::make_unique<LocalRelTable>(tableEntry, table, mm);
        } break;
        default:
            KU_UNREACHABLE;
        }
    }
    return tables.at(tableID).get();
}

LocalTable* LocalStorage::getLocalTable(table_id_t tableID) const {
    if (tables.contains(tableID)) {
        return tables.at(tableID).get();
    }
    return nullptr;
}

PageAllocator* LocalStorage::addOptimisticAllocator() {
    auto* dataFH = StorageManager::Get(clientContext)->getDataFH();
    if (dataFH->isInMemoryMode()) {
        return dataFH->getPageManager();
    }
    UniqLock lck{mtx};
    optimisticAllocators.emplace_back(
        std::make_unique<OptimisticAllocator>(*dataFH->getPageManager()));
    return optimisticAllocators.back().get();
}

void LocalStorage::commit() {
    auto catalog = catalog::Catalog::Get(clientContext);
    auto transaction = transaction::Transaction::Get(clientContext);
    auto storageManager = StorageManager::Get(clientContext);
    for (auto& [tableID, localTable] : tables) {
        if (localTable->getTableType() == TableType::NODE) {
            const auto tableEntry = catalog->getTableCatalogEntry(transaction, tableID);
            const auto table = storageManager->getTable(tableID);
            table->commit(&clientContext, tableEntry, localTable.get());
        }
    }
    for (auto& [tableID, localTable] : tables) {
        if (localTable->getTableType() == TableType::REL) {
            const auto table = storageManager->getTable(tableID);
            const auto tableEntry =
                catalog->getTableCatalogEntry(transaction, table->cast<RelTable>().getRelGroupID());
            table->commit(&clientContext, tableEntry, localTable.get());
        }
    }
    for (auto& optimisticAllocator : optimisticAllocators) {
        optimisticAllocator->commit();
    }
}

void LocalStorage::rollback() {
    auto mm = MemoryManager::Get(clientContext);
    for (auto& [_, localTable] : tables) {
        localTable->clear(*mm);
    }
    for (auto& optimisticAllocator : optimisticAllocators) {
        optimisticAllocator->rollback();
    }
    auto* bufferManager = mm->getBufferManager();
    PageManager::Get(clientContext)->clearEvictedBMEntriesIfNeeded(bufferManager);
}

} // namespace storage
} // namespace kuzu
