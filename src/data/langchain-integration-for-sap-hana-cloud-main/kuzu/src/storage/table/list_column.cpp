#include "storage/table/list_column.h"

/**
 * P2-110: List Column Storage - Variable-Length Array Optimization
 * 
 * Purpose:
 * Implements efficient storage for LIST/ARRAY types with variable-length elements.
 * Uses separate offset/size/data columns for O(1) random access to list elements.
 * 
 * Storage Layout:
 * ```
 * ListColumn (stores list_entry_t values)
 *   ├── offsetColumn: Column<UINT64>    // End offset of each list
 *   ├── sizeColumn: Column<UINT32>      // Size of each list
 *   ├── dataColumn: Column<ChildType>   // Actual list elements (recursive)
 *   └── nullColumn: Column<bool>        // Null bitmap
 * 
 * Physical Layout (for 3 lists: [1,2], [3,4,5], [6]):
 * Row:     | 0  | 1  | 2  |
 * Offset:  | 2  | 5  | 6  |  (cumulative end positions)
 * Size:    | 2  | 3  | 1  |  (element counts)
 * Data:    | 1 | 2 | 3 | 4 | 5 | 6 |  (flattened elements)
 * ```
 * 
 * Key Data Structures:
 * - ListOffsetSizeInfo: Cached offset/size arrays for scan operations
 * - list_entry_t: {offset, size} tuple for ValueVector representation
 * 
 * Scan Optimization: isOffsetSortedAscending()
 * When list data is stored contiguously (no deletions/updates),
 * we can scan the entire range in one dataColumn->scanSegment() call.
 * Otherwise, we fall back to per-list scanning.
 * 
 * Performance Analysis:
 * | Operation | Contiguous | Fragmented |
 * |-----------|------------|------------|
 * | Full scan | O(n) | O(m*n) where m=avg list size |
 * | Random access | O(1) | O(1) |
 * | Append | O(k) | O(k) |
 * | Checkpoint | In-place possible | May require rewrite |
 * 
 * Compression Consideration:
 * - FLOAT/DOUBLE arrays in ARRAY types disable compression
 * - disableCompressionOnData() prevents lossy compression for vector data
 * - Important for embedding vectors in AI/ML workloads
 * 
 * Checkpoint Strategy (checkpointSegment):
 * 1. Try in-place checkpoint for data column first
 * 2. If data is contiguous, use single segment checkpoint
 * 3. For fragmented data, create per-list checkpoint states
 * 4. Offset/size columns always checkpoint independently
 * 
 * Memory Optimization Opportunities:
 * 
 * 1. Delta Encoding for Offsets:
 *    Instead of storing cumulative offsets, store deltas:
 *    ```
 *    // Current: [2, 5, 6] - 8 bytes each = 24 bytes
 *    // Delta:   [2, 3, 1] - can use 1-2 bytes each = 3-6 bytes
 *    ```
 *    With variable-length encoding: 75% space reduction.
 * 
 * 2. Run-Length Encoding for Size Column:
 *    When many lists have same size (common in embeddings):
 *    ```
 *    // Embedding vectors: all size=1536
 *    // RLE: (1536, count=10000) = 12 bytes vs 40KB
 *    ```
 * 
 * 3. Prefetch Data During Offset Scan:
 *    ```
 *    void scanWithPrefetch(offset_t start, offset_t end) {
 *        // Prefetch data pages while scanning offsets
 *        for (auto i = start; i < end; i++) {
 *            __builtin_prefetch(dataPtr + offsets[i+8]);
 *            process(data[offsets[i]]);
 *        }
 *    }
 *    ```
 * 
 * 4. Compact Storage for Small Lists:
 *    For lists with ≤ N elements, inline in main column:
 *    - Avoids indirection for common small lists
 *    - Similar to PostgreSQL TOAST threshold
 */

#include <algorithm>

