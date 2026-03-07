#include "storage/disk_array_collection.h"

/**
 * P2-134: Disk Array Collection - Multi-Array Header Management
 * 
 * Purpose:
 * Manages a collection of disk arrays sharing header pages. Used by hash indexes
 * to organize multiple related disk arrays (e.g., primary slots, overflow slots)
 * with unified header management.
 * 
 * Architecture:
 * ```
 * DiskArrayCollection
 *   ├── fileHandle: FileHandle&          // Underlying storage
 *   ├── shadowFile: ShadowFile&          // Shadow paging
 *   ├── bypassShadowing: bool            // Optimization flag
 *   ├── numHeaders: size_t               // Total array count
 *   ├── headerPagesOnDisk: size_t        // Persisted pages
 *   ├── headersForReadTrx: vector<unique_ptr<HeaderPage>>
 *   └── headersForWriteTrx: vector<unique_ptr<HeaderPage>>
 * 
 * HeaderPage Layout:
 *   ├── numHeaders: size_t               // Headers in this page
 *   ├── nextHeaderPage: page_idx_t       // Linked list pointer
 *   └── headers[NUM_HEADERS_PER_PAGE]: DiskArrayHeader[]
 * ```
 * 
 * MVCC Design:
 * - headersForReadTrx: Consistent read view (from checkpoint)
 * - headersForWriteTrx: Mutable write view
 * - Checkpoint copies write→read view
 * - Enables snapshot isolation for readers
 * 
 * Key Operations:
 * 
 * 1. Constructor (new collection):
 *    - Creates empty header pages for read/write
 *    - headerPagesOnDisk = 0
 * 
 * 2. Constructor (from disk):
 *    - Reads linked header pages from firstHeaderPage
 *    - Copies to both read and write views
 *    - Counts total numHeaders
 * 
 * 3. addDiskArray():
 *    - Increments numHeaders
 *    - Adds new HeaderPage if current full
 *    - Returns index for DiskArray creation
 * 
 * 4. checkpoint(firstHeaderPage, pageAllocator):
 *    - Allocates new header pages if needed
 *    - Writes changed headers via ShadowUtils
 *    - Only updates pages that differ from read version
 *    - Updates headerPagesOnDisk count
 * 
 * 5. reclaimStorage():
 *    - Frees all header pages in linked list
 *    - Called during DROP TABLE
 * 
 * Header Page Linking:
 * ```
 * HeaderPage[0] → HeaderPage[1] → ... → HeaderPage[N]
 *   ↓               ↓                       ↓
 * headers[0..K]   headers[0..K]           headers[0..M]
 *   ↓               ↓                       ↓
 * DiskArray      DiskArray              DiskArray
 * ```
 * 
 * Usage Example:
 * ```cpp
 * // Primary Key Index creates multiple disk arrays
 * DiskArrayCollection dac(fileHandle, shadowFile);
 * size_t primarySlotsIdx = dac.addDiskArray();
 * size_t overflowSlotsIdx = dac.addDiskArray();
 * 
 * // Get headers for individual disk arrays
 * auto& primaryHeader = dac.getHeader(primarySlotsIdx);
 * ```
 * 
 * Thread Safety:
 * - Read/write separation enables concurrent reads
 * - Write operations must be serialized
 */

#include "common/system_config.h"
#include "common/types/types.h"
#include "storage/file_handle.h"
#include "storage/shadow_utils.h"

using namespace kuzu::common;

