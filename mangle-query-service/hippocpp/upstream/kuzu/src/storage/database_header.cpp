#include "storage/database_header.h"

/**
 * P3-203: DatabaseHeader - Extended Implementation Documentation
 * 
 * Additional Details (see P2-65 for version validation design)
 * 
 * DatabaseHeader Structure:
 * ```
 * DatabaseHeader {
 *   catalogPageRange: PageRange   // Pages for serialized catalog
 *   metadataPageRange: PageRange  // Pages for table metadata
 *   databaseID: ku_uuid_t         // Unique database identifier
 * }
 * ```
 * 
 * Header Serialization Format:
 * ```
 * [MAGIC_BYTES (4)]["storage_version"][version: storage_version_t]
 * ["catalog"][startPageIdx][numPages]
 * ["metadata"][startPageIdx][numPages]
 * ["databaseID"][uuid.value]
 * ```
 * 
 * validateMagicBytes() Algorithm:
 * ```
 * validateMagicBytes(deSer):
 *   magicBytes = read 4 bytes
 *   IF memcmp(magicBytes, "KUZU") != 0:
 *     THROW "Not a valid Kuzu database file"
 * ```
 * 
 * validateStorageVersion() Algorithm:
 * ```
 * validateStorageVersion(deSer):
 *   savedVersion = read storage_version_t
 *   currentVersion = StorageVersionInfo::getStorageVersion()
 *   IF savedVersion != currentVersion:
 *     THROW "Version mismatch: saved={saved}, current={current}"
 * ```
 * 
 * readDatabaseHeader() Flow:
 * ```
 * readDatabaseHeader(fileInfo):
 *   IF fileInfo.getFileSize() < KUZU_PAGE_SIZE:
 *     RETURN nullopt  // No header yet
 *   
 *   TRY:
 *     reader = BufferedFileReader(fileInfo)
 *     RETURN deserialize(reader)
 *   CATCH RuntimeException:
 *     // Magic bytes check failed - no valid header
 *     RETURN nullopt
 * ```
 * 
 * createInitialHeader() Flow:
 * ```
 * createInitialHeader(randomEngine):
 *   uuid = UUID::generateRandomUUID(randomEngine)
 *   RETURN DatabaseHeader{{}, {}, uuid}
 * ```
 * 
 * Page Range Management:
 * ```
 * updateCatalogPageRange(pageManager, newRange):
 *   IF catalogPageRange.startPageIdx != INVALID:
 *     pageManager.freePageRange(catalogPageRange)  // Free old
 *   catalogPageRange = newRange  // Set new
 * 
 * freeMetadataPageRange(pageManager):
 *   IF metadataPageRange.startPageIdx != INVALID:
 *     pageManager.freePageRange(metadataPageRange)
 * ```
 * 
 * Usage in Recovery:
 * ```
 * 1. Database opens file
 * 2. readDatabaseHeader() attempts to load header
 * 3. IF header exists:
 *      - Validate magic bytes
 *      - Validate storage version
 *      - Load catalog/metadata page ranges
 *    ELSE:
 *      - Create initial header with new UUID
 * ```
 * 
 * ====================================
 * See P2-65 inline for storage version validation design.
 */

#include <cstring>

#include "common/exception/runtime.h"
#include "common/file_system/file_info.h"
#include "common/serializer/buffered_file.h"
#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "common/system_config.h"
#include "main/client_context.h"
#include "storage/page_manager.h"
#include "storage/storage_version_info.h"