#include "common/assert.h"
#include "common/types/types.h"
#include "common/vector/value_vector.h"
#include "storage/buffer_manager/memory_manager.h"
#include "storage/storage_utils.h"
#include "storage/table/column.h"
#include "storage/table/column_chunk.h"
#include "storage/table/column_chunk_data.h"
#include "storage/table/list_chunk_data.h"
#include "storage/table/null_column.h"
#include <bit>

using namespace kuzu::common;

namespace kuzu {
namespace storage {

offset_t ListOffsetSizeInfo::getListStartOffset(uint64_t pos) const {
    if (numTotal == 0) {
        return 0;
    }
    return pos == numTotal ? getListEndOffset(pos - 1) : getListEndOffset(pos) - getListSize(pos);
}

offset_t ListOffsetSizeInfo::getListEndOffset(uint64_t pos) const {
    if (numTotal == 0) {
        return 0;
    }
    KU_ASSERT(pos < offsetColumnChunk->getNumValues());
    return offsetColumnChunk->getValue<offset_t>(pos);
}

list_size_t ListOffsetSizeInfo::getListSize(uint64_t pos) const {
    if (numTotal == 0) {
        return 0;
    }
    KU_ASSERT(pos < sizeColumnChunk->getNumValues());
    return sizeColumnChunk->getValue<list_size_t>(pos);
}

bool ListOffsetSizeInfo::isOffsetSortedAscending(uint64_t startPos, uint64_t endPos) const {
    offset_t prevEndOffset = getListStartOffset(startPos);
    for (auto i = startPos; i < endPos; i++) {
        offset_t currentEndOffset = getListEndOffset(i);
        auto size = getListSize(i);
        prevEndOffset += size;
        if (currentEndOffset != prevEndOffset) {
            return false;
        }
    }
    return true;
}

ListColumn::ListColumn(std::string name, LogicalType dataType, FileHandle* dataFH,
    MemoryManager* mm, ShadowFile* shadowFile, bool enableCompression)
    : Column{std::move(name), std::move(dataType), dataFH, mm, shadowFile, enableCompression,
          true /* requireNullColumn */} {
    auto offsetColName =
        StorageUtils::getColumnName(this->name, StorageUtils::ColumnType::OFFSET, "offset_");
    auto sizeColName =
        StorageUtils::getColumnName(this->name, StorageUtils::ColumnType::OFFSET, "");
    auto dataColName = StorageUtils::getColumnName(this->name, StorageUtils::ColumnType::DATA, "");
    sizeColumn = std::make_unique<Column>(sizeColName, LogicalType::UINT32(), dataFH, mm,
        shadowFile, enableCompression, false /*requireNullColumn*/);
    offsetColumn = std::make_unique<Column>(offsetColName, LogicalType::UINT64(), dataFH, mm,
        shadowFile, enableCompression, false /*requireNullColumn*/);
    if (disableCompressionOnData(this->dataType)) {
        enableCompression = false;
    }
    dataColumn = ColumnFactory::createColumn(dataColName,
        ListType::getChildType(this->dataType).copy(), dataFH, mm, shadowFile, enableCompression);
}

bool ListColumn::disableCompressionOnData(const LogicalType& dataType) {
    if (dataType.getLogicalTypeID() == LogicalTypeID::ARRAY &&
        (ListType::getChildType(dataType).getPhysicalType() == PhysicalTypeID::FLOAT ||
            ListType::getChildType(dataType).getPhysicalType() == PhysicalTypeID::DOUBLE)) {
        // Force disable compression for floating point types.
        return true;
    }
    return false;
}

std::unique_ptr<ColumnChunkData> ListColumn::flushChunkData(const ColumnChunkData& chunk,
    PageAllocator& pageAllocator) {
    auto flushedChunk = flushNonNestedChunkData(chunk, pageAllocator);
    auto& listChunk = chunk.cast<ListChunkData>();
    auto& flushedListChunk = flushedChunk->cast<ListChunkData>();
    flushedListChunk.setOffsetColumnChunk(
        Column::flushChunkData(*listChunk.getOffsetColumnChunk(), pageAllocator));
    flushedListChunk.setSizeColumnChunk(
        Column::flushChunkData(*listChunk.getSizeColumnChunk(), pageAllocator));
    flushedListChunk.setDataColumnChunk(
        Column::flushChunkData(*listChunk.getDataColumnChunk(), pageAllocator));
    return flushedChunk;
}

void ListColumn::scanSegment(const SegmentState& state, offset_t startOffsetInChunk,
    row_idx_t numValuesToScan, ValueVector* resultVector, offset_t offsetInResult) const {
    if (nullColumn) {
        KU_ASSERT(state.nullState);
        nullColumn->scanSegment(*state.nullState, startOffsetInChunk, numValuesToScan, resultVector,
            offsetInResult);
    }
    auto listOffsetSizeInfo = getListOffsetSizeInfo(state, startOffsetInChunk, numValuesToScan);
    if (!resultVector->state || resultVector->state->getSelVector().isUnfiltered()) {
        scanUnfiltered(state, resultVector, numValuesToScan, listOffsetSizeInfo, offsetInResult);
    } else {
        scanFiltered(state, startOffsetInChunk, resultVector, listOffsetSizeInfo, offsetInResult);
    }
}

void ListColumn::scanSegment(const SegmentState& state, ColumnChunkData* resultChunk,
    common::offset_t startOffsetInSegment, common::row_idx_t numValuesToScan) const {
    auto startOffsetInResult = resultChunk->getNumValues();
    auto& listColumnChunk = resultChunk->cast<ListChunkData>();
    // Save the original offset/size chunk numValues BEFORE calling Column::scanSegment,
    // since it may modify them as a side effect when appending to the result chunk.
    // We need these values to properly position our subsequent scans.
    const auto originalOffsetNumValues = listColumnChunk.getOffsetColumnChunk()->getNumValues();
    const auto originalSizeNumValues = listColumnChunk.getSizeColumnChunk()->getNumValues();
    
    Column::scanSegment(state, resultChunk, startOffsetInSegment, numValuesToScan);
    if (numValuesToScan == 0) {
        return;
    }
    // Restore the offset/size chunk numValues to their original values.
    // Column::scanSegment modifies these as a side effect, but we need to scan
    // them independently starting from the correct position.
    listColumnChunk.getOffsetColumnChunk()->setNumValues(originalOffsetNumValues);
    listColumnChunk.getSizeColumnChunk()->setNumValues(originalSizeNumValues);

    offsetColumn->scanSegment(state.childrenStates[OFFSET_COLUMN_CHILD_READ_STATE_IDX],
        listColumnChunk.getOffsetColumnChunk(), startOffsetInSegment, numValuesToScan);
    sizeColumn->scanSegment(state.childrenStates[SIZE_COLUMN_CHILD_READ_STATE_IDX],
        listColumnChunk.getSizeColumnChunk(), startOffsetInSegment, numValuesToScan);
    auto resizeNumValues = listColumnChunk.getDataColumnChunk()->getNumValues();
    bool isOffsetSortedAscending = true;
    KU_ASSERT(listColumnChunk.getSizeColumnChunk()->getNumValues() ==
              startOffsetInResult + numValuesToScan);
    offset_t prevOffset = listColumnChunk.getListStartOffset(startOffsetInResult);
    for (auto i = startOffsetInResult; i < startOffsetInResult + numValuesToScan; i++) {
        auto currentEndOffset = listColumnChunk.getListEndOffset(i);
        auto appendSize = listColumnChunk.getListSize(i);
        prevOffset += appendSize;
        if (currentEndOffset != prevOffset) {
            isOffsetSortedAscending = false;
        }
        resizeNumValues += appendSize;
    }
    if (isOffsetSortedAscending) {
        listColumnChunk.resizeDataColumnChunk(std::bit_ceil(resizeNumValues));
        offset_t startListOffset = listColumnChunk.getListStartOffset(startOffsetInResult);
        offset_t endListOffset =
            listColumnChunk.getListStartOffset(startOffsetInResult + numValuesToScan);
        KU_ASSERT(endListOffset >= startListOffset);
        dataColumn->scanSegment(state.childrenStates[DATA_COLUMN_CHILD_READ_STATE_IDX],
            listColumnChunk.getDataColumnChunk(), startListOffset, endListOffset - startListOffset);
    } else {
        listColumnChunk.resizeDataColumnChunk(std::bit_ceil(resizeNumValues));
        for (auto i = startOffsetInResult; i < startOffsetInResult + numValuesToScan; i++) {
            offset_t startListOffset = listColumnChunk.getListStartOffset(i);
            offset_t endListOffset = listColumnChunk.getListEndOffset(i);
            dataColumn->scanSegment(state.childrenStates[DATA_COLUMN_CHILD_READ_STATE_IDX],
                listColumnChunk.getDataColumnChunk(), startListOffset,
                endListOffset - startListOffset);
        }
    }
    listColumnChunk.resetOffset();

    KU_ASSERT(listColumnChunk.sanityCheck());
}

void ListColumn::lookupInternal(const SegmentState& state, offset_t nodeOffset,
    ValueVector* resultVector, uint32_t posInVector) const {
    auto [nodeGroupIdx, offsetInChunk] = StorageUtils::getNodeGroupIdxAndOffsetInChunk(nodeOffset);
    const auto listEndOffset = readOffset(state, offsetInChunk);
    const auto size = readSize(state, offsetInChunk);
    const auto listStartOffset = listEndOffset - size;
    auto dataVector = ListVector::getDataVector(resultVector);
    auto currentListDataSize = ListVector::getDataVectorSize(resultVector);
    ListVector::resizeDataVector(resultVector, currentListDataSize + size);
    dataColumn->scanSegment(state.childrenStates[ListChunkData::DATA_COLUMN_CHILD_READ_STATE_IDX],
        listStartOffset, listEndOffset - listStartOffset, dataVector, currentListDataSize);
    resultVector->setValue(posInVector, list_entry_t{currentListDataSize, size});
}

void ListColumn::scanUnfiltered(const SegmentState& state, ValueVector* resultVector,
    uint64_t numValuesToScan, const ListOffsetSizeInfo& listOffsetInfoInStorage,
    offset_t offsetInResult) const {
    auto dataVector = ListVector::getDataVector(resultVector);
    // Scans append to the end of the vector, so we need to start at the end of the last list
    auto startOffsetInDataVector = ListVector::getDataVectorSize(resultVector);
    auto offsetInDataVector = startOffsetInDataVector;

    numValuesToScan = std::min(numValuesToScan, listOffsetInfoInStorage.numTotal);
    for (auto i = 0u; i < numValuesToScan; i++) {
        auto listLen = listOffsetInfoInStorage.getListSize(i);
        resultVector->setValue(offsetInResult + i, list_entry_t{offsetInDataVector, listLen});
        offsetInDataVector += listLen;
    }
    ListVector::resizeDataVector(resultVector, offsetInDataVector);
    const bool checkOffsetOrder =
        listOffsetInfoInStorage.isOffsetSortedAscending(0, numValuesToScan);
    if (checkOffsetOrder) {
        auto startListOffsetInStorage = listOffsetInfoInStorage.getListStartOffset(0);
        numValuesToScan = numValuesToScan == 0 ? 0 : numValuesToScan - 1;
        auto endListOffsetInStorage = listOffsetInfoInStorage.getListEndOffset(numValuesToScan);
        dataColumn->scanSegment(
            state.childrenStates[ListChunkData::DATA_COLUMN_CHILD_READ_STATE_IDX],
            startListOffsetInStorage, endListOffsetInStorage - startListOffsetInStorage, dataVector,
            static_cast<uint64_t>(startOffsetInDataVector /* offsetInVector */));
    } else {
        offsetInDataVector = startOffsetInDataVector;
        for (auto i = 0u; i < numValuesToScan; i++) {
            // Nulls are scanned to the resultVector first
            if (!resultVector->isNull(i)) {
                auto startListOffsetInStorage = listOffsetInfoInStorage.getListStartOffset(i);
                auto appendSize = listOffsetInfoInStorage.getListSize(i);
                dataColumn->scanSegment(state.childrenStates[DATA_COLUMN_CHILD_READ_STATE_IDX],
                    startListOffsetInStorage, appendSize, dataVector, offsetInDataVector);
                offsetInDataVector += appendSize;
            }
        }
    }
}

void ListColumn::scanFiltered(const SegmentState& state, offset_t startOffsetInSegment,
    ValueVector* resultVector, const ListOffsetSizeInfo& listOffsetSizeInfo,
    offset_t offsetInResult) const {
    auto dataVector = ListVector::getDataVector(resultVector);
    auto startOffsetInDataVector = ListVector::getDataVectorSize(resultVector);
    auto offsetInDataVector = startOffsetInDataVector;

    for (sel_t i = 0; i < resultVector->state->getSelVector().getSelSize(); i++) {
        auto pos = resultVector->state->getSelVector()[i];
        if (startOffsetInSegment + pos - offsetInResult < state.metadata.numValues) {
            // The listOffsetSizeInfo starts with the first value being scanned, so the
            // startOffsetInSegment parameter is not needed here except for the bounds check
            auto listSize = listOffsetSizeInfo.getListSize(pos - offsetInResult);
            resultVector->setValue(pos, list_entry_t{(offset_t)offsetInDataVector, listSize});
            offsetInDataVector += listSize;
        }
    }
    ListVector::resizeDataVector(resultVector, offsetInDataVector);
    offsetInDataVector = startOffsetInDataVector;
    for (auto i = 0u; i < resultVector->state->getSelVector().getSelSize(); i++) {
        auto pos = resultVector->state->getSelVector()[i];
        // Nulls are scanned to the resultVector first
        if (pos >= offsetInResult &&
            startOffsetInSegment + pos - offsetInResult < state.metadata.numValues &&
            !resultVector->isNull(pos)) {
            auto startOffsetInStorageToScan =
                listOffsetSizeInfo.getListStartOffset(pos - offsetInResult);
            auto appendSize = listOffsetSizeInfo.getListSize(pos - offsetInResult);
            // If there is a selection vector for the dataVector, its selected positions are not
            // being updated at all for this specific segment
            KU_ASSERT(!dataVector->state || dataVector->state->getSelVector().isUnfiltered());
            dataColumn->scanSegment(state.childrenStates[DATA_COLUMN_CHILD_READ_STATE_IDX],
                startOffsetInStorageToScan, appendSize, dataVector, offsetInDataVector);
            offsetInDataVector += resultVector->getValue<list_entry_t>(pos).size;
        }
    }
}

offset_t ListColumn::readOffset(const SegmentState& state, offset_t offsetInNodeGroup) const {
    offset_t ret = INVALID_OFFSET;
    const auto& offsetState = state.childrenStates[OFFSET_COLUMN_CHILD_READ_STATE_IDX];
    offsetColumn->columnReadWriter->readCompressedValueToPage(offsetState, offsetInNodeGroup,
        reinterpret_cast<uint8_t*>(&ret), 0, offsetColumn->readToPageFunc);
    return ret;
}

list_size_t ListColumn::readSize(const SegmentState& readState, offset_t offsetInNodeGroup) const {
    const auto& sizeState = readState.childrenStates[SIZE_COLUMN_CHILD_READ_STATE_IDX];
    offset_t value = INVALID_OFFSET;
    sizeColumn->columnReadWriter->readCompressedValueToPage(sizeState, offsetInNodeGroup,
        reinterpret_cast<uint8_t*>(&value), 0, sizeColumn->readToPageFunc);
    return value;
}

ListOffsetSizeInfo ListColumn::getListOffsetSizeInfo(const SegmentState& state,
    offset_t startOffsetInSegment, offset_t numOffsetsToRead) const {
    auto offsetColumnChunk = ColumnChunkFactory::createColumnChunkData(*mm, LogicalType::INT64(),
        enableCompression, numOffsetsToRead, ResidencyState::IN_MEMORY);
    auto sizeColumnChunk = ColumnChunkFactory::createColumnChunkData(*mm, LogicalType::UINT32(),
        enableCompression, numOffsetsToRead, ResidencyState::IN_MEMORY);
    offsetColumn->scanSegment(state.childrenStates[OFFSET_COLUMN_CHILD_READ_STATE_IDX],
        offsetColumnChunk.get(), startOffsetInSegment, numOffsetsToRead);
    sizeColumn->scanSegment(state.childrenStates[SIZE_COLUMN_CHILD_READ_STATE_IDX],
        sizeColumnChunk.get(), startOffsetInSegment, numOffsetsToRead);
    auto numValuesScan = offsetColumnChunk->getNumValues();
    return {numValuesScan, std::move(offsetColumnChunk), std::move(sizeColumnChunk)};
}

static void appendDataCheckpointState(
    std::vector<SegmentCheckpointState>& listDataChunkCheckpointStates, ColumnChunkData& dataChunk,
    offset_t inputOffset, offset_t& outputOffset, offset_t numRows) {
    if (numRows > 0) {
        listDataChunkCheckpointStates.push_back(
            SegmentCheckpointState{dataChunk, inputOffset, outputOffset, numRows});
        outputOffset += numRows;
    }
}

static std::vector<SegmentCheckpointState> createListDataChunkCheckpointStates(
    ListChunkData& persistentListChunk, std::span<SegmentCheckpointState> segmentCheckpointStates) {
    const auto persistentDataChunk = persistentListChunk.getDataColumnChunk();
    row_idx_t newListDataSize = persistentDataChunk->getNumValues();

    std::vector<SegmentCheckpointState> listDataChunkCheckpointStates;
    for (const auto& segmentCheckpointState : segmentCheckpointStates) {
        // We append the data for each list entry as separate segment checkpoint states
        // List entries with adjacent data are commbined into a single segment checkpoint state
        const auto& listChunk = segmentCheckpointState.chunkData.cast<ListChunkData>();
        offset_t currentSegmentStartOffset = INVALID_OFFSET;
        offset_t currentSegmentNumRows = 0;
        for (offset_t i = 0; i < segmentCheckpointState.numRows; i++) {
            if (listChunk.isNull(segmentCheckpointState.startRowInData + i)) {
                // Nulls will have 0 length and start at pos 0, which will work with the logic
                // below, but may create more checkpoint states than necessary
                continue;
            }
            const auto currentListStartOffset =
                listChunk.getListStartOffset(segmentCheckpointState.startRowInData + i);
            const auto currentListLength =
                listChunk.getListSize(segmentCheckpointState.startRowInData + i);
            if (currentSegmentStartOffset + currentSegmentNumRows == currentListStartOffset) {
                currentSegmentNumRows += currentListLength;
            } else {
                appendDataCheckpointState(listDataChunkCheckpointStates,
                    *listChunk.getDataColumnChunk(), currentSegmentStartOffset, newListDataSize,
                    currentSegmentNumRows);
                currentSegmentStartOffset = currentListStartOffset;
                currentSegmentNumRows = currentListLength;
            }
        }
        appendDataCheckpointState(listDataChunkCheckpointStates, *listChunk.getDataColumnChunk(),
            currentSegmentStartOffset, newListDataSize, currentSegmentNumRows);
    }

    return listDataChunkCheckpointStates;
}

std::vector<std::unique_ptr<ColumnChunkData>> ListColumn::checkpointSegment(
    ColumnCheckpointState&& checkpointState, PageAllocator& pageAllocator,
    bool canSplitSegment) const {
    if (checkpointState.segmentCheckpointStates.empty()) {
        return {};
    }
    auto& persistentListChunk = checkpointState.persistentData.cast<ListChunkData>();
    const auto persistentDataChunk = persistentListChunk.getDataColumnChunk();

    auto listDataChunkCheckpointStates = createListDataChunkCheckpointStates(persistentListChunk,
        checkpointState.segmentCheckpointStates);

    // First, check if we can checkpoint list data chunk in place.
    SegmentState chunkState;
    checkpointState.persistentData.initializeScanState(chunkState, this);
    ColumnCheckpointState listDataCheckpointState(*persistentDataChunk,
        std::move(listDataChunkCheckpointStates));
    const auto listDataCanCheckpointInPlace = dataColumn->canCheckpointInPlace(
        chunkState.childrenStates[ListChunkData::DATA_COLUMN_CHILD_READ_STATE_IDX],
        listDataCheckpointState);
    if (!listDataCanCheckpointInPlace) {
        // If we cannot checkpoint list data chunk in place, we need to checkpoint the whole chunk
        // out of place.
        return checkpointColumnChunkOutOfPlace(chunkState, checkpointState, pageAllocator,
            canSplitSegment);
    }

    const auto persistentListDataSize = persistentDataChunk->getNumValues();

    // In place checkpoint for list data.
    dataColumn->checkpointColumnChunkInPlace(
        chunkState.childrenStates[ListChunkData::DATA_COLUMN_CHILD_READ_STATE_IDX],
        listDataCheckpointState, pageAllocator);

    // Checkpoint offset data.
    std::vector<SegmentCheckpointState> offsetChunkCheckpointStates;

    KU_ASSERT(std::is_sorted(checkpointState.segmentCheckpointStates.begin(),
        checkpointState.segmentCheckpointStates.end(),
        [](const auto& a, const auto& b) { return a.startRowInData < b.startRowInData; }));
    std::vector<std::unique_ptr<ColumnChunkData>> offsetsToWrite;
    uint64_t totalAppendedListSize = 0;
    for (const auto& segmentCheckpointState : checkpointState.segmentCheckpointStates) {
        offsetsToWrite.push_back(
            ColumnChunkFactory::createColumnChunkData(*mm, LogicalType::UINT64(), false,
                segmentCheckpointState.numRows, ResidencyState::IN_MEMORY));
        const auto& listChunk = segmentCheckpointState.chunkData.cast<ListChunkData>();
        for (auto i = 0u; i < segmentCheckpointState.numRows; i++) {
            // When checkpointing the data chunks we append each list in the checkpoint state to the
            // end of the data This loop processes the lists in the same order, so the offsets match
            // the ones used by the data chunk checkpoint
            totalAppendedListSize +=
                listChunk.getListSize(segmentCheckpointState.startRowInData + i);
            offsetsToWrite.back()->setValue<offset_t>(
                persistentListDataSize + totalAppendedListSize, i);
        }
        offsetChunkCheckpointStates.push_back(SegmentCheckpointState{*offsetsToWrite.back(), 0,
            segmentCheckpointState.offsetInSegment, segmentCheckpointState.numRows});
    }

    // We do not allow nested splitting of offset/size segments
    offsetColumn->checkpointSegment(
        ColumnCheckpointState(*persistentListChunk.getOffsetColumnChunk(),
            std::move(offsetChunkCheckpointStates)),
        pageAllocator, false);

    // Checkpoint size data.
    std::vector<SegmentCheckpointState> sizeChunkCheckpointStates;
    for (const auto& segmentCheckpointState : checkpointState.segmentCheckpointStates) {
        sizeChunkCheckpointStates.push_back(SegmentCheckpointState{
            *segmentCheckpointState.chunkData.cast<ListChunkData>().getSizeColumnChunk(),
            segmentCheckpointState.startRowInData, segmentCheckpointState.offsetInSegment,
            segmentCheckpointState.numRows});
    }
    sizeColumn->checkpointSegment(ColumnCheckpointState(*persistentListChunk.getSizeColumnChunk(),
                                      std::move(sizeChunkCheckpointStates)),
        pageAllocator, false);
    // Checkpoint null data.
    Column::checkpointNullData(checkpointState, pageAllocator);

    KU_ASSERT(persistentListChunk.getNullData()->getNumValues() ==
                  persistentListChunk.getOffsetColumnChunk()->getNumValues() &&
              persistentListChunk.getNullData()->getNumValues() ==
                  persistentListChunk.getSizeColumnChunk()->getNumValues());

    persistentListChunk.syncNumValues();
    return {};
}

} // namespace storage
} // namespace kuzu
