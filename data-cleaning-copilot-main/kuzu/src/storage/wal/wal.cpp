#include "storage/wal/wal.h"

/**
 * P3-204: WAL - Extended Implementation Documentation
 * 
 * Additional Details (see P3-174 for architecture overview)
 * 
 * Constructor Parameters:
 * ```
 * WAL(dbPath, readOnly, enableChecksums, vfs):
 *   walPath = StorageUtils::getWALFilePath(dbPath)  // ".wal"
 *   inMemory = DBConfig::isDBPathInMemory(dbPath)   // ":memory:"
 *   store readOnly, vfs, enableChecksums
 * ```
 * 
 * logCommittedWAL() Algorithm:
 * ```
 * logCommittedWAL(localWAL, context):
 *   IF readOnly OR inMemory OR localWAL.size == 0:
 *     RETURN  // No logging needed
 *   
 *   LOCK mtx
 *   initWriter(context)  // Lazy init serializer
 *   localWAL.inMemWriter.flush(serializer.writer)
 *   flushAndSyncNoLock()  // Ensure durability
 * ```
 * 
 * logAndFlushCheckpoint() Algorithm:
 * ```
 * logAndFlushCheckpoint(context):
 *   LOCK mtx
 *   initWriter(context)
 *   addNewWALRecordNoLock(CheckpointRecord)
 *   flushAndSyncNoLock()
 * ```
 * 
 * initWriter() Flow:
 * ```
 * initWriter(context):
 *   IF serializer already exists: RETURN
 *   
 *   fileInfo = vfs.openFile(walPath, CREATE_IF_NOT_EXISTS | RW)
 *   writer = BufferedFileWriter(fileInfo)
 *   IF enableChecksums:
 *     writer = ChecksumWriter(writer, mm)  // Wrap for checksums
 *   serializer = new Serializer(writer)
 *   
 *   IF fileInfo.getFileSize() == 0:
 *     writeHeader(context)  // Write DB UUID + checksum flag
 *   
 *   // APPEND mode - don't overwrite existing records
 *   bufferedWriter.setFileOffset(fileInfo.getFileSize())
 * ```
 * 
 * writeHeader() Format:
 * ```
 * [ObjectBegin]
 *   [DatabaseID: ku_uuid_t]
 *   [enableChecksums: bool]
 * [ObjectEnd]
 * ```
 * 
 * addNewWALRecordNoLock() Format:
 * ```
 * addNewWALRecordNoLock(record):
 *   ASSERT type != INVALID_RECORD
 *   serializer.writer.onObjectBegin()
 *   record.serialize(serializer)
 *   serializer.writer.onObjectEnd()
 * ```
 * 
 * clear() vs reset():
 * | Method | Action | Use Case |
 * |--------|--------|----------|
 * | clear() | Clear buffer only | After checkpoint, keep file |
 * | reset() | Remove WAL file | Full cleanup, delete file |
 * 
 * Static Access:
 * ```cpp
 * WAL* wal = WAL::Get(context);
 * // Returns from context.getDatabase().getStorageManager().getWAL()
 * ```
 * 
 * ====================================
 * 
 * P3-174: WAL (Write-Ahead Log) - Durability and Recovery
 * 
 * Purpose:
 * Implements write-ahead logging for transaction durability. All changes
 * are logged to WAL before being applied, enabling crash recovery.
 * 
 * Architecture:
 * ```
 * WAL
 *   ├── walPath: string             // Path to .wal file
 *   ├── inMemory: bool              // Skip logging if in-memory DB
 *   ├── readOnly: bool              // Disable logging if read-only
 *   ├── enableChecksums: bool       // Enable checksum verification
 *   ├── fileInfo: unique_ptr<FileInfo>
 *   ├── serializer: unique_ptr<Serializer>
 *   ├── vfs: VirtualFileSystem*
 *   └── mtx: mutex                  // Thread safety
 * ```
 * 
 * WAL Record Types:
 * | Type | Description |
 * |------|-------------|
 * | CHECKPOINT | Marks checkpoint completion |
 * | COMMIT | Transaction commit record |
 * | PAGE_UPDATE | Page modification |
 * | CREATE_TABLE | DDL for new table |
 * | DROP_TABLE | DDL for table removal |
 * | LOAD_EXTENSION | Extension loading |
 * 
 * Key Operations:
 * 
 * 1. logCommittedWAL(localWAL, context):
 *    - Flushes local WAL to global WAL file
 *    - LocalWAL buffers transaction changes
 *    - Thread-safe with mutex lock
 * 
 * 2. logAndFlushCheckpoint(context):
 *    - Writes checkpoint record
 *    - Marks safe recovery point
 *    - Syncs WAL to disk
 * 
 * 3. clear():
 *    - Clears WAL buffer
 *    - After successful checkpoint
 * 
 * 4. reset():
 *    - Removes WAL file completely
 *    - Full WAL cleanup
 * 
 * WAL File Format:
 * ```
 * Header:
 *   - Database UUID
 *   - enableChecksums flag
 * 
 * Records (sequence):
 *   [ObjectBegin][Record Data][ObjectEnd]
 *   ...
 * ```
 * 
 * Checksum Support:
 * - Optional checksums via ChecksumWriter
 * - Wraps BufferedFileWriter
 * - Detects corruption during replay
 * 
 * Recovery Flow:
 * ```
 * Database Start
 *   │
 *   └── WALReplayer::replay()
 *         ├── Read header, verify DB UUID
 *         ├── For each record:
 *         │     └── Apply changes
 *         └── Stop at CHECKPOINT or EOF
 * ```
 * 
 * Thread Safety:
 * - Mutex protects all WAL operations
 * - One transaction commits at a time
 * - Local WAL per transaction for isolation
 * 
 * In-Memory Databases:
 * - WAL logging is skipped
 * - No durability guarantees
 * - Faster operation
 */

