#include "storage/buffer_manager/spiller.h"

/**
 * P3-211: Spiller - Memory-to-Disk Spilling Manager
 * 
 * Purpose:
 * Manages spilling of memory buffers to disk under memory pressure.
 * Provides coordinated spilling of column chunks and partitioner groups.
 * 
 * Architecture:
 * ```
 * Spiller {
 *   tmpFilePath: string           // Temp file for spilled data
 *   bufferManager: BufferManager& // For file handle creation
 *   vfs: VirtualFileSystem*       // File operations
 *   dataFH: atomic<FileHandle*>   // Lazy-initialized temp file
 *   fullPartitionerGroups: set<InMemChunkedNodeGroup*>
 *   partitionerGroupsMtx: mutex   // Protects set
 *   fileCreationMutex: mutex      // For lazy init
 * }
 * ```
 * 
 * Constructor:
 * ```
 * Spiller(tmpFilePath, bm, vfs):
 *   // Remove existing temp file from previous run
 *   vfs.removeFileIfExists(tmpFilePath)
 * ```
 * 
 * getOrCreateDataFH() - Double-checked Locking:
 * ```
 * getOrCreateDataFH():
 *   IF dataFH.load(): RETURN dataFH  // Fast path
 *   
 *   LOCK fileCreationMutex
 *   IF dataFH.load(): RETURN dataFH  // Another thread created
 *   
 *   dataFH = bm.getFileHandle(tmpFilePath, O_PERSISTENT_CREATE)
 *   RETURN dataFH
 * ```
 * 
 * spillToDisk() Algorithm:
 * ```
 * spillToDisk(chunk):
 *   buffer = chunk.buffer
 *   ASSERT !buffer.evicted
 *   
 *   dataFH = getOrCreateDataFH()
 *   pageSize = dataFH.getPageSize()
 *   numPages = ceil(buffer.size / pageSize)
 *   startPage = dataFH.addNewPages(numPages)
 *   
 *   dataFH.writePagesToFile(buffer.data, buffer.size, startPage)
 *   RETURN buffer.setSpilledToDisk(startPage * pageSize)
 * ```
 * 
 * loadFromDisk() Algorithm:
 * ```
 * loadFromDisk(chunk):
 *   buffer = chunk.buffer
 *   IF buffer.evicted:
 *     buffer.prepareLoadFromDisk()  // Reallocate memory
 *     dataFH.readFromFile(buffer.data, buffer.size, buffer.filePosition)
 * ```
 * 
 * Partitioner Groups Management:
 * ```
 * addUnusedChunk(nodeGroup):
 *   LOCK partitionerGroupsMtx
 *   fullPartitionerGroups.insert(nodeGroup)
 * 
 * clearUnusedChunk(nodeGroup):
 *   LOCK partitionerGroupsMtx
 *   fullPartitionerGroups.erase(nodeGroup)
 * 
 * claimNextGroup():
 *   LOCK partitionerGroupsMtx
 *   IF fullPartitionerGroups.empty(): RETURN {}
 *   groupToFlush = *begin()
 *   fullPartitionerGroups.erase(begin())
 *   UNLOCK
 *   RETURN groupToFlush.spillToDisk()
 * ```
 * 
 * Destructor:
 * ```
 * ~Spiller():
 *   vfs.removeFileIfExists(tmpFilePath)  // Cleanup
 * ```
 * 
 * Thread Safety:
 * - fileCreationMutex for lazy file creation
 * - partitionerGroupsMtx for group set access
 * - atomic<FileHandle*> for double-checked locking
 * 
 * File Layout:
 * ```
 * [Page 0][Page 1]...[Page N]
 * Each buffer gets consecutive pages
 * Position stored in MemoryBuffer::filePosition
 * ```
 */

#include <mutex>

#include "common/assert.h"
#include "common/exception/io.h"
#include "common/file_system/virtual_file_system.h"
#include "common/types/types.h"
#include "storage/buffer_manager/buffer_manager.h"
#include "storage/buffer_manager/memory_manager.h"
#include "storage/file_handle.h"
#include "storage/table/chunked_node_group.h"
#include "storage/table/column_chunk_data.h"

