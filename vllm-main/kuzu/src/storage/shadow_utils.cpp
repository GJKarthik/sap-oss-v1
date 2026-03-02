#include "storage/shadow_utils.h"

/**
 * P3-199: ShadowUtils - Shadow Page Management Utilities
 * 
 * Purpose:
 * Provides utility functions for shadow page operations during
 * checkpoint-based atomic updates. Abstracts the common patterns
 * of creating, reading, and updating shadow pages.
 * 
 * Architecture:
 * ```
 * ShadowPageAndFrame {
 *   originalPage: page_idx_t    // Page in main data file
 *   shadowPage: page_idx_t      // Page in shadow file
 *   frame: uint8_t*             // Pinned shadow frame
 * }
 * ```
 * 
 * createShadowVersionIfNecessaryAndPinPage() Flow:
 * ```
 * createShadowVersionIfNecessaryAndPinPage(originalPage, skipRead, fh, sf):
 *   hasShadow = shadowFile.hasShadowPage(fileIdx, originalPage)
 *   shadowPage = shadowFile.getOrCreateShadowPage(fileIdx, originalPage)
 *   
 *   IF hasShadow:
 *     frame = shadowFH.pinPage(shadowPage, READ_PAGE)
 *   ELSE:
 *     frame = shadowFH.pinPage(shadowPage, DONT_READ_PAGE)
 *     IF !skipRead:
 *       // Copy original page content to shadow
 *       fileHandle.optimisticReadPage(originalPage, [&](src) {
 *         memcpy(frame, src, KUZU_PAGE_SIZE)
 *       })
 *   
 *   shadowFH.setLockedPageDirty(shadowPage)
 *   RETURN {originalPage, shadowPage, frame}
 * ```
 * 
 * getFileHandleAndPhysicalPageIdxToPin() Logic:
 * ```
 * getFileHandleAndPhysicalPageIdxToPin(fh, pageIdx, sf, trxType):
 *   IF trxType == CHECKPOINT AND hasShadowPage:
 *     RETURN (shadowFH, shadowPageIdx)  // Read from shadow
 *   ELSE:
 *     RETURN (fileHandle, pageIdx)      // Read from main
 * ```
 * 
 * updatePage() Pattern:
 * ```
 * updatePage(fileHandle, originalPage, skipRead, shadowFile, updateOp):
 *   1. Create shadow version if needed
 *   2. Pin shadow page
 *   3. Execute updateOp(frame)
 *   4. Unpin shadow page
 * 
 * Exception safety: unpin on throw
 * ```
 * 
 * readShadowVersionOfPage() Pattern:
 * ```
 * readShadowVersionOfPage(fileHandle, originalPage, shadowFile, readOp):
 *   ASSERT shadow page exists
 *   shadowPage = getShadowPage()
 *   frame = pin(shadowPage, READ_PAGE)
 *   readOp(frame)
 *   unpin(shadowPage)
 * ```
 * 
 * Usage Patterns:
 * 
 * 1. Modify page during checkpoint:
 *    ```cpp
 *    ShadowUtils::updatePage(dataFH, pageIdx, false, shadowFile,
 *        [&](uint8_t* frame) { /* modify frame */ });
 *    ```
 * 
 * 2. Read page considering shadow:
 *    ```cpp
 *    auto [fh, idx] = ShadowUtils::getFileHandleAndPhysicalPageIdxToPin(
 *        dataFH, pageIdx, shadowFile, trxType);
 *    fh->readPage(idx, callback);
 *    ```
 * 
 * 3. Read shadow version directly:
 *    ```cpp
 *    ShadowUtils::readShadowVersionOfPage(dataFH, pageIdx, shadowFile,
 *        [&](uint8_t* frame) { /* read data */ });
 *    ```
 * 
 * Thread Safety:
 * - Single-threaded checkpoint assumed
 * - No concurrent shadow page access
 * 
 * Performance:
 * - Copy-on-write semantics (original page copied on first modify)
 * - Shadow pages reused within checkpoint
 * - Dirty tracking per shadow page
 */

#include "storage/file_handle.h"
#include "storage/shadow_file.h"
#include "transaction/transaction.h"

using namespace kuzu::common;

namespace kuzu {
namespace storage {

ShadowPageAndFrame ShadowUtils::createShadowVersionIfNecessaryAndPinPage(page_idx_t originalPage,
    bool skipReadingOriginalPage, FileHandle& fileHandle, ShadowFile& shadowFile) {
    KU_ASSERT(!fileHandle.isInMemoryMode());
    const auto hasShadowPage = shadowFile.hasShadowPage(fileHandle.getFileIndex(), originalPage);
    auto shadowPage = shadowFile.getOrCreateShadowPage(fileHandle.getFileIndex(), originalPage);
    uint8_t* shadowFrame = nullptr;
    try {
        if (hasShadowPage) {
            shadowFrame =
                shadowFile.getShadowingFH().pinPage(shadowPage, PageReadPolicy::READ_PAGE);
        } else {
            shadowFrame =
                shadowFile.getShadowingFH().pinPage(shadowPage, PageReadPolicy::DONT_READ_PAGE);
            if (!skipReadingOriginalPage) {
                fileHandle.optimisticReadPage(originalPage, [&](const uint8_t* frame) -> void {
                    memcpy(shadowFrame, frame, KUZU_PAGE_SIZE);
                });
            }
        }
        // The shadow page existing already does not mean that it's already dirty
        // It may have been flushed to disk to free memory and then read again
        shadowFile.getShadowingFH().setLockedPageDirty(shadowPage);
    } catch (Exception&) {
        throw;
    }
    return {originalPage, shadowPage, shadowFrame};
}

std::pair<FileHandle*, page_idx_t> ShadowUtils::getFileHandleAndPhysicalPageIdxToPin(
    FileHandle& fileHandle, page_idx_t pageIdx, const ShadowFile& shadowFile,
    transaction::TransactionType trxType) {
    if (trxType == transaction::TransactionType::CHECKPOINT &&
        shadowFile.hasShadowPage(fileHandle.getFileIndex(), pageIdx)) {
        return std::make_pair(&shadowFile.getShadowingFH(),
            shadowFile.getShadowPage(fileHandle.getFileIndex(), pageIdx));
    }
    return std::make_pair(&fileHandle, pageIdx);
}

void unpinShadowPage(page_idx_t originalPageIdx, page_idx_t shadowPageIdx,
    const ShadowFile& shadowFile) {
    KU_ASSERT(originalPageIdx != INVALID_PAGE_IDX && shadowPageIdx != INVALID_PAGE_IDX);
    KU_UNUSED(originalPageIdx);
    shadowFile.getShadowingFH().unpinPage(shadowPageIdx);
}

void ShadowUtils::updatePage(FileHandle& fileHandle, page_idx_t originalPageIdx,
    bool skipReadingOriginalPage, ShadowFile& shadowFile,
    const std::function<void(uint8_t*)>& updateOp) {
    KU_ASSERT(!fileHandle.isInMemoryMode());
    const auto shadowPageIdxAndFrame = createShadowVersionIfNecessaryAndPinPage(originalPageIdx,
        skipReadingOriginalPage, fileHandle, shadowFile);
    try {
        updateOp(shadowPageIdxAndFrame.frame);
    } catch (Exception&) {
        unpinShadowPage(shadowPageIdxAndFrame.originalPage, shadowPageIdxAndFrame.shadowPage,
            shadowFile);
        throw;
    }
    unpinShadowPage(shadowPageIdxAndFrame.originalPage, shadowPageIdxAndFrame.shadowPage,
        shadowFile);
}

void ShadowUtils::readShadowVersionOfPage(const FileHandle& fileHandle, page_idx_t originalPageIdx,
    const ShadowFile& shadowFile, const std::function<void(uint8_t*)>& readOp) {
    KU_ASSERT(!fileHandle.isInMemoryMode());
    KU_ASSERT(shadowFile.hasShadowPage(fileHandle.getFileIndex(), originalPageIdx));
    const page_idx_t shadowPageIdx =
        shadowFile.getShadowPage(fileHandle.getFileIndex(), originalPageIdx);
    const auto frame =
        shadowFile.getShadowingFH().pinPage(shadowPageIdx, PageReadPolicy::READ_PAGE);
    readOp(frame);
    unpinShadowPage(originalPageIdx, shadowPageIdx, shadowFile);
}

} // namespace storage
} // namespace kuzu
