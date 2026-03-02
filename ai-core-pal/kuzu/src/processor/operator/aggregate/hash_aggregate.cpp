#include "processor/operator/aggregate/hash_aggregate.h"

#include <memory>

#include "binder/expression/expression_util.h"
#include "common/assert.h"
#include "common/types/types.h"
#include "main/client_context.h"
#include "processor/execution_context.h"
#include "processor/operator/aggregate/aggregate_hash_table.h"
#include "processor/operator/aggregate/aggregate_input.h"
#include "processor/operator/aggregate/base_aggregate.h"
#include "processor/result/factorized_table_schema.h"
#include "storage/buffer_manager/memory_manager.h"

using namespace kuzu::common;
using namespace kuzu::function;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

std::string HashAggregatePrintInfo::toString() const {
    std::string result = "";
    result += "Group By: ";
    result += binder::ExpressionUtil::toString(keys);
    if (!aggregates.empty()) {
        result += ", Aggregates: ";
        result += binder::ExpressionUtil::toString(aggregates);
    }
    if (limitNum != UINT64_MAX) {
        result += ", Distinct Limit: " + std::to_string(limitNum);
    }
    return result;
}

HashAggregateInfo::HashAggregateInfo(std::vector<DataPos> flatKeysPos,
    std::vector<DataPos> unFlatKeysPos, std::vector<DataPos> dependentKeysPos,
    FactorizedTableSchema tableSchema)
    : flatKeysPos{std::move(flatKeysPos)}, unFlatKeysPos{std::move(unFlatKeysPos)},
      dependentKeysPos{std::move(dependentKeysPos)}, tableSchema{std::move(tableSchema)} {}

HashAggregateInfo::HashAggregateInfo(const HashAggregateInfo& other)
    : flatKeysPos{other.flatKeysPos}, unFlatKeysPos{other.unFlatKeysPos},
      dependentKeysPos{other.dependentKeysPos}, tableSchema{other.tableSchema.copy()} {}

HashAggregateSharedState::HashAggregateSharedState(main::ClientContext* context,
    HashAggregateInfo hashAggInfo,
    const std::vector<function::AggregateFunction>& aggregateFunctions,
    std::span<AggregateInfo> aggregateInfos, std::vector<LogicalType> keyTypes,
    std::vector<LogicalType> payloadTypes)
    : BaseAggregateSharedState{aggregateFunctions, getNumPartitionsForParallelism(context)},
      aggInfo{std::move(hashAggInfo)}, limitNumber{common::INVALID_LIMIT},
      memoryManager{MemoryManager::Get(*context)},
      globalPartitions{getNumPartitionsForParallelism(context)} {
    std::vector<LogicalType> distinctAggregateKeyTypes;
    for (auto& aggInfo : aggregateInfos) {
        distinctAggregateKeyTypes.push_back(aggInfo.distinctAggKeyType.copy());
    }

    // When copying directly into factorizedTables the table's schema's internal mayContainNulls
    // won't be updated and it's probably less work to just always check nulls
    // Skip the last column, which is the hash column and should never contain nulls
    for (size_t i = 0; i < this->aggInfo.tableSchema.getNumColumns() - 1; i++) {
        this->aggInfo.tableSchema.setMayContainsNullsToTrue(i);
    }

    auto& partition = globalPartitions[0];
    partition.queue = std::make_unique<HashTableQueue>(MemoryManager::Get(*context),
        this->aggInfo.tableSchema.copy());

    // Always create a hash table for the first partition. Any other partitions which are non-empty
    // when finalizing will create an empty copy of this table
    partition.hashTable = std::make_unique<AggregateHashTable>(*MemoryManager::Get(*context),
        std::move(keyTypes), std::move(payloadTypes), aggregateFunctions, distinctAggregateKeyTypes,
        0, this->aggInfo.tableSchema.copy());
    for (size_t functionIdx = 0; functionIdx < aggregateFunctions.size(); functionIdx++) {
        auto& function = aggregateFunctions[functionIdx];
        if (function.isFunctionDistinct()) {
            // Create table schema for distinct hash table
            auto distinctTableSchema = FactorizedTableSchema();
            // Group by key columns
            for (size_t i = 0;
                 i < this->aggInfo.flatKeysPos.size() + this->aggInfo.unFlatKeysPos.size(); i++) {
                distinctTableSchema.appendColumn(this->aggInfo.tableSchema.getColumn(i)->copy());
                distinctTableSchema.setMayContainsNullsToTrue(i);
            }
            // Distinct key column
            distinctTableSchema.appendColumn(ColumnSchema(false /*isUnFlat*/, 0 /*groupID*/,
                LogicalTypeUtils::getRowLayoutSize(
                    aggregateInfos[functionIdx].distinctAggKeyType)));
            distinctTableSchema.setMayContainsNullsToTrue(distinctTableSchema.getNumColumns() - 1);
            // Hash column
            distinctTableSchema.appendColumn(
                ColumnSchema(false /* isUnFlat */, 0 /* groupID */, sizeof(hash_t)));

            partition.distinctTableQueues.emplace_back(std::make_unique<HashTableQueue>(
                MemoryManager::Get(*context), std::move(distinctTableSchema)));
        } else {
            // dummy entry so that indices line up with the aggregateFunctions
            partition.distinctTableQueues.emplace_back();
        }
    }
    // Each partition is the same, so we create the list of distinct queues for the first partition
    // and copy it to the other partitions
    for (size_t i = 1; i < globalPartitions.size(); i++) {
        globalPartitions[i].queue = std::make_unique<HashTableQueue>(MemoryManager::Get(*context),
            this->aggInfo.tableSchema.copy());
        globalPartitions[i].distinctTableQueues.resize(partition.distinctTableQueues.size());
        std::transform(partition.distinctTableQueues.begin(), partition.distinctTableQueues.end(),
            globalPartitions[i].distinctTableQueues.begin(), [&](auto& q) {
                if (q.get() != nullptr) {
                    return q->copy();
                } else {
                    return std::unique_ptr<HashTableQueue>();
                }
            });
    }
}

