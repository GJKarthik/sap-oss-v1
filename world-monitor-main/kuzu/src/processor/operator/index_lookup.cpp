#include "processor/operator/index_lookup.h"

#include "binder/expression/expression_util.h"
#include "common/assert.h"
#include "common/exception/message.h"
#include "common/types/types.h"
#include "common/utils.h"
#include "common/vector/value_vector.h"
#include "processor/warning_context.h"
#include "storage/index/hash_index.h"
#include "storage/table/node_table.h"

using namespace kuzu::common;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

namespace {

std::optional<WarningSourceData> getWarningSourceData(
    const std::vector<ValueVector*>& warningDataVectors, sel_t pos) {
    std::optional<WarningSourceData> ret;
    if (!warningDataVectors.empty()) {
        ret.emplace(WarningSourceData::constructFromData(warningDataVectors,
            safeIntegerConversion<idx_t>(pos)));
    }
    return ret;
}

/**
 * P2-73: Index Lookup Unfiltered Optimization
 * 
 * This TODO and the one below suggest adding a "short path" for unfiltered cases.
 * 
 * Current Approach:
 * - Always iterate through selection vector positions
 * - For each position, check if key is null
 * - This adds indirection even when all positions are valid
 * 
 * What "Unfiltered Short Path" Means:
 * When the selection vector is unfiltered (sequential 0,1,2,...,N-1), we can:
 * - Skip selection vector lookups
 * - Use direct array indexing
 * - Potentially use SIMD for batch null checks
 * 
 * Performance Comparison:
 * ```
 * Filtered:   for (i < numKeys) pos = selVector[i]; keyVector[pos]
 * Unfiltered: for (i < numKeys) keyVector[i]  // Direct access
 * ```
 * 
 * Why This Matters for Index Lookup:
 * - During COPY FROM, keys are often dense/sequential
 * - Bulk imports hit this code path frequently
 * - Small overhead per-key adds up over millions of rows
 * 
 * Implementation Would Look Like:
 * ```cpp
 * if (keyVector->state->getSelVector().isUnfiltered()) {
 *     // Fast path: direct iteration
 *     for (auto i = 0u; i < numKeys; i++) {
 *         if (!keyVector->isNull(i)) { ... }
 *     }
 * } else {
 *     // Current path with selection vector
 * }
 * ```
 * 
 * Also Applies To:
 * - fillOffsetArraysFromVector() below (same TODO)
 * - Other batch operations on dense data
 */
bool checkNullKey(ValueVector* keyVector, offset_t vectorOffset,
    BatchInsertErrorHandler* errorHandler, const std::vector<ValueVector*>& warningDataVectors) {
    bool isNull = keyVector->isNull(vectorOffset);
    if (isNull) {
        errorHandler->handleError(ExceptionMessage::nullPKException(),
            getWarningSourceData(warningDataVectors, vectorOffset));
    }
    return !isNull;
}

struct OffsetVectorManager {
    OffsetVectorManager(ValueVector* resultVector, BatchInsertErrorHandler* errorHandler)
        : ignoreErrors(errorHandler->getIgnoreErrors()), resultVector(resultVector),
          insertOffset(0) {
        // if we are ignoring errors we may need to filter the output sel vector
        if (ignoreErrors) {
            resultVector->state->getSelVectorUnsafe().setToFiltered();
        }
    }

    ~OffsetVectorManager() {
        if (ignoreErrors) {
            resultVector->state->getSelVectorUnsafe().setSelSize(insertOffset);
        }
    }

    void insertEntry(offset_t entry, sel_t posInKeyVector) {
        auto* offsets = reinterpret_cast<offset_t*>(resultVector->getData());
        offsets[posInKeyVector] = entry;
        if (ignoreErrors) {
            // if the lookup was successful we may add the current entry to the output selection
            resultVector->state->getSelVectorUnsafe()[insertOffset] = posInKeyVector;
        }
        ++insertOffset;
    }

