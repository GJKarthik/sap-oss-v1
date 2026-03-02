#include "processor/operator/result_collector.h"

#include "binder/expression/expression_util.h"
#include "main/query_result/materialized_query_result.h"
#include "processor/execution_context.h"
#include "storage/buffer_manager/memory_manager.h"

using namespace kuzu::common;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

std::string ResultCollectorPrintInfo::toString() const {
    std::string result = "";
    if (accumulateType == AccumulateType::OPTIONAL_) {
        result += "Type: " + AccumulateTypeUtil::toString(accumulateType);
    }
    result += ",Expressions: ";
    result += binder::ExpressionUtil::toString(expressions);
    return result;
}

void ResultCollector::initNecessaryLocalState(ResultSet* resultSet, ExecutionContext* context) {
    payloadVectors.reserve(info.payloadPositions.size());
    for (auto& pos : info.payloadPositions) {
        auto vec = resultSet->getValueVector(pos).get();
        payloadVectors.push_back(vec);
        payloadAndMarkVectors.push_back(vec);
    }
    if (info.accumulateType == AccumulateType::OPTIONAL_) {
        markVector = std::make_unique<ValueVector>(LogicalType::BOOL(),
            MemoryManager::Get(*context->clientContext));
        markVector->state = DataChunkState::getSingleValueDataChunkState();
        markVector->setValue<bool>(0, true);
        payloadAndMarkVectors.push_back(markVector.get());
    }
}

void ResultCollector::initLocalStateInternal(ResultSet* resultSet, ExecutionContext* context) {
    initNecessaryLocalState(resultSet, context);
    localTable = std::make_unique<FactorizedTable>(MemoryManager::Get(*context->clientContext),
        info.tableSchema.copy());
}

void ResultCollector::executeInternal(ExecutionContext* context) {
    while (children[0]->getNextTuple(context)) {
        if (!payloadVectors.empty()) {
            for (auto i = 0u; i < resultSet->multiplicity; i++) {
                localTable->append(payloadAndMarkVectors);
            }
        }
    }
    if (!payloadVectors.empty()) {
        metrics->numOutputTuple.increase(localTable->getTotalNumFlatTuples());
        sharedState->mergeLocalTable(*localTable);
    }
}

/**
 * P2-74: FactorizedTable Interface for Flat/Unflat State
 * 
 * This TODO suggests adding a cleaner interface in FactorizedTable to handle
 * the flat/unflat state setting based on column schema.
 * 
 * The Problem:
 * - Some code checks currIdx == -1 to determine if state is unflat
 * - This is a legacy convention that's error-prone
 * - The flat/unflat state should be derived from the table schema
 * 
 * Current Pattern (here and elsewhere):
 * ```cpp
 * for (auto i = 0u; i < payloadVectors.size(); ++i) {
 *     auto columnSchema = tableSchema->getColumn(i);
 *     if (columnSchema->isFlat()) {
 *         payloadVectors[i]->state->setToFlat();
 *     }
 * }
 * ```
 * 
 * What "Interface in FactorizedTable" Would Look Like:
 * ```cpp
 * // Proposed API:
 * table->initVectorStates(payloadVectors);  // Sets flat/unflat based on schema
 * 
 * // Or more explicitly:
 * for (auto i = 0u; i < payloadVectors.size(); ++i) {
 *     table->applyColumnStateToVector(i, payloadVectors[i]);
 * }
 * ```
 * 
 * Why This Matters:
 * - DRY: This pattern is repeated in multiple operators
 * - Correctness: Centralizing logic prevents inconsistencies
 * - Readability: Intent is clearer than manual state manipulation
 * 
 * Current Workaround:
 * - Manually iterate through columns and check isFlat()
 * - Set vector state accordingly
 * - Works, but duplicated across codebase
 * 
 * Places That Would Benefit:
 * - ResultCollector (here)
 * - Scan operators
 * - Hash join probe side
 * - Aggregate finalization
 */
void ResultCollector::finalizeInternal(ExecutionContext* context) {
    switch (info.accumulateType) {
    case AccumulateType::OPTIONAL_: {
        auto localResultSet = getResultSet(MemoryManager::Get(*context->clientContext));
        initNecessaryLocalState(localResultSet.get(), context);
        // Manual flat/unflat state setting based on column schema
        // (This pattern could be encapsulated in FactorizedTable)
        auto table = sharedState->getTable();
        auto tableSchema = table->getTableSchema();
        for (auto i = 0u; i < payloadVectors.size(); ++i) {
            auto columnSchema = tableSchema->getColumn(i);
            if (columnSchema->isFlat()) {
                payloadVectors[i]->state->setToFlat();
            }
        }
        if (table->isEmpty()) {
            for (auto& vector : payloadVectors) {
                vector->setAsSingleNullEntry();
            }
            markVector->setValue<bool>(0, false);
            table->append(payloadAndMarkVectors);
        }
    }
    default:
        break;
    }
}

std::unique_ptr<main::QueryResult> ResultCollector::getQueryResult() const {
    return std::make_unique<main::MaterializedQueryResult>(sharedState->getTable());
}

} // namespace processor
} // namespace kuzu