std::pair<uint64_t, uint64_t> HashAggregateSharedState::getNextRangeToRead() {
    std::unique_lock lck{mtx};
    auto startOffset = currentOffset.load();
    auto numTuples = getNumTuples();
    if (startOffset >= numTuples) {
        return std::make_pair(startOffset, startOffset);
    }
    // FactorizedTable::lookup resets the ValueVector and writes to the beginning,
    // so we can't support scanning from multiple partitions at once
    auto [table, tableStartOffset] = getPartitionForOffset(startOffset);
    auto range = std::min(std::min(DEFAULT_VECTOR_CAPACITY, numTuples - startOffset),
        table->getNumTuples() + tableStartOffset - startOffset);
    currentOffset += range;
    return std::make_pair(startOffset, startOffset + range);
}

uint64_t HashAggregateSharedState::getNumTuples() const {
    uint64_t numTuples = 0;
    for (auto& partition : globalPartitions) {
        numTuples += partition.hashTable->getNumEntries();
    }
    return numTuples;
}

/**
 * P2-70: Hash Aggregate Partition Finalization
 * 
 * This TODO notes that the distinct table merge and main table merge could ideally
 * be combined into a single function.
 * 
 * Current Two-Phase Merge Process:
 * 1. Merge distinct tables first (for each aggregate function)
 * 2. Then merge main hash table queue
 * 
 * Why Two Phases Are Currently Required:
 * - Distinct tables must exist BEFORE main table merge
 * - Main table merge updates aggregate states
 * - Those state updates reference the distinct tables
 * - If distinct tables don't exist yet, crash or incorrect results
 * 
 * What "Single Function" Would Look Like:
 * ```cpp
 * partition.mergeAllTables();  // Handles ordering internally
 * ```
 * - Encapsulate the merge ordering inside AggregateHashTable
 * - Caller doesn't need to know about distinct vs non-distinct
 * - Simpler finalization code
 * 
 * Why Keep Separate For Now:
 * 1. Explicit ordering is clearer for maintenance
 * 2. Debugging: can inspect state between phases
 * 3. Different merge strategies might be needed in future
 * 4. Not a performance bottleneck (finalization is O(partitions))
 * 
 * Merge Sequence Diagram:
 * ```
 * ┌─────────────────────────────────────────────────────┐
 * │ For each partition:                                  │
 * │   1. Merge distinct queues → distinct hash tables    │
 * │   2. Merge main queue → main hash table              │
 * │      (updates agg states, references distinct tables)│
 * │   3. Merge distinct aggregate info                   │
 * │   4. Finalize aggregate states                       │
 * └─────────────────────────────────────────────────────┘
 * ```
 * 
 * Performance Note:
 * - Merging is parallelized across partitions
 * - Each partition is finalized independently
 * - No cross-partition synchronization needed during merge
 */
void HashAggregateSharedState::finalizePartitions() {
    BaseAggregateSharedState::finalizePartitions(globalPartitions, [&](auto& partition) {
        if (!partition.hashTable) {
            // We always initialize the hash table in the first partition
            partition.hashTable = std::make_unique<AggregateHashTable>(
                globalPartitions[0].hashTable->createEmptyCopy());
        }
        // Phase 1: Merge distinct tables (must complete before main table merge)
        for (size_t i = 0; i < partition.distinctTableQueues.size(); i++) {
            if (partition.distinctTableQueues[i]) {
                partition.distinctTableQueues[i]->mergeInto(
                    *partition.hashTable->getDistinctHashTable(i));
            }
        }
        // Phase 2: Merge main table (references distinct tables for agg state updates)
        partition.queue->mergeInto(*partition.hashTable);
        partition.hashTable->mergeDistinctAggregateInfo();

        partition.hashTable->finalizeAggregateStates();
    });
}