namespace kuzu::storage {
/**
 * P2-65: Storage Version Validation
 * 
 * This function validates that the database file's storage version matches
 * the current build's expected version.
 * 
 * When This Error Occurs:
 * - User tries to open a database created with a different Kuzu version
 * - Database file was created with an older/newer storage format
 * - Binary incompatible changes were made between versions
 * 
 * Test Case Considerations:
 * The TODO suggests adding a test for version mismatch scenarios.
 * 
 * Proposed Test Scenarios:
 * 1. Version Mismatch Test:
 *    - Create a mock database header with wrong version
 *    - Attempt to deserialize
 *    - Assert RuntimeException is thrown with correct message
 * 
 * 2. Future Version Test:
 *    - Header with version > current (forward incompatible)
 *    - Should fail with clear error message
 * 
 * 3. Past Version Test:
 *    - Header with version < current (backward incompatible)
 *    - Should fail with migration suggestion
 * 
 * Why Test Is Important:
 * - Users upgrading Kuzu need clear feedback
 * - Prevents data corruption from version mismatches
 * - Error message helps users understand the issue
 * 
 * Test Implementation Notes:
 * - Test file: test/storage/database_header_test.cpp
 * - Mock the serialized header with different version
 * - Use EXPECT_THROW with RuntimeException
 * - Verify error message contains both versions
 * 
 * Current Behavior (works correctly):
 * - Compares saved version against current build version
 * - Throws clear error with both version numbers
 * - Allows user to understand the incompatibility
 */
static void validateStorageVersion(common::Deserializer& deSer) {
    std::string key;
    deSer.validateDebuggingInfo(key, "storage_version");
    storage_version_t savedStorageVersion = 0;
    deSer.deserializeValue(savedStorageVersion);
    const auto storageVersion = StorageVersionInfo::getStorageVersion();
    if (savedStorageVersion != storageVersion) {
        throw common::RuntimeException(
            common::stringFormat("Trying to read a database file with a different version. "
                                 "Database file version: {}, Current build storage version: {}",
                savedStorageVersion, storageVersion));
    }
}

static void validateMagicBytes(common::Deserializer& deSer) {
    std::string key;
    deSer.validateDebuggingInfo(key, "magic");
    const auto numMagicBytes = strlen(StorageVersionInfo::MAGIC_BYTES);
    uint8_t magicBytes[4];
    for (auto i = 0u; i < numMagicBytes; i++) {
        deSer.deserializeValue<uint8_t>(magicBytes[i]);
    }
    if (memcmp(magicBytes, StorageVersionInfo::MAGIC_BYTES, numMagicBytes) != 0) {
        throw common::RuntimeException(
            "Unable to open database. The file is not a valid Kuzu database file!");
    }
}

void DatabaseHeader::updateCatalogPageRange(PageManager& pageManager, PageRange newPageRange) {
    if (catalogPageRange.startPageIdx != common::INVALID_PAGE_IDX) {
        pageManager.freePageRange(catalogPageRange);
    }
    catalogPageRange = newPageRange;
}

void DatabaseHeader::freeMetadataPageRange(PageManager& pageManager) const {
    if (metadataPageRange.startPageIdx != common::INVALID_PAGE_IDX) {
        pageManager.freePageRange(metadataPageRange);
    }
}

static void writeMagicBytes(common::Serializer& serializer) {
    serializer.writeDebuggingInfo("magic");
    const auto numMagicBytes = strlen(StorageVersionInfo::MAGIC_BYTES);
    for (auto i = 0u; i < numMagicBytes; i++) {
        serializer.serializeValue<uint8_t>(StorageVersionInfo::MAGIC_BYTES[i]);
    }
}

void DatabaseHeader::serialize(common::Serializer& ser) const {
    writeMagicBytes(ser);
    ser.writeDebuggingInfo("storage_version");
    ser.serializeValue(StorageVersionInfo::getStorageVersion());
    ser.writeDebuggingInfo("catalog");
    ser.serializeValue(catalogPageRange.startPageIdx);
    ser.serializeValue(catalogPageRange.numPages);
    ser.writeDebuggingInfo("metadata");
    ser.serializeValue(metadataPageRange.startPageIdx);
    ser.serializeValue(metadataPageRange.numPages);
    ser.writeDebuggingInfo("databaseID");
    ser.serializeValue(databaseID.value);
}

DatabaseHeader DatabaseHeader::deserialize(common::Deserializer& deSer) {
    validateMagicBytes(deSer);
    validateStorageVersion(deSer);
    PageRange catalogPageRange{}, metaPageRange{};
    common::ku_uuid_t databaseID{};
    std::string key;
    deSer.validateDebuggingInfo(key, "catalog");
    deSer.deserializeValue(catalogPageRange.startPageIdx);
    deSer.deserializeValue(catalogPageRange.numPages);
    deSer.validateDebuggingInfo(key, "metadata");
    deSer.deserializeValue(metaPageRange.startPageIdx);
    deSer.deserializeValue(metaPageRange.numPages);
    deSer.validateDebuggingInfo(key, "databaseID");
    deSer.deserializeValue(databaseID.value);
    return {catalogPageRange, metaPageRange, databaseID};
}

DatabaseHeader DatabaseHeader::createInitialHeader(common::RandomEngine* randomEngine) {
    // We generate a random UUID to act as the database ID
    return DatabaseHeader{{}, {}, common::UUID::generateRandomUUID(randomEngine)};
}

std::optional<DatabaseHeader> DatabaseHeader::readDatabaseHeader(common::FileInfo& dataFileInfo) {
    if (dataFileInfo.getFileSize() < common::KUZU_PAGE_SIZE) {
        // If the data file hasn't been written to there is no existing database header
        return std::nullopt;
    }
    auto reader = std::make_unique<common::BufferedFileReader>(dataFileInfo);
    common::Deserializer deSer(std::move(reader));
    try {
        return DatabaseHeader::deserialize(deSer);
    } catch (const common::RuntimeException&) {
        // It is possible we optimistically write to the database file before the first checkpoint
        // In this case the magic bytes check will fail and we assume there is no existing header
        return std::nullopt;
    }
}
} // namespace kuzu::storage
