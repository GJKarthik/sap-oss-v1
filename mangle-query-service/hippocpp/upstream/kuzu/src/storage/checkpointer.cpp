#include "storage/checkpointer.h"

/**
 * P3-176: Checkpointer - Extended Documentation
 * 
 * Additional Details (see P2-129 for base documentation)
 * 
 * Checkpoint Trigger Points:
 * | Trigger | Condition |
 * |---------|-----------|
 * | Manual | CHECKPOINT command |
 * | Auto | WAL size > threshold |
 * | Shutdown | Database close |
 * 
 * Auto-Checkpoint Algorithm:
 * ```cpp
 * if (localWAL.size + wal.fileSize > checkpointThreshold) {
 *     // Trigger checkpoint after current transaction commits
 * }
 * ```
 * 
 * Database Header Page Layout:
 * ```
 * Page 0 (DatabaseHeader):
 *   ├── databaseID: ku_uuid_t
 *   ├── catalogPageRange: {start, count}
 *   └── metadataPageRange: {start, count}
 * ```
 * 
 * Page Allocation During Checkpoint:
 * 1. Catalog serialization allocates pages
 * 2. Metadata serialization pre-allocates for PageManager
 * 3. PageManager tracks its own serialization pages
 * 4. Freed pages reclaimed after finalization
 * 
 * Rollback Handling:
 * ```
 * On checkpoint failure:
 *   rollback()
 *     └── rollbackCheckpoint()
 *           └── Restore freed page tracking
 * ```
 * 
 * Buffer Manager Interaction:
 * - removeEvictedCandidates() cleans eviction queue
 * - Prevents duplicate entries from freed/reused pages
 * - Called after finalizeCheckpoint()
 * 
 * Version Reset:
 * After successful checkpoint:
 * - Catalog version reset
 * - PageManager version reset  
 * - WAL cleared
 * - Shadow file removed
 * 
 * ====================================
 * 
 * P2-129: Checkpointer - Database Checkpoint Management
 * 
 * Purpose:
 * Manages database checkpointing for durability. Serializes catalog, metadata,
 * and storage state to disk using shadow paging for crash safety.
 * 
 * Architecture:
 * ```
 * Checkpointer
 *   ├── clientContext: ClientContext&
 *   └── isInMemory: bool    // Skip checkpointing for in-memory DBs
 * 
 * Database File Layout:
 *   Page 0: DatabaseHeader
 *     ├── catalogPageRange: PageRange
 *     └── metadataPageRange: PageRange
 *   
 *   Pages N..M: Serialized Catalog
 *   Pages M..K: Serialized Metadata (storage + page manager)
 * ```
 * 
 * Checkpoint Flow (writeCheckpoint):
 * ```
 * 1. checkpointStorage()
 *    └── Flush all dirty data to shadow pages
 * 
 * 2. serializeCatalogAndMetadata()
 *    ├── serializeCatalog() → Write catalog if changed
 *    └── serializeMetadata() → Write storage + page manager
 * 
 * 3. writeDatabaseHeader()
 *    └── Update header with new page ranges
 * 
 * 4. logCheckpointAndApplyShadowPages()
 *    ├── Flush shadow file
 *    ├── Write checkpoint marker to WAL
 *    ├── Apply shadow pages to data file
 *    └── Clear WAL and shadow file
 * 
 * 5. finalizeCheckpoint()
 *    └── Evict freed pages from buffer manager
 * ```
 * 
 * Recovery Flow (readCheckpoint):
 * ```
 * 1. Read DatabaseHeader from page 0
 * 2. Read Catalog from catalogPageRange
 * 3. Read Storage metadata from metadataPageRange
 * 4. Deserialize page manager state
 * 5. Auto-load linked extensions
 * ```
 * 
 * Key Operations:
 * 
 * 1. serializeCatalog(catalog, storageManager):
 *    - Write catalog to InMemFileWriter
 *    - Flush to allocated pages
 *    - Return PageRange
 * 
 * 2. serializeMetadata(catalog, storageManager):
 *    - Write storage metadata
 *    - Pre-allocate pages for page manager
 *    - Serialize page manager state
 *    - Return PageRange
 * 
 * 3. canAutoCheckpoint(context, transaction):
 *    - Check if WAL size exceeds threshold
 *    - Skip for in-memory or recovery transactions
 * 
 * 4. rollback():
 *    - Revert freed pages during failed checkpoint
 * 
 * Shadow Paging Strategy:
 * - Modified pages written to shadow file first
 * - On successful checkpoint, shadow pages applied atomically
 * - On crash before completion, original pages remain intact
 * 
 * Auto-Checkpoint:
 * ```
 * Triggered when:
 *   localWAL.size + wal.fileSize > checkpointThreshold
 * ```
 * 
 * Thread Safety:
 * - Checkpoint runs exclusively (no concurrent writes)
 * - Read operations use consistent snapshots
 * 
 * Performance:
 * - Incremental: Only serialize changed components
 * - Buffer eviction after checkpoint completion
 */