std::tuple<const FactorizedTable*, offset_t> HashAggregateSharedState::getPartitionForOffset(
    offset_t offset) const {
    auto factorizedTableStartOffset = 0;
    auto partitionIdx = 0;
    const auto* table = globalPartitions[partitionIdx].hashTable->getFactorizedTable();
    while (factorizedTableStartOffset + table->getNumTuples() <= offset) {
        factorizedTableStartOffset += table->getNumTuples();
        table = globalPartitions[++partitionIdx].hashTable->getFactorizedTable();
    }
    return std::make_tuple(table, factorizedTableStartOffset);
}

void HashAggregateSharedState::scan(std::span<uint8_t*> entries,
    std::vector<common::ValueVector*>& keyVectors, offset_t startOffset, offset_t numTuplesToScan,
    std::vector<uint32_t>& columnIndices) {
    auto [table, tableStartOffset] = getPartitionForOffset(startOffset);
    // Due to the way FactorizedTable::lookup works, it's necessary to read one partition
    // at a time.
    KU_ASSERT(startOffset - tableStartOffset + numTuplesToScan <= table->getNumTuples());
    for (size_t pos = 0; pos < numTuplesToScan; pos++) {
        auto posInTable = startOffset + pos - tableStartOffset;
        entries[pos] = table->getTuple(posInTable);
    }
    table->lookup(keyVectors, columnIndices, entries.data(), 0, numTuplesToScan);
    KU_ASSERT(true);
}

void HashAggregateSharedState::assertFinalized() const {
    RUNTIME_CHECK(for (const auto& partition
                       : globalPartitions) {
        KU_ASSERT(partition.finalized);
        KU_ASSERT(partition.queue->empty());
    });
}

void HashAggregateLocalState::init(HashAggregateSharedState* sharedState, ResultSet& resultSet,
    main::ClientContext* context, std::vector<function::AggregateFunction>& aggregateFunctions,
    std::vector<common::LogicalType> distinctKeyTypes) {
    auto& info = sharedState->getAggregateInfo();
    std::vector<LogicalType> keyDataTypes;
    for (auto& pos : info.flatKeysPos) {
        auto vector = resultSet.getValueVector(pos).get();
        keyVectors.push_back(vector);
        keyDataTypes.push_back(vector->dataType.copy());
    }
    for (auto& pos : info.unFlatKeysPos) {
        auto vector = resultSet.getValueVector(pos).get();
        keyVectors.push_back(vector);
        keyDataTypes.push_back(vector->dataType.copy());
        leadingState = vector->state.get();
    }
    if (leadingState == nullptr) {
        // All vectors are flat, so any can be the leading state
        leadingState = keyVectors.front()->state.get();
    }
    std::vector<LogicalType> payloadDataTypes;
    for (auto& pos : info.dependentKeysPos) {
        auto vector = resultSet.getValueVector(pos).get();
        dependentKeyVectors.push_back(vector);
        payloadDataTypes.push_back(vector->dataType.copy());
    }

    aggregateHashTable = std::make_unique<PartitioningAggregateHashTable>(sharedState,
        *MemoryManager::Get(*context), std::move(keyDataTypes), std::move(payloadDataTypes),
        aggregateFunctions, std::move(distinctKeyTypes), info.tableSchema.copy());
}

uint64_t HashAggregateLocalState::append(const std::vector<AggregateInput>& aggregateInputs,
    uint64_t multiplicity) const {
    return aggregateHashTable->append(keyVectors, dependentKeyVectors, leadingState,
        aggregateInputs, multiplicity);
}

void HashAggregate::initLocalStateInternal(ResultSet* resultSet, ExecutionContext* context) {
    BaseAggregate::initLocalStateInternal(resultSet, context);
    std::vector<LogicalType> distinctAggKeyTypes;
    for (auto& info : aggInfos) {
        distinctAggKeyTypes.push_back(info.distinctAggKeyType.copy());
    }
    localState.init(common::ku_dynamic_cast<HashAggregateSharedState*>(sharedState.get()),
        *resultSet, context->clientContext, aggregateFunctions, std::move(distinctAggKeyTypes));
}

void HashAggregate::executeInternal(ExecutionContext* context) {
    while (children[0]->getNextTuple(context)) {
        const auto numAppendedFlatTuples = localState.append(aggInputs, resultSet->multiplicity);
        metrics->numOutputTuple.increase(numAppendedFlatTuples);
        // Note: The limit count check here is only applicable to the distinct limit case.
        if (localState.aggregateHashTable->getNumEntries() >=
            getSharedStateReference().getLimitNumber()) {
            break;
        }
    }
    localState.aggregateHashTable->mergeIfFull(0 /*tuplesToAdd*/, true /*mergeAll*/);
}

} // namespace processor
} // namespace kuzu
