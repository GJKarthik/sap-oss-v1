#include "storage/table/dictionary_chunk.h"

/**
 * P2-120: Dictionary Chunk - String Dictionary Encoding
 * 
 * Purpose:
 * Implements dictionary encoding for string columns to achieve space efficiency
 * by deduplicating repeated strings. Each unique string is stored once, and
 * references use compact integer indices.
 * 
 * Architecture:
 * ```
 * DictionaryChunk
 *   ├── stringDataChunk: ColumnChunkData<UINT8>  // Concatenated string bytes
 *   ├── offsetChunk: ColumnChunkData<UINT64>     // Start offset for each string
 *   ├── indexTable: unordered_set<StringOps>     // Deduplication hash table
 *   └── enableCompression: bool                  // Whether to deduplicate
 * 
 * Storage Layout:
 * ┌─────────────────────────────────────────────────────────┐
 * │ offsetChunk:     [0, 5, 10, 15]                         │
 * │ stringDataChunk: "HelloWorldTest..."                    │
 * │                   ^^^^^          <- index 0: "Hello"    │
 * │                        ^^^^^     <- index 1: "World"    │
 * │                             ^^^^ <- index 2: "Test"     │
 * └─────────────────────────────────────────────────────────┘
 * ```
 * 
 * Key Operations:
 * 
 * 1. appendString(val):
 *    - Check indexTable for existing string (O(1) average)
 *    - If found and compression enabled, return existing index
 *    - Otherwise append to stringDataChunk, add offset to offsetChunk
 *    - Insert into indexTable for future deduplication
 * 
 * 2. getString(index):
 *    - Lookup start offset from offsetChunk[index]
 *    - Calculate length from offsetChunk[index+1] - offsetChunk[index]
 *    - Return string_view into stringDataChunk
 * 
 * 3. getStringLength(index):
 *    - For index < numStrings-1: offset[index+1] - offset[index]
 *    - For last string: stringDataChunk.numValues - offset[index]
 * 
 * Deduplication Strategy:
 * - StringOps provides hash and equality for indexTable
 * - Uses string_view to avoid copying during lookup
 * - Only deduplicates when enableCompression = true
 * 
 * Capacity Management:
 * - INITIAL_OFFSET_CHUNK_CAPACITY = 3 (not power of 2)
 * - Ensures always extra space for in-place updates
 * - stringDataChunk doubles via bit_ceil on overflow
 * - offsetChunk grows by CHUNK_RESIZE_RATIO (2x)
 * 
 * Memory Efficiency:
 * ```
 * Without dictionary: N * avg_string_length bytes
 * With dictionary:    unique_strings * avg_length + N * 8 bytes (indices)
 * Savings when:       repeated_ratio > 8 / avg_string_length
 * 
 * Example: 1000 names with 100 unique, avg 20 chars
 * Without: 1000 * 20 = 20,000 bytes
 * With:    100 * 20 + 1000 * 8 = 10,000 bytes (50% savings)
 * ```
 * 
 * Serialization:
 * - serialize(): Write offsetChunk then stringDataChunk
 * - deserialize(): Reconstruct both chunks, indexTable rebuilt on demand
 * 
 * Thread Safety:
 * - Not thread-safe by itself
 * - Protected by transaction/chunk-level locking
 */

#include "common/constants.h"
#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "storage/enums/residency_state.h"
#include <bit>

using namespace kuzu::common;