#include "catalog/catalog.h"
#include "common/file_system/file_system.h"
#include "common/file_system/virtual_file_system.h"
#include "common/serializer/buffered_file.h"
#include "common/serializer/deserializer.h"
#include "common/serializer/in_mem_file_writer.h"
#include "extension/extension_manager.h"
#include "main/client_context.h"
#include "main/db_config.h"
#include "storage/buffer_manager/buffer_manager.h"
#include "storage/database_header.h"
#include "storage/shadow_utils.h"
#include "storage/storage_manager.h"
#include "storage/wal/local_wal.h"

namespace kuzu {
namespace storage {

Checkpointer::Checkpointer(main::ClientContext& clientContext)
    : clientContext{clientContext},
      isInMemory{main::DBConfig::isDBPathInMemory(clientContext.getDatabasePath())} {}

Checkpointer::~Checkpointer() = default;

PageRange Checkpointer::serializeCatalog(const catalog::Catalog& catalog,
    StorageManager& storageManager) {
    auto catalogWriter =
        std::make_shared<common::InMemFileWriter>(*MemoryManager::Get(clientContext));
    common::Serializer catalogSerializer(catalogWriter);
    catalog.serialize(catalogSerializer);
    auto pageAllocator = storageManager.getDataFH()->getPageManager();
    return catalogWriter->flush(*pageAllocator, storageManager.getShadowFile());
}

PageRange Checkpointer::serializeMetadata(const catalog::Catalog& catalog,
    StorageManager& storageManager) {
    auto metadataWriter =
        std::make_shared<common::InMemFileWriter>(*MemoryManager::Get(clientContext));
    common::Serializer metadataSerializer(metadataWriter);
    storageManager.serialize(catalog, metadataSerializer);

    // We need to preallocate the pages for the page manager before we actually serialize it,
    // this is because the page manager needs to track the pages used for itself.
    // The number of pages needed for the page manager should only decrease after making an
    // additional allocation, so we just calculate the number of pages needed to serialize the
    // current state of the page manager.
    // Thus, it is possible that we allocate an extra page that we won't end up writing to when we
    // flush the metadata writer. This may cause a discrepancy between the number of tracked pages
    // and the number of physical pages in the file but shouldn't cause any actual incorrect
    // behavior in the database.
    auto& pageManager = *storageManager.getDataFH()->getPageManager();
    const auto pagesForPageManager = pageManager.estimatePagesNeededForSerialize();
    auto pageAllocator = storageManager.getDataFH()->getPageManager();
    const auto allocatedPages = pageAllocator->allocatePageRange(
        metadataWriter->getNumPagesToFlush() + pagesForPageManager);
    pageManager.serialize(metadataSerializer);

    metadataWriter->flush(allocatedPages, pageAllocator->getDataFH(),
        storageManager.getShadowFile());
    return allocatedPages;
}

void Checkpointer::writeCheckpoint() {
    if (isInMemory) {
        return;
    }

    auto databaseHeader =
        *StorageManager::Get(clientContext)->getOrInitDatabaseHeader(clientContext);
    // Checkpoint storage. Note that we first checkpoint storage before serializing the catalog, as
    // checkpointing storage may overwrite columnIDs in the catalog.
    bool hasStorageChanges = checkpointStorage();
    serializeCatalogAndMetadata(databaseHeader, hasStorageChanges);
    writeDatabaseHeader(databaseHeader);
    logCheckpointAndApplyShadowPages();

    // This function will evict all pages that were freed during this checkpoint
    // It must be called before we remove all evicted candidates from the BM
    // Or else the evicted pages may end up appearing multiple times in the eviction queue
    auto storageManager = StorageManager::Get(clientContext);
    storageManager->finalizeCheckpoint();
    // When a page is freed by the FSM, it evicts it from the BM. However, if the page is freed,
    // then reused over and over, it can be appended to the eviction queue multiple times. To
    // prevent multiple entries of the same page from existing in the eviction queue, at the end of
    // each checkpoint we remove any already-evicted pages.
    auto bufferManager = MemoryManager::Get(clientContext)->getBufferManager();
    bufferManager->removeEvictedCandidates();

    catalog::Catalog::Get(clientContext)->resetVersion();
    auto* dataFH = storageManager->getDataFH();
    dataFH->getPageManager()->resetVersion();
    storageManager->getWAL().reset();
    storageManager->getShadowFile().reset();
}

bool Checkpointer::checkpointStorage() {
    const auto storageManager = StorageManager::Get(clientContext);
    auto pageAllocator = storageManager->getDataFH()->getPageManager();
    return storageManager->checkpoint(&clientContext, *pageAllocator);
}

void Checkpointer::serializeCatalogAndMetadata(DatabaseHeader& databaseHeader,
    bool hasStorageChanges) {
    const auto storageManager = StorageManager::Get(clientContext);
    const auto catalog = catalog::Catalog::Get(clientContext);
    auto* dataFH = storageManager->getDataFH();

    // Serialize the catalog if there are changes
    if (databaseHeader.catalogPageRange.startPageIdx == common::INVALID_PAGE_IDX ||
        catalog->changedSinceLastCheckpoint()) {
        databaseHeader.updateCatalogPageRange(*dataFH->getPageManager(),
            serializeCatalog(*catalog, *storageManager));
    }
    // Serialize the storage metadata if there are changes
    if (databaseHeader.metadataPageRange.startPageIdx == common::INVALID_PAGE_IDX ||
        hasStorageChanges || catalog->changedSinceLastCheckpoint() ||
        dataFH->getPageManager()->changedSinceLastCheckpoint()) {
        // We must free the existing metadata page range before serializing
        // So that the freed pages are serialized by the FSM
        databaseHeader.freeMetadataPageRange(*dataFH->getPageManager());
        databaseHeader.metadataPageRange = serializeMetadata(*catalog, *storageManager);
    }
}

void Checkpointer::writeDatabaseHeader(const DatabaseHeader& header) {
    auto headerWriter =
        std::make_shared<common::InMemFileWriter>(*MemoryManager::Get(clientContext));
    common::Serializer headerSerializer(headerWriter);
    header.serialize(headerSerializer);
    auto headerPage = headerWriter->getPage(0);

    const auto storageManager = StorageManager::Get(clientContext);
    auto dataFH = storageManager->getDataFH();
    auto& shadowFile = storageManager->getShadowFile();
    auto shadowHeader = ShadowUtils::createShadowVersionIfNecessaryAndPinPage(
        common::StorageConstants::DB_HEADER_PAGE_IDX, true /* skipReadingOriginalPage */, *dataFH,
        shadowFile);
    memcpy(shadowHeader.frame, headerPage.data(), common::KUZU_PAGE_SIZE);
    shadowFile.getShadowingFH().unpinPage(shadowHeader.shadowPage);

    // Update the in-memory database header with the new version
    StorageManager::Get(clientContext)->setDatabaseHeader(std::make_unique<DatabaseHeader>(header));
}

void Checkpointer::logCheckpointAndApplyShadowPages() {
    const auto storageManager = StorageManager::Get(clientContext);
    auto& shadowFile = storageManager->getShadowFile();
    // Flush the shadow file.
    shadowFile.flushAll(clientContext);
    auto wal = WAL::Get(clientContext);
    // Log the checkpoint to the WAL and flush WAL. This indicates that all shadow pages and
    // files (snapshots of catalog and metadata) have been written to disk. The part that is not
    // done is to replace them with the original pages or catalog and metadata files. If the
    // system crashes before this point, the WAL can still be used to recover the system to a
    // state where the checkpoint can be redone.
    wal->logAndFlushCheckpoint(&clientContext);
    shadowFile.applyShadowPages(clientContext);
    // Clear the wal and also shadowing files.
    auto bufferManager = MemoryManager::Get(clientContext)->getBufferManager();
    wal->clear();
    shadowFile.clear(*bufferManager);
}

void Checkpointer::rollback() {
    if (isInMemory) {
        return;
    }
    const auto storageManager = StorageManager::Get(clientContext);
    auto catalog = catalog::Catalog::Get(clientContext);
    // Any pages freed during the checkpoint are no longer freed
    storageManager->rollbackCheckpoint(*catalog);
}

bool Checkpointer::canAutoCheckpoint(const main::ClientContext& clientContext,
    const transaction::Transaction& transaction) {
    if (clientContext.isInMemory()) {
        return false;
    }
    if (!clientContext.getDBConfig()->autoCheckpoint) {
        return false;
    }
    if (transaction.isRecovery()) {
        // Recovery transactions are not allowed to trigger auto checkpoint.
        return false;
    }
    auto wal = WAL::Get(clientContext);
    const auto expectedSize = transaction.getLocalWAL().getSize() + wal->getFileSize();
    return expectedSize > clientContext.getDBConfig()->checkpointThreshold;
}

void Checkpointer::readCheckpoint() {
    auto storageManager = StorageManager::Get(clientContext);
    storageManager->initDataFileHandle(common::VirtualFileSystem::GetUnsafe(clientContext),
        &clientContext);
    if (!isInMemory && storageManager->getDataFH()->getNumPages() > 0) {
        readCheckpoint(&clientContext, catalog::Catalog::Get(clientContext), storageManager);
    }
    extension::ExtensionManager::Get(clientContext)->autoLoadLinkedExtensions(&clientContext);
}

void Checkpointer::readCheckpoint(main::ClientContext* context, catalog::Catalog* catalog,
    StorageManager* storageManager) {
    auto fileInfo = storageManager->getDataFH()->getFileInfo();
    auto reader = std::make_unique<common::BufferedFileReader>(*fileInfo);
    common::Deserializer deSer(std::move(reader));
    auto currentHeader = std::make_unique<DatabaseHeader>(DatabaseHeader::deserialize(deSer));
    // If the catalog page range is invalid, it means there is no catalog to read; thus, the
    // database is empty.
    if (currentHeader->catalogPageRange.startPageIdx != common::INVALID_PAGE_IDX) {
        deSer.getReader()->cast<common::BufferedFileReader>()->resetReadOffset(
            currentHeader->catalogPageRange.startPageIdx * common::KUZU_PAGE_SIZE);
        catalog->deserialize(deSer);
        deSer.getReader()->cast<common::BufferedFileReader>()->resetReadOffset(
            currentHeader->metadataPageRange.startPageIdx * common::KUZU_PAGE_SIZE);
        storageManager->deserialize(context, catalog, deSer);
        storageManager->getDataFH()->getPageManager()->deserialize(deSer);
    }
    storageManager->setDatabaseHeader(std::move(currentHeader));
}

} // namespace storage
} // namespace kuzu