namespace kuzu {
namespace storage {

Spiller::Spiller(std::string tmpFilePath, BufferManager& bufferManager,
    common::VirtualFileSystem* vfs)
    : tmpFilePath{std::move(tmpFilePath)}, bufferManager{bufferManager}, vfs{vfs}, dataFH{nullptr} {
    // Clear the file if it already existed (e.g. from a previous run which
    // failed to clean up).
    vfs->removeFileIfExists(this->tmpFilePath);
}

FileHandle* Spiller::getOrCreateDataFH() const {
    if (dataFH.load()) {
        return dataFH;
    }
    std::unique_lock lock(fileCreationMutex);
    // Another thread may have created the file while the lock was being acquired
    if (dataFH.load()) {
        return dataFH;
    }
    const_cast<Spiller*>(this)->dataFH = bufferManager.getFileHandle(tmpFilePath,
        FileHandle::O_PERSISTENT_FILE_CREATE_NOT_EXISTS, vfs, nullptr);
    return dataFH;
}

FileHandle* Spiller::getDataFH() const {
    if (dataFH.load()) {
        return dataFH;
    }
    return nullptr;
}

void Spiller::addUnusedChunk(InMemChunkedNodeGroup* nodeGroup) {
    std::unique_lock lock(partitionerGroupsMtx);
    fullPartitionerGroups.insert(nodeGroup);
}

void Spiller::clearUnusedChunk(InMemChunkedNodeGroup* nodeGroup) {
    std::unique_lock lock(partitionerGroupsMtx);
    auto entry = fullPartitionerGroups.find(nodeGroup);
    if (entry != fullPartitionerGroups.end()) {
        fullPartitionerGroups.erase(entry);
    }
}

Spiller::~Spiller() {
    // This should be safe as long as the VFS is always using a local file system and the VFS is
    // destroyed after the buffer manager
    try {
        vfs->removeFileIfExists(this->tmpFilePath);
    } catch (common::IOException&) {} // NOLINT
}

SpillResult Spiller::spillToDisk(ColumnChunkData& chunk) const {
    auto& buffer = *chunk.buffer;
    KU_ASSERT(!buffer.evicted);
    auto dataFH = getOrCreateDataFH();
    auto pageSize = dataFH->getPageSize();
    auto numPages = (buffer.buffer.size_bytes() + pageSize - 1) / pageSize;
    auto startPage = dataFH->addNewPages(numPages);
    dataFH->writePagesToFile(buffer.buffer.data(), buffer.buffer.size_bytes(), startPage);
    return buffer.setSpilledToDisk(startPage * pageSize);
}

void Spiller::loadFromDisk(ColumnChunkData& chunk) const {
    auto& buffer = *chunk.buffer;
    if (buffer.evicted) {
        buffer.prepareLoadFromDisk();
        auto dataFH = getDataFH();
        KU_ASSERT(dataFH);
        dataFH->getFileInfo()->readFromFile(buffer.buffer.data(), buffer.buffer.size(),
            buffer.filePosition);
    }
}

SpillResult Spiller::claimNextGroup() {
    InMemChunkedNodeGroup* groupToFlush = nullptr;
    {
        std::unique_lock lock(partitionerGroupsMtx);
        if (!fullPartitionerGroups.empty()) {
            auto groupToFlushEntry = fullPartitionerGroups.begin();
            groupToFlush = *groupToFlushEntry;
            fullPartitionerGroups.erase(groupToFlushEntry);
        }
    }
    if (groupToFlush == nullptr) {
        return SpillResult{};
    }
    return groupToFlush->spillToDisk();
}

// NOLINTNEXTLINE(readability-make-member-function-const): Function shouldn't be re-ordered
void Spiller::clearFile() {
    auto curDataFH = getDataFH();
    if (curDataFH) {
        curDataFH->getFileInfo()->truncate(0);
    }
}

} // namespace storage
} // namespace kuzu
