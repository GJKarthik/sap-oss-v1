#include "processor/operator/order_by/order_by_merge.h"

#include <thread>

#include "common/constants.h"
#include "processor/execution_context.h"
#include "storage/buffer_manager/memory_manager.h"

using namespace kuzu::common;

namespace kuzu {
namespace processor {

void OrderByMerge::initLocalStateInternal(ResultSet* /*resultSet*/, ExecutionContext* /*context*/) {
    // OrderByMerge is the only sink operator in a pipeline and only modifies the
    // sharedState by merging sortedKeyBlocks, So we don't need to initialize the resultSet.
    localMerger = make_unique<KeyBlockMerger>(sharedState->getPayloadTables(),
        sharedState->getStrKeyColInfo(), sharedState->getNumBytesPerTuple());
}

void OrderByMerge::executeInternal(ExecutionContext* /*context*/) {
    while (!sharedDispatcher->isDoneMerge()) {
        auto keyBlockMergeMorsel = sharedDispatcher->getMorsel();
        if (keyBlockMergeMorsel == nullptr) {
            std::this_thread::sleep_for(
                std::chrono::microseconds(THREAD_SLEEP_TIME_WHEN_WAITING_IN_MICROS));
            continue;
        }
        localMerger->mergeKeyBlocks(*keyBlockMergeMorsel);
        sharedDispatcher->doneMorsel(std::move(keyBlockMergeMorsel));
    }
}

/**
 * P2-85: Direct SharedState Feed to Merger/Dispatcher
 * 
 * This TODO suggests passing sharedState directly instead of extracting individual
 * components and passing them separately.
 * 
 * Current Approach:
 * ```cpp
 * sharedDispatcher->init(memManager,
 *     sharedState->getSortedKeyBlocks(),    // Extracted
 *     sharedState->getPayloadTables(),      // Extracted
 *     sharedState->getStrKeyColInfo(),      // Extracted
 *     sharedState->getNumBytesPerTuple());  // Extracted
 * ```
 * 
 * Proposed Cleaner Approach:
 * ```cpp
 * sharedDispatcher->init(memManager, sharedState);
 * // Dispatcher extracts what it needs internally
 * ```
 * 
 * Benefits of Direct Feed:
 * | Benefit | Description |
 * |---------|-------------|
 * | Simpler interface | One parameter vs four |
 * | Encapsulation | Dispatcher accesses what it needs |
 * | Flexibility | Can access more state if needed |
 * | Less coupling | Caller doesn't know internal needs |
 * 
 * Why Current Approach Exists:
 * - Historical: init() was written before sharedState was fully designed
 * - Explicit: clearly shows exactly what dispatcher needs
 * - No dependency on sharedState class in dispatcher
 * 
 * Trade-offs:
 * - Current: More verbose but explicit dependencies
 * - Direct feed: Cleaner API but hides dependencies
 * 
 * Current Status:
 * Works correctly. Refactoring would be a minor API improvement.
 */
void OrderByMerge::initGlobalStateInternal(ExecutionContext* context) {
    // Passes extracted components from sharedState; see P2-85 for refactor suggestion
    sharedDispatcher->init(storage::MemoryManager::Get(*context->clientContext),
        sharedState->getSortedKeyBlocks(), sharedState->getPayloadTables(),
        sharedState->getStrKeyColInfo(), sharedState->getNumBytesPerTuple());
}

} // namespace processor
} // namespace kuzu