#include "common/file_system/file_info.h"
#include "common/file_system/virtual_file_system.h"
#include "common/serializer/buffered_file.h"
#include "common/serializer/in_mem_file_writer.h"
#include "main/client_context.h"
#include "main/database.h"
#include "main/db_config.h"
#include "storage/file_db_id_utils.h"
#include "storage/storage_manager.h"
#include "storage/storage_utils.h"
#include "storage/wal/checksum_writer.h"
#include "storage/wal/local_wal.h"

using namespace kuzu::common;

namespace kuzu {
namespace storage {

WAL::WAL(const std::string& dbPath, bool readOnly, bool enableChecksums, VirtualFileSystem* vfs)
    : walPath{StorageUtils::getWALFilePath(dbPath)},
      inMemory{main::DBConfig::isDBPathInMemory(dbPath)}, readOnly{readOnly}, vfs{vfs},
      enableChecksums(enableChecksums) {}

WAL::~WAL() {}

void WAL::logCommittedWAL(LocalWAL& localWAL, main::ClientContext* context) {
    KU_ASSERT(!readOnly);
    if (inMemory || localWAL.getSize() == 0) {
        return; // No need to log empty WAL.
    }
    std::unique_lock lck{mtx};
    initWriter(context);
    localWAL.inMemWriter->flush(*serializer->getWriter());
    flushAndSyncNoLock();
}

void WAL::logAndFlushCheckpoint(main::ClientContext* context) {
    std::unique_lock lck{mtx};
    initWriter(context);
    CheckpointRecord walRecord;
    addNewWALRecordNoLock(walRecord);
    flushAndSyncNoLock();
}

// NOLINTNEXTLINE(readability-make-member-function-const): semantically non-const function.
void WAL::clear() {
    std::unique_lock lck{mtx};
    serializer->getWriter()->clear();
}

void WAL::reset() {
    std::unique_lock lck{mtx};
    fileInfo.reset();
    serializer.reset();
    vfs->removeFileIfExists(walPath);
}

// NOLINTNEXTLINE(readability-make-member-function-const): semantically non-const function.
void WAL::flushAndSyncNoLock() {
    serializer->getWriter()->flush();
    serializer->getWriter()->sync();
}

uint64_t WAL::getFileSize() {
    std::unique_lock lck{mtx};
    return serializer->getWriter()->getSize();
}

void WAL::writeHeader(main::ClientContext& context) {
    serializer->getWriter()->onObjectBegin();
    FileDBIDUtils::writeDatabaseID(*serializer,
        StorageManager::Get(context)->getOrInitDatabaseID(context));
    serializer->write(enableChecksums);
    serializer->getWriter()->onObjectEnd();
}

void WAL::initWriter(main::ClientContext* context) {
    if (serializer) {
        return;
    }
    fileInfo = vfs->openFile(walPath,
        FileOpenFlags(FileFlags::CREATE_IF_NOT_EXISTS | FileFlags::READ_ONLY | FileFlags::WRITE),
        context);

    std::shared_ptr<Writer> writer = std::make_shared<BufferedFileWriter>(*fileInfo);
    auto& bufferedWriter = writer->cast<BufferedFileWriter>();
    if (enableChecksums) {
        writer = std::make_shared<ChecksumWriter>(std::move(writer), *MemoryManager::Get(*context));
    }
    serializer = std::make_unique<Serializer>(std::move(writer));

    // Write the databaseID at the start of the WAL if needed
    // This is used to ensure that when replaying the WAL matches the database
    if (fileInfo->getFileSize() == 0) {
        writeHeader(*context);
    }

    // WAL should always be APPEND only. We don't want to overwrite the file as it may still
    // contain records not replayed. This can happen if checkpoint is not triggered before the
    // Database is closed last time.
    bufferedWriter.setFileOffset(fileInfo->getFileSize());
}

// NOLINTNEXTLINE(readability-make-member-function-const): semantically non-const function.
void WAL::addNewWALRecordNoLock(const WALRecord& walRecord) {
    KU_ASSERT(walRecord.type != WALRecordType::INVALID_RECORD);
    KU_ASSERT(!inMemory);
    KU_ASSERT(serializer != nullptr);
    serializer->getWriter()->onObjectBegin();
    walRecord.serialize(*serializer);
    serializer->getWriter()->onObjectEnd();
}

WAL* WAL::Get(const main::ClientContext& context) {
    KU_ASSERT(context.getDatabase() && context.getDatabase()->getStorageManager());
    return &context.getDatabase()->getStorageManager()->getWAL();
}

} // namespace storage
} // namespace kuzu