    bool ignoreErrors;
    ValueVector* resultVector;

    offset_t insertOffset;
};

// Unfiltered optimization also applies here (see P2-73 comment above)
template<bool hasNoNullsGuarantee>
void fillOffsetArraysFromVector(transaction::Transaction* transaction, const IndexLookupInfo& info,
    ValueVector* keyVector, ValueVector* resultVector,
    const std::vector<ValueVector*>& warningDataVectors, BatchInsertErrorHandler* errorHandler) {
    KU_ASSERT(resultVector->dataType.getPhysicalType() == PhysicalTypeID::INT64);
    TypeUtils::visit(
        keyVector->dataType.getPhysicalType(),
        [&]<IndexHashable T>(T) {
            auto numKeys = keyVector->state->getSelVector().getSelSize();

            // fetch all the selection pos at the start
            // since we may modify the selection vector in the middle of the lookup
            std::vector<sel_t> lookupPos(numKeys);
            for (idx_t i = 0; i < numKeys; ++i) {
                lookupPos[i] = (keyVector->state->getSelVector()[i]);
            }

            OffsetVectorManager resultManager{resultVector, errorHandler};
            for (auto i = 0u; i < numKeys; i++) {
                auto pos = lookupPos[i];
                if constexpr (!hasNoNullsGuarantee) {
                    if (!checkNullKey(keyVector, pos, errorHandler, warningDataVectors)) {
                        continue;
                    }
                }
                offset_t lookupOffset = 0;
                if (!info.nodeTable->lookupPK(transaction, keyVector, pos, lookupOffset)) {
                    TypeUtils::visit(keyVector->dataType, [&]<typename type>(type) {
                        errorHandler->handleError(
                            ExceptionMessage::nonExistentPKException(
                                TypeUtils::toString(keyVector->getValue<type>(pos), keyVector)),
                            getWarningSourceData(warningDataVectors, pos));
                    });
                } else {
                    resultManager.insertEntry(lookupOffset, pos);
                }
            }
        },
        [&](auto) { KU_UNREACHABLE; });
}
} // namespace

std::string IndexLookupPrintInfo::toString() const {
    std::string result = "Indexes: ";
    result += binder::ExpressionUtil::toString(expressions);
    return result;
}

bool IndexLookup::getNextTuplesInternal(ExecutionContext* context) {
    if (!children[0]->getNextTuple(context)) {
        return false;
    }
    for (auto& info : infos) {
        info.keyEvaluator->evaluate();
        lookup(transaction::Transaction::Get(*context->clientContext), info);
    }
    localState->errorHandler->flushStoredErrors();
    return true;
}

void IndexLookup::initLocalStateInternal(ResultSet* resultSet, ExecutionContext* context) {
    auto errorHandler = std::make_unique<BatchInsertErrorHandler>(context,
        WarningContext::Get(*context->clientContext)->getIgnoreErrorsOption());
    localState = std::make_unique<IndexLookupLocalState>(std::move(errorHandler));
    for (auto& pos : warningDataVectorPos) {
        localState->warningDataVectors.push_back(resultSet->getValueVector(pos).get());
    }
    for (auto& info : infos) {
        info.keyEvaluator->init(*resultSet, context->clientContext);
    }
}

void IndexLookup::lookup(transaction::Transaction* transaction, const IndexLookupInfo& info) {
    auto keyVector = info.keyEvaluator->resultVector.get();
    auto resultVector = resultSet->getValueVector(info.resultVectorPos).get();

    if (keyVector->hasNoNullsGuarantee()) {
        fillOffsetArraysFromVector<true>(transaction, info, keyVector, resultVector,
            localState->warningDataVectors, localState->errorHandler.get());
    } else {
        fillOffsetArraysFromVector<false>(transaction, info, keyVector, resultVector,
            localState->warningDataVectors, localState->errorHandler.get());
    }
}

} // namespace processor
} // namespace kuzu
