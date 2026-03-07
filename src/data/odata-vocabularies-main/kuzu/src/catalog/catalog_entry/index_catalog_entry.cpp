#include "catalog/catalog_entry/index_catalog_entry.h"

/**
 * P3-144: IndexCatalogEntry - Secondary Index Metadata
 * 
 * Purpose:
 * Catalog entry for secondary indexes on node table properties.
 * Stores index definition, target table/properties, and auxiliary
 * index-specific data for lazy loading.
 * 
 * Architecture:
 * ```
 * CatalogEntry (base)
 *   └── IndexCatalogEntry
 *         ├── type: string              // Index type (e.g., "HNSW")
 *         ├── tableID: table_id_t       // Target node table
 *         ├── indexName: string         // User-defined name
 *         ├── propertyIDs: vector<property_id_t>  // Indexed properties
 *         ├── auxInfo: unique_ptr<IndexAuxInfo>   // Loaded index data
 *         ├── auxBuffer: unique_ptr<uint8_t[]>    // Serialized index
 *         └── auxBufferSize: uint64_t
 * ```
 * 
 * Index States:
 * ```
 * Loaded:   auxInfo != nullptr (index structure in memory)
 * Unloaded: auxBuffer != nullptr (serialized form on disk)
 * 
 * isLoaded() → auxInfo != nullptr
 * ```
 * 
 * Internal Name:
 * ```
 * getInternalIndexName(tableID, indexName):
 *   → "{tableID}_{indexName}"
 * 
 * Example: Table 5, Index "vec_idx"
 *   → "5_vec_idx"
 * ```
 * 
 * Key Operations:
 * 
 * 1. setAuxInfo(auxInfo):
 *    - Set loaded index structure
 *    - Clears auxBuffer (now loaded)
 * 
 * 2. containsPropertyID(propertyID):
 *    - Check if property is indexed
 *    - Used for query optimization
 * 
 * 3. serialize():
 *    - If loaded: serialize auxInfo via BufferWriter
 *    - If unloaded: write auxBuffer directly
 * 
 * 4. deserialize():
 *    - Read metadata + auxBuffer
 *    - Index stays unloaded until query needs it
 * 
 * 5. getAuxBufferReader():
 *    - Create BufferReader for lazy index loading
 *    - Throws if auxBuffer not set
 * 
 * 6. copyFrom():
 *    - Deep copy including auxInfo
 *    - For version chain management
 * 
 * IndexAuxInfo (base class):
 * - Virtual serialize() → returns BufferWriter
 * - Subclassed by specific index types (HNSW, etc.)
 * 
 * Usage:
 * ```cpp
 * // Create index
 * CREATE INDEX vec_idx ON Person(embedding) USING HNSW
 * 
 * // Lookup
 * auto* idx = catalog->getIndex(txn, tableID, "vec_idx");
 * if (!idx->isLoaded()) {
 *     auto reader = idx->getAuxBufferReader();
 *     // Load index structure from reader
 * }
 * ```
 * 
 * Entry Type:
 * - CatalogEntryType::INDEX_ENTRY
 */

#include "common/exception/runtime.h"
#include "common/serializer/buffer_writer.h"

namespace kuzu {
namespace catalog {

std::shared_ptr<common::BufferWriter> IndexAuxInfo::serialize() const {
    return std::make_shared<common::BufferWriter>(0 /*maximumSize*/);
}

void IndexCatalogEntry::setAuxInfo(std::unique_ptr<IndexAuxInfo> auxInfo_) {
    auxInfo = std::move(auxInfo_);
    auxBuffer = nullptr;
    auxBufferSize = 0;
}

bool IndexCatalogEntry::containsPropertyID(common::property_id_t propertyID) const {
    for (auto id : propertyIDs) {
        if (id == propertyID) {
            return true;
        }
    }
    return false;
}

void IndexCatalogEntry::serialize(common::Serializer& serializer) const {
    CatalogEntry::serialize(serializer);
    serializer.write(type);
    serializer.write(tableID);
    serializer.write(indexName);
    serializer.serializeVector(propertyIDs);
    if (isLoaded()) {
        const auto bufferedWriter = auxInfo->serialize();
        serializer.write<uint64_t>(bufferedWriter->getSize());
        serializer.write(bufferedWriter->getData().data.get(), bufferedWriter->getSize());
    } else {
        serializer.write(auxBufferSize);
        serializer.write(auxBuffer.get(), auxBufferSize);
    }
}

std::unique_ptr<IndexCatalogEntry> IndexCatalogEntry::deserialize(
    common::Deserializer& deserializer) {
    std::string type;
    common::table_id_t tableID = common::INVALID_TABLE_ID;
    std::string indexName;
    std::vector<common::property_id_t> propertyIDs;
    deserializer.deserializeValue(type);
    deserializer.deserializeValue(tableID);
    deserializer.deserializeValue(indexName);
    deserializer.deserializeVector(propertyIDs);
    auto indexEntry = std::make_unique<IndexCatalogEntry>(type, tableID, std::move(indexName),
        std::move(propertyIDs), nullptr /* auxInfo */);
    uint64_t auxBufferSize = 0;
    deserializer.deserializeValue(auxBufferSize);
    indexEntry->auxBuffer = std::make_unique<uint8_t[]>(auxBufferSize);
    indexEntry->auxBufferSize = auxBufferSize;
    deserializer.read(indexEntry->auxBuffer.get(), auxBufferSize);
    return indexEntry;
}

void IndexCatalogEntry::copyFrom(const CatalogEntry& other) {
    CatalogEntry::copyFrom(other);
    auto& otherTable = other.constCast<IndexCatalogEntry>();
    tableID = otherTable.tableID;
    indexName = otherTable.indexName;
    if (auxInfo) {
        auxInfo = otherTable.auxInfo->copy();
    }
}
std::unique_ptr<common::BufferReader> IndexCatalogEntry::getAuxBufferReader() const {
    // LCOV_EXCL_START
    if (!auxBuffer) {
        throw common::RuntimeException(
            common::stringFormat("Auxiliary buffer for index \"{}\" is not set.", indexName));
    }
    // LCOV_EXCL_STOP
    return std::make_unique<common::BufferReader>(auxBuffer.get(), auxBufferSize);
}

} // namespace catalog
} // namespace kuzu
