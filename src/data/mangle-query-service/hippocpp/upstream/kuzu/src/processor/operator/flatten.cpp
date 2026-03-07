#include "processor/operator/flatten.h"

#include "common/metric.h"

using namespace kuzu::common;

namespace kuzu {
namespace processor {

void Flatten::initLocalStateInternal(ResultSet* resultSet, ExecutionContext* /*context*/) {
    dataChunkState = resultSet->dataChunks[dataChunkToFlattenPos]->state.get();
    currentSelVector->setToFiltered(1 /* size */);
    localState = std::make_unique<FlattenLocalState>();
}

/**
 * P2-71: Flatten Operator State Save/Restore Design
 * 
 * This TODO notes that setToUnflat() should be part of the restore/save mechanism,
 * not a separate manual call.
 * 
 * What Flatten Does:
 * Takes an unflat (multi-row) data chunk and emits it one row at a time (flat).
 * This is needed when downstream operators require flat input.
 * 
 * State Machine:
 * ```
 * ┌──────────────────────────────────────────────────────┐
 * │ Initial: Unflat chunk from child (N rows)           │
 * │                                                      │
 * │ 1. Save selection vector                             │
 * │ 2. Set state to FLAT                                 │
 * │ 3. Emit row 0, row 1, ..., row N-1                  │
 * │ 4. When exhausted:                                   │
 * │    a. Set state back to UNFLAT  <-- TODO is here     │
 * │    b. Restore selection vector                       │
 * │    c. Get next chunk from child                      │
 * └──────────────────────────────────────────────────────┘
 * ```
 * 
 * Why setToUnflat Is Separate From Restore:
 * - restoreSelVector() only restores the selection vector
 * - But the chunk also has flat/unflat state
 * - These are conceptually linked but implemented separately
 * 
 * What "Part of Restore/Save" Would Mean:
 * ```cpp
 * // Current (separate calls):
 * dataChunkState->setToUnflat();
 * restoreSelVector(*dataChunkState);
 * 
 * // Ideal (combined):
 * restoreDataChunkState(*dataChunkState);  // Handles both
 * ```
 * 
 * Why Current Approach Works:
 * - Both calls are always paired
 * - Order is important: unflat first, then restore
 * - Explicit is better for debugging
 * 
 * Potential Refactoring:
 * 1. Create saveState() that saves both flat/unflat + selVector
 * 2. Create restoreState() that restores both
 * 3. Use RAII pattern with StateGuard class
 * 
 * Performance Impact: None (just a flag flip)
 */
bool Flatten::getNextTuplesInternal(ExecutionContext* context) {
    if (localState->currentIdx == localState->sizeToFlatten) {
        // Restore unflat state before getting next chunk from child
        // Note: setToUnflat() could be combined with restoreSelVector()
        dataChunkState->setToUnflat();
        restoreSelVector(*dataChunkState);
        if (!children[0]->getNextTuple(context)) {
            return false;
        }
        localState->currentIdx = 0;
        localState->sizeToFlatten = dataChunkState->getSelVector().getSelSize();
        saveSelVector(*dataChunkState);
        dataChunkState->setToFlat();
    }
    sel_t selPos = prevSelVector->operator[](localState->currentIdx++);
    currentSelVector->operator[](0) = selPos;
    metrics->numOutputTuple.incrementByOne();
    return true;
}

void Flatten::resetCurrentSelVector(const SelectionVector&) {}

} // namespace processor
} // namespace kuzu
