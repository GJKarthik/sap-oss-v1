#include "storage/page_manager.h"

/**
 * P3-192: PageManager - Extended Documentation
 * 
 * Additional Details (see P2-133 for base documentation)
 * 
 * Allocation Algorithm:
 * ```
 * allocatePageRange(numPages):
 *   IF ENABLE_FSM:
 *     LOCK mtx
 *     allocated = freeSpaceManager.popFreePages(numPages)
 *     IF allocated.has_value():
 *       ++version
 *       RETURN PageRange{allocated}
 *   
 *   startIdx = fileHandle.addNewPages(numPages)
 *   RETURN PageRange{startIdx, numPages}
 * ```
 * 
 * Free Page States:
 * ```
 * | State | Description | Reusable |
 * |-------|-------------|----------|
 * | ALLOCATED | Currently in use | No |
 * | UNCHECKPOINTED | Freed but not checkpointed | No |
 * | FREE | Available after checkpoint | Yes |
 * ```
 * 
 * Deferred Free vs Immediate Free:
 * ```
 * freePageRange():
 *   - Pages go to UNCHECKPOINTED
 *   - Safe: checkpoint recovery works
 *   - Slower: must wait for checkpoint
 * 
 * freeImmediatelyRewritablePageRange():
 *   - Pages go directly to FREE
 *   - Used during rollback (no recovery needed)
 *   - Evicts from buffer manager first
 * ```
 * 
 * Checkpoint Integration Flow:
 * ```
 * 1. serialize() - Write FSM state to disk
 * 2. [Checkpoint completes]
 * 3. finalizeCheckpoint() - Move UNCHECKPOINTED → FREE
 * 4. clearEvictedBMEntriesIfNeeded() - Cleanup buffer manager
 * 5. resetVersion() - Clear change flag
 * ```
 * 
 * Version Change Detection:
 * ```
 * changedSinceLastCheckpoint():
 *   RETURN version != lastCheckpointVersion
 * 
 * resetVersion():
 *   lastCheckpointVersion = version
 * ```
 * 
 * ENABLE_FSM Flag:
 * - true: Use FreeSpaceManager for page reuse
 * - false: Always expand file (debugging/testing)
 * 
 * ====================================
 * 
 * P2-133: Page Manager - Page Allocation with Free Space Management
 * 
 * Purpose:
 * High-level page allocation manager that integrates with FreeSpaceManager
 * to efficiently allocate and recycle pages. Handles both fresh allocation
 * and reuse of freed pages.
 * 
 * Architecture:
 * ```
 * PageManager
 *   ├── fileHandle: FileHandle*            // Underlying file
 *   ├── freeSpaceManager: unique_ptr<FreeSpaceManager>
 *   ├── mtx: mutex                         // Thread safety
 *   └── version: atomic<uint64_t>          // Change tracking
 * 
 * Allocation Flow:
 *   allocatePageRange(n)
 *         │
 *         ├── Try FSM.popFreePages(n)
 *         │     └── Reuse freed pages if available
 *         │
 *         └── If no free pages:
 *               fileHandle.addNewPages(n)
 * ```
 * 
 * Key Operations:
 * 
 * 1. allocatePageRange(numPages):
 *    - First try FreeSpaceManager for reusable pages
 *    - Falls back to expanding file if no free pages
 *    - Returns PageRange{startPageIdx, numPages}
 *    - Increments version on FSM allocation
 * 
 * 2. freePageRange(entry):
 *    - Marks pages for deferred reuse
 *    - addUncheckpointedFreePages() - NOT immediately reusable
 *    - Pages become available after next checkpoint
 *    - Ensures checkpoint recovery safety
 * 
 * 3. freeImmediatelyRewritablePageRange(fileHandle, entry):
 *    - For transaction rollback scenarios
 *    - evictAndAddFreePages() - immediately reusable
 *    - Evicts from buffer manager first
 * 
 * Free Page Lifecycle:
 * ```
 * ALLOCATED → freePageRange() → UNCHECKPOINTED
 *                                    │
 *                            [checkpoint]
 *                                    ↓
 *                              FREE (reusable)
 *                                    │
 *                            allocatePageRange()
 *                                    ↓
 *                              ALLOCATED
 * ```
 * 
 * Checkpoint Integration:
 * - serialize(): Save FSM state for persistence
 * - deserialize(): Restore FSM state on recovery
 * - finalizeCheckpoint(): Move uncheckpointed to free
 * - clearEvictedBMEntriesIfNeeded(): Cleanup buffer manager
 * 
 * Version Tracking:
 * - version increments on any allocation/free
 * - changedSinceLastCheckpoint() checks if version changed
 * - resetVersion() after successful checkpoint
 * 
 * Static Access:
 * ```cpp
 * PageManager* pm = PageManager::Get(clientContext);
 * ```
 * 
 * Thread Safety:
 * - Mutex-protected allocation/free operations
 * - Version is atomic for concurrent reads
 * 
 * Feature Flag:
 * - ENABLE_FSM = true (default)
 * - When false: all allocations expand file
 */

#include "common/uniq_lock.h"
#include "storage/file_handle.h"
#include "storage/storage_manager.h"

namespace kuzu::storage {
static constexpr bool ENABLE_FSM = true;

PageRange PageManager::allocatePageRange(common::page_idx_t numPages) {
    if constexpr (ENABLE_FSM) {
        common::UniqLock lck{mtx};
        auto allocatedFreeChunk = freeSpaceManager->popFreePages(numPages);
        if (allocatedFreeChunk.has_value()) {
            ++version;
            return {*allocatedFreeChunk};
        }
    }
    auto startPageIdx = fileHandle->addNewPages(numPages);
    KU_ASSERT(fileHandle->getNumPages() >= startPageIdx + numPages);
    return PageRange(startPageIdx, numPages);
}

void PageManager::freePageRange(PageRange entry) {
    if constexpr (ENABLE_FSM) {
        common::UniqLock lck{mtx};
        // Freed pages cannot be immediately reused to ensure checkpoint recovery works
        // Instead they are reusable after the end of the next checkpoint
        freeSpaceManager->addUncheckpointedFreePages(entry);
        ++version;
    }
}

common::page_idx_t PageManager::estimatePagesNeededForSerialize() {
    return freeSpaceManager->getMaxNumPagesForSerialization();
}

void PageManager::freeImmediatelyRewritablePageRange(FileHandle* fileHandle, PageRange entry) {
    if constexpr (ENABLE_FSM) {
        common::UniqLock lck{mtx};
        freeSpaceManager->evictAndAddFreePages(fileHandle, entry);
        ++version;
    }
}

void PageManager::serialize(common::Serializer& serializer) {
    freeSpaceManager->serialize(serializer);
}

void PageManager::deserialize(common::Deserializer& deSer) {
    freeSpaceManager->deserialize(deSer);
}

void PageManager::finalizeCheckpoint() {
    freeSpaceManager->finalizeCheckpoint(fileHandle);
}

void PageManager::clearEvictedBMEntriesIfNeeded(BufferManager* bufferManager) {
    freeSpaceManager->clearEvictedBufferManagerEntriesIfNeeded(bufferManager);
}

PageManager* PageManager::Get(const main::ClientContext& context) {
    return StorageManager::Get(context)->getDataFH()->getPageManager();
}

} // namespace kuzu::storage
