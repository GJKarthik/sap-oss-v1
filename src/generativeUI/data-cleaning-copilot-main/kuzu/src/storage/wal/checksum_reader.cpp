#include "storage/wal/checksum_reader.h"

/**
 * P3-209: ChecksumReader - WAL Entry Checksum Validator
 * 
 * Purpose:
 * Wraps a Reader to validate checksums on WAL entries during replay.
 * Verifies data integrity by comparing stored vs computed checksums.
 * Throws StorageException on checksum mismatch (corruption detected).
 * 
 * Architecture:
 * ```
 * ChecksumReader : Reader {
 *   deserializer: Deserializer  // Wrapped file reader
 *   entryBuffer: unique_ptr<MemoryBuffer>  // Buffer for validation
 *   currentEntrySize: optional<uint64_t>   // Size during read
 *   checksumMismatchMessage: string_view   // Error message
 * }
 * ```
 * 
 * Expected Input Format:
 * ```
 * [ObjectData][Checksum: hash_t]
 * ```
 * 
 * onObjectBegin() / onObjectEnd() Pattern:
 * ```
 * onObjectBegin():
 *   currentEntrySize = 0  // Start tracking reads
 * 
 * read(data, size):
 *   deserializer.read(data, size)  // Read from file
 *   IF currentEntrySize.has_value():
 *     // Also copy to buffer for checksum computation
 *     resizeBufferIfNeeded(currentEntrySize + size)
 *     memcpy(entryBuffer + currentEntrySize, data, size)
 *     currentEntrySize += size
 * 
 * onObjectEnd():
 *   computedChecksum = common::checksum(entryBuffer, currentEntrySize)
 *   storedChecksum = deserializer.read<hash_t>()
 *   IF storedChecksum != computedChecksum:
 *     THROW StorageException(checksumMismatchMessage)
 *   currentEntrySize = nullopt
 * ```
 * 
 * Verification Flow:
 * ```
 * 1. onObjectBegin() - start tracking
 * 2. Multiple read() calls - read data, copy to buffer
 * 3. onObjectEnd() - compute checksum, compare with stored
 * 4. Throw if mismatch
 * ```
 * 
 * Error Handling:
 * - Checksum mismatch throws StorageException
 * - Custom error message provided at construction
 * - Indicates WAL corruption or truncation
 * 
 * WAL Replay Flow:
 * ```
 * WALReplayer::replay():
 *   reader.onObjectBegin()
 *   record = WALRecord::deserialize(reader)  // Reads buffered
 *   reader.onObjectEnd()  // Validates checksum
 *   // If no exception, record is valid
 * ```
 * 
 * Methods:
 * | Method | Description |
 * |--------|-------------|
 * | read() | Read and optionally buffer for checksum |
 * | onObjectBegin() | Start tracking for checksum |
 * | onObjectEnd() | Validate checksum, throw on mismatch |
 * | finished() | Check if end of file reached |
 * | getReadOffset() | Current file position |
 * 
 * Usage:
 * ```cpp
 * ChecksumReader reader(fileInfo, mm, "WAL corruption detected");
 * Deserializer deserializer(&reader);
 * 
 * while (!reader.finished()) {
 *   reader.onObjectBegin();
 *   auto record = WALRecord::deserialize(deserializer);
 *   reader.onObjectEnd();  // Throws on corruption
 * }
 * ```
 */

#include <cstring>

#include "common/checksum.h"
#include "common/exception/storage.h"
#include "common/serializer/buffered_file.h"
#include "common/serializer/deserializer.h"
#include <bit>

namespace kuzu::storage {
static constexpr uint64_t INITIAL_BUFFER_SIZE = common::KUZU_PAGE_SIZE;

ChecksumReader::ChecksumReader(common::FileInfo& fileInfo, MemoryManager& memoryManager,
    std::string_view checksumMismatchMessage)
    : deserializer(std::make_unique<common::BufferedFileReader>(fileInfo)),
      entryBuffer(memoryManager.allocateBuffer(false, INITIAL_BUFFER_SIZE)),
      checksumMismatchMessage(checksumMismatchMessage) {}

static void resizeBufferIfNeeded(std::unique_ptr<MemoryBuffer>& entryBuffer,
    uint64_t requestedSize) {
    const auto currentBufferSize = entryBuffer->getBuffer().size_bytes();
    if (requestedSize > currentBufferSize) {
        auto* memoryManager = entryBuffer->getMemoryManager();
        entryBuffer = memoryManager->allocateBuffer(false, std::bit_ceil(requestedSize));
    }
}

void ChecksumReader::read(uint8_t* data, uint64_t size) {
    deserializer.read(data, size);
    if (currentEntrySize.has_value()) {
        resizeBufferIfNeeded(entryBuffer, *currentEntrySize + size);
        std::memcpy(entryBuffer->getData() + *currentEntrySize, data, size);
        *currentEntrySize += size;
    }
}

bool ChecksumReader::finished() {
    return deserializer.finished();
}

void ChecksumReader::onObjectBegin() {
    currentEntrySize.emplace(0);
}

void ChecksumReader::onObjectEnd() {
    KU_ASSERT(currentEntrySize.has_value());
    const uint64_t computedChecksum = common::checksum(entryBuffer->getData(), *currentEntrySize);
    uint64_t storedChecksum{};
    deserializer.deserializeValue(storedChecksum);
    if (storedChecksum != computedChecksum) {
        throw common::StorageException(std::string{checksumMismatchMessage});
    }

    currentEntrySize.reset();
}

uint64_t ChecksumReader::getReadOffset() const {
    return deserializer.getReader()->cast<common::BufferedFileReader>()->getReadOffset();
}

} // namespace kuzu::storage