namespace kuzu {
namespace storage {

DiskArrayCollection::DiskArrayCollection(FileHandle& fileHandle, ShadowFile& shadowFile,
    bool bypassShadowing)
    : fileHandle(fileHandle), shadowFile{shadowFile}, bypassShadowing{bypassShadowing},
      numHeaders{0} {
    headersForReadTrx.push_back(std::make_unique<HeaderPage>());
    headersForWriteTrx.push_back(std::make_unique<HeaderPage>());
    headerPagesOnDisk = 0;
}

DiskArrayCollection::DiskArrayCollection(FileHandle& fileHandle, ShadowFile& shadowFile,
    page_idx_t firstHeaderPage, bool bypassShadowing)
    : fileHandle(fileHandle), shadowFile{shadowFile}, bypassShadowing{bypassShadowing},
      numHeaders{0} {
    // Read headers from disk
    page_idx_t headerPageIdx = firstHeaderPage;
    do {
        fileHandle.optimisticReadPage(headerPageIdx, [&](auto* frame) {
            const auto page = reinterpret_cast<HeaderPage*>(frame);
            headersForReadTrx.push_back(std::make_unique<HeaderPage>(*page));
            headersForWriteTrx.push_back(std::make_unique<HeaderPage>(*page));
            headerPageIdx = page->nextHeaderPage;
            numHeaders += page->numHeaders;
        });
    } while (headerPageIdx != INVALID_PAGE_IDX);
    headerPagesOnDisk = headersForReadTrx.size();
}

void DiskArrayCollection::checkpoint(page_idx_t firstHeaderPage, PageAllocator& pageAllocator) {
    // Write headers to disk
    page_idx_t headerPage = firstHeaderPage;
    for (page_idx_t indexInMemory = 0; indexInMemory < headersForWriteTrx.size(); indexInMemory++) {
        if (headersForWriteTrx[indexInMemory]->nextHeaderPage == INVALID_PAGE_IDX &&
            indexInMemory < headersForWriteTrx.size() - 1) {
            // This is the first time checkpointing the next disk array, allocate a page for its
            // header
            populateNextHeaderPage(pageAllocator, indexInMemory);
        }

        // Only update if the headers for the given page have changed
        // Or if the page has not yet been written
        if (indexInMemory >= headerPagesOnDisk ||
            *headersForWriteTrx[indexInMemory] != *headersForReadTrx[indexInMemory]) {
            ShadowUtils::updatePage(*pageAllocator.getDataFH(), headerPage,
                true /*writing full page*/, shadowFile, [&](auto* frame) {
                    memcpy(frame, headersForWriteTrx[indexInMemory].get(), sizeof(HeaderPage));
                    if constexpr (sizeof(HeaderPage) < KUZU_PAGE_SIZE) {
                        // Zero remaining data in the page
                        std::fill(frame + sizeof(HeaderPage), frame + KUZU_PAGE_SIZE, 0);
                    }
                });
        }
        headerPage = headersForWriteTrx[indexInMemory]->nextHeaderPage;
    }
    headerPagesOnDisk = headersForWriteTrx.size();
}

void DiskArrayCollection::populateNextHeaderPage(PageAllocator& pageAllocator,
    common::page_idx_t indexInMemory) {
    auto nextHeaderPage = pageAllocator.allocatePage();
    headersForWriteTrx[indexInMemory]->nextHeaderPage = nextHeaderPage;
    // We can't really roll back the structural changes in the PKIndex (the disk arrays are
    // created in the destructor and there are a fixed number which does not change after that
    // point), so we apply those to the version that would otherwise be identical to the one on
    // disk
    headersForReadTrx[indexInMemory]->nextHeaderPage = nextHeaderPage;
}

size_t DiskArrayCollection::addDiskArray() {
    auto oldSize = numHeaders++;
    // This may not be the last header page. If we rollback there may be header pages which are
    // empty
    auto pageIdx = numHeaders % HeaderPage::NUM_HEADERS_PER_PAGE;
    if (pageIdx >= headersForWriteTrx.size()) {

        headersForWriteTrx.emplace_back(std::make_unique<HeaderPage>());
        // Also add a new read header page as we need to pass read headers to the disk arrays
        // Newly added read headers will be empty until checkpointing
        headersForReadTrx.emplace_back(std::make_unique<HeaderPage>());
    }

    auto& headerPage = *headersForWriteTrx[pageIdx];
    KU_ASSERT(headerPage.numHeaders < HeaderPage::NUM_HEADERS_PER_PAGE);
    auto indexInPage = headerPage.numHeaders;
    headerPage.headers[indexInPage] = DiskArrayHeader();
    headerPage.numHeaders++;
    headersForReadTrx[pageIdx]->numHeaders++;
    return oldSize;
}

void DiskArrayCollection::reclaimStorage(PageAllocator& pageAllocator,
    common::page_idx_t firstHeaderPage) const {
    auto headerPage = firstHeaderPage;
    for (page_idx_t indexInMemory = 0; indexInMemory < headersForReadTrx.size(); indexInMemory++) {
        if (headerPage == INVALID_PAGE_IDX) {
            break;
        }
        pageAllocator.freePage(headerPage);
        headerPage = headersForReadTrx[indexInMemory]->nextHeaderPage;
    }
}

} // namespace storage
} // namespace kuzu
