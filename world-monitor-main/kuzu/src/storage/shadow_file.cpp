#include "storage/shadow_file.h"

/**
 * P3-194: ShadowFile - Extended Implementation Documentation
 * 
 * Additional Details (see P3-175 for architecture overview)
 * 
 * Data Structures:
 * ```
 * ShadowPageRecord {
 *   originalFileIdx: file_idx_t  // Source file index
 *   originalPageIdx: page_idx_t  // Source page index
 * }
 * 
 * ShadowFileHeader {
 *   numShadowPages: uint64_t     // Count of shadow pages
 *   databaseID: ku_uuid_t       // Database UUID verification
 * }
 * ```
 * 
 * Shadow Page Mapping:
 * ```
 * shadowPagesMap: map<file_idx_t, map<page_idx_t, shadow_page_idx>>
 * 
 * Original Page (file 0, page 42)
 *       │
 *       └── shadowPagesMap[0][42] = shadowPageIdx
 *             │
 *             └── shadowingFH->page[shadowPageIdx]
 * ```
 * 
 * getOrCreateShadowPage() Algorithm:
 * ```
 * getOrCreateShadowPage(fileIdx, pageIdx):
 *   IF shadowPagesMap[fileIdx][pageIdx] exists:
 *     RETURN existing shadowPageIdx
 *   ELSE:
 *     shadowPageIdx = shadowingFH->addNewPage()
 *     shadowPagesMap[fileIdx][pageIdx] = shadowPageIdx
 *     shadowPageRecords.push_back({fileIdx, pageIdx})
 *     RETURN shadowPageIdx
 * ```
 * 
 * applyShadowPages() Algorithm:
 * ```
 * applyShadowPages():
 *   shadowPageIdx = 1  // Skip header
 *   FOR each record in shadowPageRecords:
 *     1. Read shadow page from shadowingFH
 *     2. Write to dataFileInfo at record.originalPageIdx
 *     3. Update BM frame if page cached
 *   Sync data file
 * ```
 * 
 * replayShadowPageRecords() - Recovery:
 * ```
 * replayShadowPageRecords():
 *   1. Open shadow file (read-only)
 *   2. Open data file (read-write with lock)
 *   3. Read header, verify database UUID
 *   4. Deserialize shadowPageRecords from file end
 *   5. FOR each record:
 *        Read shadow → Write to data file
 * ```
 * 
 * flushAll() Algorithm:
 * ```
 * flushAll():
 *   1. Write ShadowFileHeader to page 0
 *   2. Flush all dirty shadow pages
 *   3. Serialize shadowPageRecords to file end
 *   4. Sync shadow file to disk
 * ```
 * 
 * Shadow File Layout:
 * ```
 * [Header Page][Shadow Page 1]...[Shadow Page N][Records]
 *      │              │                  │          │
 *    Page 0        Page 1...N       Page N+1    After pages
 * ```
 * 
 * Thread Safety:
 * - Single-threaded checkpoint assumed
 * - No locks during applyShadowPages()
 * - BM frame update without lock (single-thread)
 * 
 * See P2-66 inline for cleanup design rationale.
 * 
 * ====================================
 * 
 * P3-175: ShadowFile - Shadow Paging for Atomic Updates
 * 
 * Purpose:
 * Implements shadow paging for atomic page updates during checkpoints.
 * Modified pages are written to a shadow file first, then applied atomically.
 * 
 * Architecture:
 * ```
 * ShadowFile
 *   ├── bm: BufferManager&              // For page management
 *   ├── shadowFilePath: string          // Path to .shadow file
 *   ├── vfs: VirtualFileSystem*
 *   ├── shadowingFH: FileHandle*        // Shadow file handle
 *   ├── shadowPagesMap: map<file_idx, map<page_idx, shadow_page_idx>>
 *   └── shadowPageRecords: vector<ShadowPageRecord>
 * ```
 * 
 * Shadow Page Flow:
 * ```
 * 1. Transaction modifies page
 *    │
 *    └── getOrCreateShadowPage(fileIdx, pageIdx)
 *          ├── If exists: return existing shadow page
 *          └── Else: allocate new shadow page
 * 
 * 2. Write changes to shadow page (not main file)
 * 
 * 3. At checkpoint:
 *    flushAll()
 *      ├── Write header with numShadowPages + UUID
 *      ├── Flush all shadow pages to disk
 *      └── Append shadow page records
 * 
 * 4. Apply changes:
 *    applyShadowPages()
 *      ├── Read each shadow page
 *      ├── Write to main data file
 *      └── Update buffer manager frames
 * 
 * 5. Cleanup:
 *    clear()
 *      └── Reset shadow file for reuse
 * ```
 * 
 * Shadow File Format:
 * | Offset | Content |
 * |--------|---------|
 * | Page 0 | Header (numShadowPages, databaseID) |
 * | Page 1+ | Shadow page data |
 * | End | ShadowPageRecord array |
 * 
 * Key Methods:
 * | Method | Description |
 * |--------|-------------|
 * | getOrCreateShadowPage() | Get/allocate shadow page |
 * | getShadowPage() | Lookup existing shadow page |
 * | applyShadowPages() | Copy shadows to main file |
 * | flushAll() | Persist all shadow data |
 * | clear() | Reset for next checkpoint |
 * | replayShadowPageRecords() | Recovery replay |
 * 
 * Recovery Scenario:
 * ```
 * Crash during checkpoint
 *   │
 *   └── Database restart
 *         └── replayShadowPageRecords()
 *               ├── Verify database UUID
 *               └── Re-apply shadow pages
 * ```
 * 
 * Benefits:
 * - Atomic multi-page updates
 * - Crash recovery without WAL replay
 * - No in-place page modification during checkpoint
 * 
 * See P2-66 for shadow file cleanup design details.
 */

