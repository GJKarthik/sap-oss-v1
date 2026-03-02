#include "storage/optimistic_allocator.h"

/**
 * P2-126: Optimistic Allocator - Transaction-Aware Page Allocation
 * 
 * Purpose:
 * Provides optimistic page allocation with transaction semantics.
 * Tracks allocated pages during a transaction and supports rollback
 * to reclaim pages if the transaction fails.
 * 
 * Architecture:
 * ```
 * OptimisticAllocator : PageAllocator
 *   ├── pageManager: PageManager&           // Underlying page manager
 *   └── optimisticallyAllocatedPages: vector<PageRange>
 *         └── Tracks allocations for rollback
 * 
 * Inheritance:
 *   PageAllocator (base)
 *       ↳ OptimisticAllocator (transaction-aware)
 * ```
 * 
 * Transaction Flow:
 * ```
 * BEGIN TRANSACTION
 *   │
 *   ├── allocatePageRange(n)
 *   │     ├── pageManager.allocatePageRange(n)
 *   │     └── Track in optimisticallyAllocatedPages
 *   │
 *   ├── ... more allocations ...
 *   │
 *   └── COMMIT or ROLLBACK
 *         │
 *         ├── commit():
 *         │     └── Clear tracking list (allocations permanent)
 *         │
 *         └── rollback():
 *               ├── For each tracked PageRange:
 *               │     └── pageManager.freeImmediatelyRewritablePageRange()
 *               └── Clear tracking list
 * ```
 * 
 * Key Operations:
 * 
 * 1. allocatePageRange(numPages):
 *    - Delegates to pageManager.allocatePageRange()
 *    - Records PageRange in tracking list
 *    - Returns PageRange for caller to use
 * 
 * 2. freePageRange(block):
 *    - Direct pass-through to pageManager.freePageRange()
 *    - Does not affect tracking (explicit free)
 * 
 * 3. rollback():
 *    - Called when transaction fails
 *    - Iterates all tracked PageRanges
 *    - Frees each using freeImmediatelyRewritablePageRange()
 *    - Clears tracking list
 * 
 * 4. commit():
 *    - Called when transaction succeeds
 *    - Simply clears tracking list
 *    - Allocations become permanent
 * 
 * Use Cases:
 * - INSERT operations that may fail
 * - Bulk data loading with validation
 * - DDL operations (CREATE TABLE, etc.)
 * - Any operation requiring atomicity
 * 
 * Example:
 * ```cpp
 * OptimisticAllocator allocator(pageManager);
 * 
 * try {
 *     auto range1 = allocator.allocatePageRange(10);
 *     // Write data to pages...
 *     
 *     auto range2 = allocator.allocatePageRange(5);
 *     // Write more data...
 *     
 *     allocator.commit();  // Pages now permanent
 * } catch (...) {
 *     allocator.rollback(); // All pages freed
 * }
 * ```
 * 
 * Performance:
 * - allocatePageRange: O(1) + PageManager allocation
 * - rollback: O(n) where n = number of allocations
 * - commit: O(1) (just clears vector)
 * - Memory: sizeof(PageRange) * num_allocations
 */

#include "storage/page_manager.h"

namespace kuzu::storage {
OptimisticAllocator::OptimisticAllocator(PageManager& pageManager)
    : PageAllocator(pageManager.getDataFH()), pageManager(pageManager) {}

PageRange OptimisticAllocator::allocatePageRange(common::page_idx_t numPages) {
    auto pageRange = pageManager.allocatePageRange(numPages);
    if (numPages > 0) {
        optimisticallyAllocatedPages.push_back(pageRange);
    }
    return pageRange;
}

void OptimisticAllocator::freePageRange(PageRange block) {
    pageManager.freePageRange(block);
}

void OptimisticAllocator::rollback() {
    for (const auto& entry : optimisticallyAllocatedPages) {
        pageManager.freeImmediatelyRewritablePageRange(pageManager.getDataFH(), entry);
    }
    optimisticallyAllocatedPages.clear();
}

void OptimisticAllocator::commit() {
    optimisticallyAllocatedPages.clear();
}
} // namespace kuzu::storage
