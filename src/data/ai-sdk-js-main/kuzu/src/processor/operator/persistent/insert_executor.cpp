#include "processor/operator/persistent/insert_executor.h"

#include "transaction/transaction.h"

using namespace kuzu::common;
using namespace kuzu::transaction;

namespace kuzu {
namespace processor {

void NodeInsertInfo::init(const ResultSet& resultSet) {
    nodeIDVector = resultSet.getValueVector(nodeIDPos).get();
    for (auto& pos : columnsPos) {
        if (pos.isValid()) {
            columnVectors.push_back(resultSet.getValueVector(pos).get());
        } else {
            columnVectors.push_back(nullptr);
        }
    }
}

void NodeInsertInfo::updateNodeID(nodeID_t nodeID) const {
    KU_ASSERT(nodeIDVector->state->getSelVector().getSelSize() == 1);
    auto pos = nodeIDVector->state->getSelVector()[0];
    nodeIDVector->setNull(pos, false);
    nodeIDVector->setValue<nodeID_t>(pos, nodeID);
}

nodeID_t NodeInsertInfo::getNodeID() const {
    auto& nodeIDSelVector = nodeIDVector->state->getSelVector();
    KU_ASSERT(nodeIDSelVector.getSelSize() == 1);
    if (nodeIDVector->isNull(nodeIDSelVector[0])) {
        return {INVALID_OFFSET, INVALID_TABLE_ID};
    }
    return nodeIDVector->getValue<nodeID_t>(nodeIDSelVector[0]);
}

void NodeTableInsertInfo::init(const ResultSet& resultSet, main::ClientContext* context) {
    for (auto& evaluator : columnDataEvaluators) {
        evaluator->init(resultSet, context);
        columnDataVectors.push_back(evaluator->resultVector.get());
    }
    pkVector = columnDataVectors[table->getPKColumnID()];
}

void NodeInsertExecutor::init(ResultSet* resultSet, const ExecutionContext* context) {
    info.init(*resultSet);
    tableInfo.init(*resultSet, context->clientContext);
}

static void writeColumnVector(ValueVector* columnVector, const ValueVector* dataVector) {
    auto& columnSelVector = columnVector->state->getSelVector();
    auto& dataSelVector = dataVector->state->getSelVector();
    KU_ASSERT(columnSelVector.getSelSize() == 1 && dataSelVector.getSelSize() == 1);
    auto columnPos = columnSelVector[0];
    auto dataPos = dataSelVector[0];
    if (dataVector->isNull(dataPos)) {
        columnVector->setNull(columnPos, true);
    } else {
        columnVector->setNull(columnPos, false);
        columnVector->copyFromVectorData(columnPos, dataVector, dataPos);
    }
}

/**
 * P2-82: Reference Data Vector Instead of Copy
 * 
 * This TODO suggests that we might be able to reference the data vector
 * instead of copying values, which would improve INSERT performance.
 * 
 * Current Approach:
 * - For each column, copy data from dataVector to columnVector
 * - Uses copyFromVectorData() which does a deep copy
 * - This ensures data independence but has overhead
 * 
 * Why Copy Is Currently Used:
 * - columnVectors may have different lifetimes than dataVectors
 * - dataVectors come from evaluators that may be re-evaluated
 * - Results may be projected to different result sets
 * - Null state is managed separately per vector
 * 
 * What "Reference Instead of Copy" Would Look Like:
 * ```cpp
 * // Instead of copying:
 * columnVector->copyFromVectorData(columnPos, dataVector, dataPos);
 * 
 * // Reference (if safe):
 * columnVector->setReference(dataVector, dataPos);
 * // Or: columnVector = dataVector;  // Share underlying buffer
 * ```
 * 
 * When Reference Would Be Safe:
 * | Condition | Safe to Reference? |
 * |-----------|-------------------|
 * | Same result set | Yes |
 * | Different lifetimes | No |
 * | Vector will be mutated | No |
 * | Single-value flat state | Maybe |
 * 
 * Performance Impact:
 * - Copy: O(data size) per value
 * - Reference: O(1) - just pointer assignment
 * - For STRING/LIST types, copy is especially expensive
 * 
 * Challenges:
 * - Ownership and lifetime management
 * - Null buffer synchronization
 * - Selection vector alignment
 * - Thread safety if referenced across pipelines
 * 
 * Current Status:
 * Copy is safe default. Reference optimization would require careful
 * analysis of vector lifetimes in INSERT query plans.
 */
static void writeColumnVectors(const std::vector<ValueVector*>& columnVectors,
    const std::vector<ValueVector*>& dataVectors) {
    KU_ASSERT(columnVectors.size() == dataVectors.size());
    for (auto i = 0u; i < columnVectors.size(); ++i) {
        if (columnVectors[i] == nullptr) { // No need to project
            continue;
        }
        writeColumnVector(columnVectors[i], dataVectors[i]);
    }
}

static void writeColumnVectorsToNull(const std::vector<ValueVector*>& columnVectors) {
    for (auto i = 0u; i < columnVectors.size(); ++i) {
        auto columnVector = columnVectors[i];
        if (columnVector == nullptr) { // No need to project
            continue;
        }
        auto& columnSelVector = columnVector->state->getSelVector();
        KU_ASSERT(columnSelVector.getSelSize() == 1);
        columnVector->setNull(columnSelVector[0], true);
    }
}

void NodeInsertExecutor::setNodeIDVectorToNonNull() const {
    info.nodeIDVector->setNull(info.nodeIDVector->state->getSelVector()[0], false);
}

nodeID_t NodeInsertExecutor::insert(main::ClientContext* context) {
    for (auto& evaluator : tableInfo.columnDataEvaluators) {
        evaluator->evaluate();
    }
    auto transaction = Transaction::Get(*context);
    if (checkConflict(transaction)) {
        return info.getNodeID();
    }
    auto insertState = std::make_unique<storage::NodeTableInsertState>(*info.nodeIDVector,
        *tableInfo.pkVector, tableInfo.columnDataVectors);
    tableInfo.table->initInsertState(context, *insertState);
    tableInfo.table->insert(transaction, *insertState);
    writeColumnVectors(info.columnVectors, tableInfo.columnDataVectors);
    return info.getNodeID();
}

void NodeInsertExecutor::skipInsert() const {
    for (auto& evaluator : tableInfo.columnDataEvaluators) {
        evaluator->evaluate();
    }
    info.nodeIDVector->setNull(info.nodeIDVector->state->getSelVector()[0], false);
    writeColumnVectors(info.columnVectors, tableInfo.columnDataVectors);
}

bool NodeInsertExecutor::checkConflict(const Transaction* transaction) const {
    if (info.conflictAction == ConflictAction::ON_CONFLICT_DO_NOTHING) {
        auto offset =
            tableInfo.table->validateUniquenessConstraint(transaction, tableInfo.columnDataVectors);
        if (offset != INVALID_OFFSET) {
            // Conflict. Skip insertion.
            info.updateNodeID({offset, tableInfo.table->getTableID()});
            return true;
        }
    }
    return false;
}

void RelInsertInfo::init(const ResultSet& resultSet) {
    srcNodeIDVector = resultSet.getValueVector(srcNodeIDPos).get();
    dstNodeIDVector = resultSet.getValueVector(dstNodeIDPos).get();
    for (auto& pos : columnsPos) {
        if (pos.isValid()) {
            columnVectors.push_back(resultSet.getValueVector(pos).get());
        } else {
            columnVectors.push_back(nullptr);
        }
    }
}

void RelTableInsertInfo::init(const ResultSet& resultSet, main::ClientContext* context) {
    for (auto& evaluator : columnDataEvaluators) {
        evaluator->init(resultSet, context);
        columnDataVectors.push_back(evaluator->resultVector.get());
    }
}

internalID_t RelTableInsertInfo::getRelID() const {
    auto relIDVector = columnDataVectors[0];
    auto& nodeIDSelVector = relIDVector->state->getSelVector();
    KU_ASSERT(nodeIDSelVector.getSelSize() == 1);
    if (relIDVector->isNull(nodeIDSelVector[0])) {
        return {INVALID_OFFSET, INVALID_TABLE_ID};
    }
    return relIDVector->getValue<nodeID_t>(nodeIDSelVector[0]);
}

void RelInsertExecutor::init(ResultSet* resultSet, const ExecutionContext* context) {
    info.init(*resultSet);
    tableInfo.init(*resultSet, context->clientContext);
}

internalID_t RelInsertExecutor::insert(main::ClientContext* context) {
    KU_ASSERT(info.srcNodeIDVector->state->getSelVector().getSelSize() == 1);
    KU_ASSERT(info.dstNodeIDVector->state->getSelVector().getSelSize() == 1);
    auto srcNodeIDPos = info.srcNodeIDVector->state->getSelVector()[0];
    auto dstNodeIDPos = info.dstNodeIDVector->state->getSelVector()[0];
    if (info.srcNodeIDVector->isNull(srcNodeIDPos) || info.dstNodeIDVector->isNull(dstNodeIDPos)) {
        // No need to insert.
        writeColumnVectorsToNull(info.columnVectors);
        return tableInfo.getRelID();
    }
    for (auto i = 1u; i < tableInfo.columnDataEvaluators.size(); ++i) {
        tableInfo.columnDataEvaluators[i]->evaluate();
    }
    auto insertState = std::make_unique<storage::RelTableInsertState>(*info.srcNodeIDVector,
        *info.dstNodeIDVector, tableInfo.columnDataVectors);
    tableInfo.table->initInsertState(context, *insertState);
    tableInfo.table->insert(Transaction::Get(*context), *insertState);
    writeColumnVectors(info.columnVectors, tableInfo.columnDataVectors);
    return tableInfo.getRelID();
}

void RelInsertExecutor::skipInsert() const {
    for (auto i = 1u; i < tableInfo.columnDataEvaluators.size(); ++i) {
        tableInfo.columnDataEvaluators[i]->evaluate();
    }
    writeColumnVectors(info.columnVectors, tableInfo.columnDataVectors);
}

} // namespace processor
} // namespace kuzu