namespace kuzu {
namespace storage {

// The offset chunk is able to grow beyond the node group size.
// We rely on appending to the dictionary when updating, however if the chunk is full,
// there will be no space for in-place updates.
// The data chunk doubles in size on use, but out of place updates will never need the offset
// chunk to be greater than the node group size since they remove unused entries.
// So the chunk is initialized with a size equal to 3 so that the capacity is never resized to
// exactly the node group size (which is always a power of 2), making sure there is always extra
// space for updates.
static constexpr uint64_t INITIAL_OFFSET_CHUNK_CAPACITY = 3;

DictionaryChunk::DictionaryChunk(MemoryManager& mm, uint64_t capacity, bool enableCompression,
    ResidencyState residencyState)
    : enableCompression{enableCompression},
      indexTable(0, StringOps(this) /*hash*/, StringOps(this) /*equals*/) {
    // Bitpacking might save 1 bit per value with regular ascii compared to UTF-8
    stringDataChunk = ColumnChunkFactory::createColumnChunkData(mm, LogicalType::UINT8(),
        false /*enableCompression*/, 0, residencyState, false /*hasNullData*/);
    offsetChunk = ColumnChunkFactory::createColumnChunkData(mm, LogicalType::UINT64(),
        enableCompression, std::min(capacity, INITIAL_OFFSET_CHUNK_CAPACITY), residencyState,
        false /*hasNullData*/);
}

void DictionaryChunk::resetToEmpty() {
    stringDataChunk->resetToEmpty();
    offsetChunk->resetToEmpty();
    indexTable.clear();
}

uint64_t DictionaryChunk::getStringLength(string_index_t index) const {
    if (stringDataChunk->getNumValues() == 0) {
        return 0;
    }
    if (index + 1 < offsetChunk->getNumValues()) {
        KU_ASSERT(offsetChunk->getValue<string_offset_t>(index + 1) >=
                  offsetChunk->getValue<string_offset_t>(index));
        return offsetChunk->getValue<string_offset_t>(index + 1) -
               offsetChunk->getValue<string_offset_t>(index);
    }
    return stringDataChunk->getNumValues() - offsetChunk->getValue<string_offset_t>(index);
}

DictionaryChunk::string_index_t DictionaryChunk::appendString(std::string_view val) {
    const auto found = indexTable.find(val);
    // If the string already exists in the dictionary, skip it and refer to the existing string
    if (enableCompression && found != indexTable.end()) {
        return found->index;
    }
    const auto leftSpace = stringDataChunk->getCapacity() - stringDataChunk->getNumValues();
    if (leftSpace < val.size()) {
        stringDataChunk->resize(std::bit_ceil(stringDataChunk->getCapacity() + val.size()));
    }
    const auto startOffset = stringDataChunk->getNumValues();
    memcpy(stringDataChunk->getData() + startOffset, val.data(), val.size());
    stringDataChunk->setNumValues(startOffset + val.size());
    const auto index = offsetChunk->getNumValues();
    if (index >= offsetChunk->getCapacity()) {
        offsetChunk->resize(offsetChunk->getCapacity() == 0 ?
                                2 :
                                (offsetChunk->getCapacity() * CHUNK_RESIZE_RATIO));
    }
    offsetChunk->setValue<string_offset_t>(startOffset, index);
    offsetChunk->setNumValues(index + 1);
    if (enableCompression) {
        indexTable.insert({static_cast<string_index_t>(index)});
    }
    return index;
}

std::string_view DictionaryChunk::getString(string_index_t index) const {
    KU_ASSERT(index < offsetChunk->getNumValues());
    const auto startOffset = offsetChunk->getValue<string_offset_t>(index);
    const auto length = getStringLength(index);
    return std::string_view(reinterpret_cast<const char*>(stringDataChunk->getData()) + startOffset,
        length);
}

bool DictionaryChunk::sanityCheck() const {
    return offsetChunk->getNumValues() <= offsetChunk->getNumValues();
}

void DictionaryChunk::resetNumValuesFromMetadata() {
    stringDataChunk->resetNumValuesFromMetadata();
    offsetChunk->resetNumValuesFromMetadata();
}

uint64_t DictionaryChunk::getEstimatedMemoryUsage() const {
    return stringDataChunk->getEstimatedMemoryUsage() + offsetChunk->getEstimatedMemoryUsage();
}

void DictionaryChunk::flush(PageAllocator& pageAllocator) {
    stringDataChunk->flush(pageAllocator);
    offsetChunk->flush(pageAllocator);
}

void DictionaryChunk::serialize(Serializer& serializer) const {
    serializer.writeDebuggingInfo("offset_chunk");
    offsetChunk->serialize(serializer);
    serializer.writeDebuggingInfo("string_data_chunk");
    stringDataChunk->serialize(serializer);
}

std::unique_ptr<DictionaryChunk> DictionaryChunk::deserialize(MemoryManager& memoryManager,
    Deserializer& deSer) {
    auto chunk = std::make_unique<DictionaryChunk>(memoryManager, 0, true, ResidencyState::ON_DISK);
    std::string key;
    deSer.validateDebuggingInfo(key, "offset_chunk");
    chunk->offsetChunk = ColumnChunkData::deserialize(memoryManager, deSer);
    deSer.validateDebuggingInfo(key, "string_data_chunk");
    chunk->stringDataChunk = ColumnChunkData::deserialize(memoryManager, deSer);
    return chunk;
}

} // namespace storage
} // namespace kuzu