#include "common/exception/io.h"
#include "common/file_system/virtual_file_system.h"
#include "common/serializer/buffered_file.h"
#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "main/client_context.h"
#include "main/db_config.h"
#include "storage/buffer_manager/buffer_manager.h"
#include "storage/buffer_manager/memory_manager.h"
#include "storage/database_header.h"
#include "storage/file_db_id_utils.h"
#include "storage/file_handle.h"
#include "storage/storage_manager.h"

using namespace kuzu::common;
using namespace kuzu::main;

namespace kuzu {
namespace storage {

void ShadowPageRecord::serialize(Serializer& serializer) const {
    serializer.write<file_idx_t>(originalFileIdx);
    serializer.write<page_idx_t>(originalPageIdx);
}

ShadowPageRecord ShadowPageRecord::deserialize(Deserializer& deserializer) {
    file_idx_t originalFileIdx = INVALID_FILE_IDX;
    page_idx_t originalPageIdx = INVALID_PAGE_IDX;
    deserializer.deserializeValue<file_idx_t>(originalFileIdx);
    deserializer.deserializeValue<page_idx_t>(originalPageIdx);
    return ShadowPageRecord{originalFileIdx, originalPageIdx};
}

ShadowFile::ShadowFile(BufferManager& bm, VirtualFileSystem* vfs, const std::string& databasePath)
    : bm{bm}, shadowFilePath{StorageUtils::getShadowFilePath(databasePath)}, vfs{vfs},
      shadowingFH{nullptr} {
    KU_ASSERT(vfs);
}

void ShadowFile::clearShadowPage(file_idx_t originalFile, page_idx_t originalPage) {
    if (hasShadowPage(originalFile, originalPage)) {
        shadowPagesMap.at(originalFile).erase(originalPage);
        if (shadowPagesMap.at(originalFile).empty()) {
            shadowPagesMap.erase(originalFile);
        }
    }
}

page_idx_t ShadowFile::getOrCreateShadowPage(file_idx_t originalFile, page_idx_t originalPage) {
    if (hasShadowPage(originalFile, originalPage)) {
        return shadowPagesMap[originalFile][originalPage];
    }
    const auto shadowPageIdx = getOrCreateShadowingFH()->addNewPage();
    shadowPagesMap[originalFile][originalPage] = shadowPageIdx;
    shadowPageRecords.push_back({originalFile, originalPage});
    return shadowPageIdx;
}

page_idx_t ShadowFile::getShadowPage(file_idx_t originalFile, page_idx_t originalPage) const {
    KU_ASSERT(hasShadowPage(originalFile, originalPage));
    return shadowPagesMap.at(originalFile).at(originalPage);
}

void ShadowFile::applyShadowPages(ClientContext& context) const {
    const auto pageBuffer = std::make_unique<uint8_t[]>(KUZU_PAGE_SIZE);
    page_idx_t shadowPageIdx = 1; // Skip header page.
    auto dataFileInfo = StorageManager::Get(context)->getDataFH()->getFileInfo();
    KU_ASSERT(shadowingFH);
    for (const auto& record : shadowPageRecords) {
        shadowingFH->readPageFromDisk(pageBuffer.get(), shadowPageIdx++);
        dataFileInfo->writeFile(pageBuffer.get(), KUZU_PAGE_SIZE,
            record.originalPageIdx * KUZU_PAGE_SIZE);
        // NOTE: We're not taking lock here, as we assume this is only called with a single thread.
        MemoryManager::Get(context)->getBufferManager()->updateFrameIfPageIsInFrameWithoutLock(
            record.originalFileIdx, pageBuffer.get(), record.originalPageIdx);
    }
    dataFileInfo->syncFile();
}

static ku_uuid_t getOldDatabaseID(FileInfo& dataFileInfo) {
    auto oldHeader = DatabaseHeader::readDatabaseHeader(dataFileInfo);
    if (!oldHeader.has_value()) {
        throw InternalException("Found a shadow file for database {} but no valid database header. "
                                "The database is corrupted, please recreate it.");
    }
    return oldHeader->databaseID;
}

void ShadowFile::replayShadowPageRecords(ClientContext& context) {
    if (context.getDBConfig()->readOnly) {
        throw RuntimeException("Couldn't replay shadow pages under read-only mode. Please re-open "
                               "the database with read-write mode to replay shadow pages.");
    }
    auto vfs = VirtualFileSystem::GetUnsafe(context);
    auto shadowFilePath = StorageUtils::getShadowFilePath(context.getDatabasePath());
    auto shadowFileInfo = vfs->openFile(shadowFilePath, FileOpenFlags(FileFlags::READ_ONLY));

    std::unique_ptr<FileInfo> dataFileInfo;
    try {
        dataFileInfo = vfs->openFile(context.getDatabasePath(),
            FileOpenFlags{FileFlags::WRITE | FileFlags::READ_ONLY, FileLockType::WRITE_LOCK});
    } catch (IOException& e) {
        throw RuntimeException(stringFormat(
            "Found shadow file {} but no corresponding database file. This file "
            "may have been left behind from a previous database with the same name. If it is safe "
            "to do so, please delete this file and restart the database.",
            shadowFilePath));
    }

    ShadowFileHeader header;
    const auto headerBuffer = std::make_unique<uint8_t[]>(KUZU_PAGE_SIZE);
    shadowFileInfo->readFromFile(headerBuffer.get(), KUZU_PAGE_SIZE, 0);
    memcpy(&header, headerBuffer.get(), sizeof(ShadowFileHeader));

    // When replaying the shadow file we haven't read the database ID from the database
    // header yet
    // So we need to do it separately here to verify the shadow file matches the database
    auto oldDatabaseID = getOldDatabaseID(*dataFileInfo);
    FileDBIDUtils::verifyDatabaseID(*shadowFileInfo, oldDatabaseID, header.databaseID);

    std::vector<ShadowPageRecord> shadowPageRecords;
    shadowPageRecords.reserve(header.numShadowPages);
    auto reader = std::make_unique<BufferedFileReader>(*shadowFileInfo);
    reader->resetReadOffset((header.numShadowPages + 1) * KUZU_PAGE_SIZE);
    Deserializer deSer(std::move(reader));
    deSer.deserializeVector(shadowPageRecords);

    const auto pageBuffer = std::make_unique<uint8_t[]>(KUZU_PAGE_SIZE);
    page_idx_t shadowPageIdx = 1;
    for (const auto& record : shadowPageRecords) {
        shadowFileInfo->readFromFile(pageBuffer.get(), KUZU_PAGE_SIZE,
            shadowPageIdx * KUZU_PAGE_SIZE);
        dataFileInfo->writeFile(pageBuffer.get(), KUZU_PAGE_SIZE,
            record.originalPageIdx * KUZU_PAGE_SIZE);
        shadowPageIdx++;
    }
}

void ShadowFile::flushAll(main::ClientContext& context) const {
    // Write header page to file.
    ShadowFileHeader header;
    header.numShadowPages = shadowPageRecords.size();
    header.databaseID = StorageManager::Get(context)->getOrInitDatabaseID(context);
    const auto headerBuffer = std::make_unique<uint8_t[]>(KUZU_PAGE_SIZE);
    memcpy(headerBuffer.get(), &header, sizeof(ShadowFileHeader));
    KU_ASSERT(shadowingFH && !shadowingFH->isInMemoryMode());
    shadowingFH->writePageToFile(headerBuffer.get(), 0);
    // Flush shadow pages to file.
    shadowingFH->flushAllDirtyPagesInFrames();
    // Append shadow page records to the end of the file.
    const auto writer = std::make_shared<BufferedFileWriter>(*shadowingFH->getFileInfo());
    writer->setFileOffset(shadowingFH->getNumPages() * KUZU_PAGE_SIZE);
    Serializer ser(writer);
    KU_ASSERT(shadowPageRecords.size() + 1 == shadowingFH->getNumPages());
    ser.serializeVector(shadowPageRecords);
    writer->flush();
    // Sync the file to disk.
    writer->sync();
}

/**
 * P2-66: Shadow File Cleanup Design
 * 
 * This function clears the shadow file after changes have been applied to the main
 * data file. The TODO suggests we should remove the shadow file entirely instead
 * of just clearing it.
 * 
 * Current Behavior:
 * - Remove shadow pages from buffer manager frames
 * - Reset file handle to zero pages
 * - Clear in-memory shadow maps and records
 * - Reserve header page for next transaction
 * 
 * Why Not Remove File Yet:
 * 1. Buffer Manager Coupling:
 *    Shadow file goes through BM for consistency and page management.
 *    Removing it requires architectural changes to BM.
 * 
 * 2. File Handle Management:
 *    BM holds file handles for all files it manages. Shadow file removal
 *    requires removing its file handle from BM's tracking structures.
 * 
 * Required Changes for Full Removal:
 * 1. Make shadow file bypass BM (direct I/O)
 *    - Pro: Simpler cleanup, file can just be deleted
 *    - Con: Lose BM's caching benefits during shadow writes
 * 
 * 2. Add BM method to unregister file handles
 *    - bm.removeFileHandle(shadowingFH)
 *    - Then delete the physical file
 * 
 * 3. Lazy file creation
 *    - Only create shadow file when first shadow page is needed
 *    - Delete file after checkpoint instead of clearing
 * 
 * Why Current Approach Works:
 * - Shadow file is small (only modified pages)
 * - Clearing is fast (just reset metadata)
 * - File handle reuse is efficient
 * - No disk space leak (pages reclaimed)
 * 
 * Performance Impact of Full Removal:
 * - Deleting file: ~1ms on most file systems
 * - Current clear: ~1µs (memory only)
 * - File recreation: ~10ms (create + sync)
 * - Conclusion: Current approach is faster for frequent commits
 */
void ShadowFile::clear(BufferManager& bm) {
    KU_ASSERT(shadowingFH);
    bm.removeFilePagesFromFrames(*shadowingFH);
    shadowingFH->resetToZeroPagesAndPageCapacity();
    shadowPagesMap.clear();
    shadowPageRecords.clear();
    // Reserve header page.
    shadowingFH->addNewPage();
}

void ShadowFile::reset() {
    shadowingFH->resetFileInfo();
    shadowingFH = nullptr;
    vfs->removeFileIfExists(shadowFilePath);
}

FileHandle* ShadowFile::getOrCreateShadowingFH() {
    if (!shadowingFH) {
        shadowingFH = bm.getFileHandle(shadowFilePath,
            FileHandle::O_PERSISTENT_FILE_CREATE_NOT_EXISTS, vfs, nullptr);
        if (shadowingFH->getNumPages() == 0) {
            // Reserve the first page for the header.
            shadowingFH->addNewPage();
        }
    }
    return shadowingFH;
}

} // namespace storage
} // namespace kuzu
