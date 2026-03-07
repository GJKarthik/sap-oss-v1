#include "storage/table/struct_column.h"

#include "common/types/types.h"
#include "common/vector/value_vector.h"
#include "storage/buffer_manager/memory_manager.h"
#include "storage/storage_utils.h"
#include "storage/table/column_chunk.h"
#include "storage/table/null_column.h"
#include "storage/table/struct_chunk_data.h"

using namespace kuzu::catalog;
using namespace kuzu::common;
using namespace kuzu::transaction;

namespace kuzu {
namespace storage {

StructColumn::StructColumn(std::string name, LogicalType dataType, FileHandle* dataFH,
    MemoryManager* mm, ShadowFile* shadowFile, bool enableCompression)
    : Column{std::move(name), std::move(dataType), dataFH, mm, shadowFile, enableCompression,
          true /* requireNullColumn */} {
    const auto fieldTypes = StructType::getFieldTypes(this->dataType);
    childColumns.resize(fieldTypes.size());
    for (auto i = 0u; i < fieldTypes.size(); i++) {
        const auto childColName = StorageUtils::getColumnName(this->name,
            StorageUtils::ColumnType::STRUCT_CHILD, std::to_string(i));
        childColumns[i] = ColumnFactory::createColumn(childColName, fieldTypes[i]->copy(), dataFH,
            mm, shadowFile, enableCompression);
    }
}

std::unique_ptr<ColumnChunkData> StructColumn::flushChunkData(const ColumnChunkData& chunk,
    PageAllocator& pageAllocator) {
    auto flushedChunk = flushNonNestedChunkData(chunk, pageAllocator);
    auto& structChunk = chunk.cast<StructChunkData>();
    auto& flushedStructChunk = flushedChunk->cast<StructChunkData>();
    for (auto i = 0u; i < structChunk.getNumChildren(); i++) {
        auto flushedChildChunk = Column::flushChunkData(structChunk.getChild(i), pageAllocator);
        flushedStructChunk.setChild(i, std::move(flushedChildChunk));
    }
    return flushedChunk;
}

/**
 * P2-68: Struct Column Child Size Synchronization
 * 
 * This TODO notes that fixing child sizes after parent scan shouldn't be necessary.
 * 
 * The Problem:
 * Column::scanSegment() adjusts chunk size to match scanned values. For struct columns,
 * this affects all child chunks, but children need their OWN scan to determine correct size.
 * 
 * Why Size Fix Is Currently Needed:
 * 1. Parent scan modifies resultChunk->numValues
 * 2. Child chunks inherit this size change
 * 3. But children haven't been scanned yet
 * 4. So we save size, let parent scan, restore size, then scan children
 * 
 * Why This Is Awkward:
 * - Size should be set AFTER scanning, not during
 * - Each column should manage its own chunk size
 * - Coupling between parent and child scan order
 * 
 * Ideal Solution:
 * - Separate "scan" from "resize" operations
 * - Each column writes to its own size field
 * - Or: children scan first, parent aggregates
 * 
 * Current Workaround:
 * - Save sizeBeforeScan
 * - Let parent Column::scanSegment run (modifies chunk)
 * - For each child: restore size, then scan child
 * - This ensures children start with correct pre-scan size
 * 
 * Performance Impact:
 * - Minimal: just reading/writing numValues field
 * - Alternative (scan children first) would require 2 passes
 * 
 * Similar Issue: list_column.cpp has the same pattern
 * (referenced in comment as "see note in list_column.cpp")
 */
void StructColumn::scanSegment(const SegmentState& state, ColumnChunkData* resultChunk,
    common::offset_t startOffsetInSegment, common::row_idx_t numValuesToScan) const {
    KU_ASSERT(resultChunk->getDataType().getPhysicalType() == PhysicalTypeID::STRUCT);
    auto sizeBeforeScan = resultChunk->getNumValues();
    Column::scanSegment(state, resultChunk, startOffsetInSegment, numValuesToScan);
    auto& structColumnChunk = resultChunk->cast<StructChunkData>();
    for (auto i = 0u; i < childColumns.size(); i++) {
        structColumnChunk.getChild(i)->setNumValues(sizeBeforeScan);
        childColumns[i]->scanSegment(state.childrenStates[i], structColumnChunk.getChild(i),
            startOffsetInSegment, numValuesToScan);
    }
}

void StructColumn::scanSegment(const SegmentState& state, offset_t startOffsetInSegment,
    row_idx_t numValuesToScan, ValueVector* resultVector, offset_t offsetInResult) const {
    Column::scanSegment(state, startOffsetInSegment, numValuesToScan, resultVector, offsetInResult);
    for (auto i = 0u; i < childColumns.size(); i++) {
        const auto fieldVector = StructVector::getFieldVector(resultVector, i).get();
        childColumns[i]->scanSegment(state.childrenStates[i], startOffsetInSegment, numValuesToScan,
            fieldVector, offsetInResult);
    }
}

void StructColumn::lookupInternal(const SegmentState& state, offset_t offsetInSegment,
    ValueVector* resultVector, uint32_t posInVector) const {
    for (auto i = 0u; i < childColumns.size(); i++) {
        const auto fieldVector = StructVector::getFieldVector(resultVector, i).get();
        childColumns[i]->lookupInternal(state.childrenStates[i], offsetInSegment, fieldVector,
            posInVector);
    }
}

void StructColumn::writeSegment(ColumnChunkData& persistentChunk, SegmentState& state,
    offset_t offsetInSegment, const ColumnChunkData& data, offset_t dataOffset,
    length_t numValues) const {
    KU_ASSERT(data.getDataType().getPhysicalType() == PhysicalTypeID::STRUCT);
    nullColumn->writeSegment(*persistentChunk.getNullData(), *state.nullState, offsetInSegment,
        *data.getNullData(), dataOffset, numValues);
    auto& structData = data.cast<StructChunkData>();
    auto& persistentStructChunk = persistentChunk.cast<StructChunkData>();
    for (auto i = 0u; i < childColumns.size(); i++) {
        const auto& childData = structData.getChild(i);
        childColumns[i]->writeSegment(*persistentStructChunk.getChild(i), state.childrenStates[i],
            offsetInSegment, childData, dataOffset, numValues);
    }
}

std::vector<std::unique_ptr<ColumnChunkData>> StructColumn::checkpointSegment(
    ColumnCheckpointState&& checkpointState, PageAllocator& pageAllocator,
    bool canSplitSegment) const {
    auto& persistentStructChunk = checkpointState.persistentData.cast<StructChunkData>();
    // TODO(bmwinger): child columns are now handled as a group so they get split together
    // Re-introduce the code below when struct columns checkpoing each field individually again
    /*
    for (auto i = 0u; i < childColumns.size(); i++) {
        std::vector<SegmentCheckpointState> childSegmentCheckpointStates;
        for (const auto& segmentCheckpointState : checkpointState.segmentCheckpointStates) {
            childSegmentCheckpointStates.emplace_back(
                segmentCheckpointState.chunkData.cast<StructChunkData>().getChild(i),
                segmentCheckpointState.startRowInData, segmentCheckpointState.offsetInSegment,
                segmentCheckpointState.numRows);
        }
        childColumns[i]->checkpointSegment(ColumnCheckpointState(*persistentStructChunk.getChild(i),
            std::move(childSegmentCheckpointStates)), pageAllocator);
    }
    Column::checkpointNullData(checkpointState, pageAllocator);
    */
    auto result =
        Column::checkpointSegment(std::move(checkpointState), pageAllocator, canSplitSegment);
    persistentStructChunk.syncNumValues();
    return result;
}

bool StructColumn::canCheckpointInPlace(const SegmentState& state,
    const ColumnCheckpointState& checkpointState) const {
    if (!Column::canCheckpointInPlace(state, checkpointState)) {
        return false;
    }
    for (size_t i = 0; i < childColumns.size(); ++i) {
        auto& structChunkData = checkpointState.persistentData.cast<StructChunkData>();
        KU_ASSERT(childColumns.size() == structChunkData.getNumChildren());
        auto* childChunkData = structChunkData.getChild(i);

        std::vector<SegmentCheckpointState> childSegmentCheckpointStates;
        for (auto& segmentCheckpointState : checkpointState.segmentCheckpointStates) {
            auto& structSegmentData = segmentCheckpointState.chunkData.cast<StructChunkData>();
            auto& childSegmentData = structSegmentData.getChild(i);
            childSegmentCheckpointStates.emplace_back(childSegmentData,
                segmentCheckpointState.offsetInSegment, segmentCheckpointState.startRowInData,
                segmentCheckpointState.numRows);
        }

        if (!childColumns[i]->canCheckpointInPlace(state.getChildState(i),
                ColumnCheckpointState(*childChunkData, std::move(childSegmentCheckpointStates)))) {
            return false;
        }
    }
    return true;
}

} // namespace storage
} // namespace kuzu
