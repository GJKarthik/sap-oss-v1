#include "storage/wal/checksum_writer.h"

/**
 * P3-208: ChecksumWriter - WAL Entry Checksum Writer
 * 
 * Purpose:
 * Wraps a Writer to add checksum computation for WAL entries.
 * Computes checksum over each object and appends it to output.
 * Used to detect WAL corruption during replay.
 * 
 * Architecture:
 * ```
 * ChecksumWriter : Writer {
 *   outputSerializer: Serializer  // Wrapped output writer
 *   entryBuffer: unique_ptr<MemoryBuffer>  // Buffer for current entry
 *   currentEntrySize: optional<uint64_t>   // Size during object write
 * }
 * ```
 * 
 * Output Format:
 * ```
 * [ObjectData][Checksum: hash_t]
 * ```
 * 
 * onObjectBegin() / onObjectEnd() Pattern:
 * ```
 * onObjectBegin():
 *   currentEntrySize = 0  // Start buffering
 * 
 * write(data, size):
 *   IF currentEntrySize.has_value():
 *     // Buffering mode - collect data
 *     resizeBufferIfNeeded(currentEntrySize + size)
 *     memcpy(entryBuffer + currentEntrySize, data, size)
 *     currentEntrySize += size
 *   ELSE:
 *     // Pass-through mode (no checksum)
 *     outputSerializer.write(data, size)
 * 
 * onObjectEnd():
 *   checksum = common::checksum(entryBuffer, currentEntrySize)
 *   outputSerializer.write(entryBuffer, currentEntrySize)
 *   outputSerializer.write(checksum)
 *   currentEntrySize = nullopt  // End buffering
 * ```
 * 
 * Buffer Resize Logic:
 * ```
 * resizeBufferIfNeeded(buffer, requestedSize):
 *   IF requestedSize > buffer.size:
 *     newSize = bit_ceil(requestedSize)  // Next power of 2
 *     buffer = memoryManager.allocateBuffer(newSize)
 * ```
 * 
 * Checksum Algorithm:
 * - Uses common::checksum() (hash function)
 * - Computed over entire entry data
 * - Appended as hash_t after entry
 * 
 * WAL Write Flow:
 * ```
 * WAL.addNewWALRecordNoLock(record):
 *   writer.onObjectBegin()      // Start buffering
 *   record.serialize(writer)    // All writes go to buffer
 *   writer.onObjectEnd()        // Compute checksum, write both
 * ```
 * 
 * Methods:
 * | Method | Description |
 * |--------|-------------|
 * | write() | Buffer or pass-through based on state |
 * | onObjectBegin() | Start buffering for checksum |
 * | onObjectEnd() | Compute/write checksum, flush buffer |
 * | clear() | Reset state and output |
 * | flush() | Flush output writer |
 * | sync() | Sync output to disk |
 * | getSize() | Current buffer + output size |
 * 
 * Usage:
 * ```cpp
 * auto writer = std::make_shared<ChecksumWriter>(outputWriter, mm);
 * Serializer serializer(writer);
 * 
 * writer->onObjectBegin();
 * serializer.write(...);  // Buffered
 * writer->onObjectEnd();   // Checksum computed
 * ```
 */

#include <cstring>

#include "common/checksum.h"
#include "common/serializer/serializer.h"
#include <bit>

namespace kuzu::storage {
static constexpr uint64_t INITIAL_BUFFER_SIZE = common::KUZU_PAGE_SIZE;

ChecksumWriter::ChecksumWriter(std::shared_ptr<common::Writer> outputWriter,
    MemoryManager& memoryManager)
    : outputSerializer(std::move(outputWriter)),
      entryBuffer(memoryManager.allocateBuffer(false, INITIAL_BUFFER_SIZE)) {}

static void resizeBufferIfNeeded(std::unique_ptr<MemoryBuffer>& entryBuffer,
    uint64_t requestedSize) {
    const auto currentBufferSize = entryBuffer->getBuffer().size_bytes();
    if (requestedSize > currentBufferSize) {
        auto* memoryManager = entryBuffer->getMemoryManager();
        entryBuffer = memoryManager->allocateBuffer(false, std::bit_ceil(requestedSize));
    }
}

void ChecksumWriter::write(const uint8_t* data, uint64_t size) {
    if (currentEntrySize.has_value()) {
        resizeBufferIfNeeded(entryBuffer, *currentEntrySize + size);
        std::memcpy(entryBuffer->getData() + *currentEntrySize, data, size);
        *currentEntrySize += size;
    } else {
        // The data we are writing does not need to be checksummed
        outputSerializer.write(data, size);
    }
}

void ChecksumWriter::clear() {
    currentEntrySize.reset();
    outputSerializer.getWriter()->clear();
}

void ChecksumWriter::flush() {
    outputSerializer.getWriter()->flush();
}

void ChecksumWriter::onObjectBegin() {
    currentEntrySize.emplace(0);
}

void ChecksumWriter::onObjectEnd() {
    KU_ASSERT(currentEntrySize.has_value());
    const auto checksum = common::checksum(entryBuffer->getData(), *currentEntrySize);
    outputSerializer.write(entryBuffer->getData(), *currentEntrySize);
    outputSerializer.serializeValue(checksum);
    currentEntrySize.reset();
}

uint64_t ChecksumWriter::getSize() const {
    return currentEntrySize.value_or(0) + outputSerializer.getWriter()->getSize();
}

void ChecksumWriter::sync() {
    outputSerializer.getWriter()->sync();
}

} // namespace kuzu::storage
