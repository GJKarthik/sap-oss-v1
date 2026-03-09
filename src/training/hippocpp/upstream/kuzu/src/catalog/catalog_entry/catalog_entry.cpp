#include "catalog/catalog_entry/catalog_entry.h"

/**
 * P3-147: CatalogEntry - Base Catalog Entry
 * 
 * Purpose:
 * Abstract base class for all catalog entries. Provides common fields
 * for identification, versioning, and serialization dispatch.
 * 
 * Inheritance Hierarchy:
 * ```
 * CatalogEntry (this)
 *   ├── TableCatalogEntry
 *   │     ├── NodeTableCatalogEntry
 *   │     └── RelGroupCatalogEntry
 *   ├── SequenceCatalogEntry
 *   ├── IndexCatalogEntry
 *   ├── TypeCatalogEntry
 *   ├── ScalarMacroCatalogEntry
 *   └── FunctionCatalogEntry (+ subclasses)
 * ```
 * 
 * Core Fields:
 * ```
 * CatalogEntry {
 *   type: CatalogEntryType    // Entry type enum
 *   name: string              // Entry name
 *   oid: oid_t                // Object ID (unique)
 *   timestamp: transaction_t  // Version timestamp
 *   deleted: bool             // Tombstone flag
 *   hasParent_: bool          // Dependency flag
 * }
 * ```
 * 
 * CatalogEntryType Enum:
 * ```
 * NODE_TABLE_ENTRY      // Node tables
 * REL_GROUP_ENTRY       // Relationship tables
 * SEQUENCE_ENTRY        // Sequences
 * INDEX_ENTRY           // Secondary indexes
 * TYPE_ENTRY            // Custom types
 * SCALAR_MACRO_ENTRY    // Scalar macros
 * SCALAR_FUNCTION_ENTRY // Scalar functions
 * AGGREGATE_FUNCTION_ENTRY
 * TABLE_FUNCTION_ENTRY
 * REWRITE_FUNCTION_ENTRY
 * DUMMY_ENTRY           // Placeholder
 * ```
 * 
 * Key Operations:
 * 
 * 1. serialize():
 *    - Writes: type, name, oid, hasParent_
 *    - Subclasses add their specific fields
 * 
 * 2. deserialize():
 *    - Reads base fields
 *    - Dispatches to appropriate subclass based on type:
 *      * NODE_TABLE/REL_GROUP → TableCatalogEntry::deserialize()
 *      * SCALAR_MACRO → ScalarMacroCatalogEntry::deserialize()
 *      * SEQUENCE → SequenceCatalogEntry::deserialize()
 *      * TYPE → TypeCatalogEntry::deserialize()
 *      * INDEX → IndexCatalogEntry::deserialize()
 *    - Sets base fields on result
 *    - Sets timestamp to DUMMY_START_TIMESTAMP (restored during load)
 * 
 * 3. copyFrom():
 *    - Deep copies all base fields
 *    - Used by subclass copy() methods
 *    - For version chain management
 * 
 * Version Chain Integration:
 * ```
 * CatalogSet maintains version chains:
 *   name → Entry(TS=100) → Entry(TS=50) → Entry(TS=10)
 *                │
 *           Current visible version depends on transaction timestamp
 * 
 * Fields used:
 * - oid: Links versions together
 * - timestamp: Version identifier
 * - deleted: Tombstone for DROP
 * ```
 * 
 * Virtual Methods (in header):
 * - toCypher(): Generate CREATE statement
 * - copy(): Deep copy for ALTER
 */

#include "catalog/catalog_entry/index_catalog_entry.h"
#include "catalog/catalog_entry/scalar_macro_catalog_entry.h"
#include "catalog/catalog_entry/sequence_catalog_entry.h"
#include "catalog/catalog_entry/table_catalog_entry.h"
#include "catalog/catalog_entry/type_catalog_entry.h"
#include "common/serializer/deserializer.h"
#include "transaction/transaction.h"

namespace kuzu {
namespace catalog {

void CatalogEntry::serialize(common::Serializer& serializer) const {
    serializer.writeDebuggingInfo("type");
    serializer.write(type);
    serializer.writeDebuggingInfo("name");
    serializer.write(name);
    serializer.writeDebuggingInfo("oid");
    serializer.write(oid);
    serializer.writeDebuggingInfo("hasParent_");
    serializer.write(hasParent_);
}

std::unique_ptr<CatalogEntry> CatalogEntry::deserialize(common::Deserializer& deserializer) {
    std::string debuggingInfo;
    auto type = CatalogEntryType::DUMMY_ENTRY;
    std::string name;
    common::oid_t oid = common::INVALID_OID;
    bool hasParent_ = false;
    deserializer.validateDebuggingInfo(debuggingInfo, "type");
    deserializer.deserializeValue(type);
    deserializer.validateDebuggingInfo(debuggingInfo, "name");
    deserializer.deserializeValue(name);
    deserializer.validateDebuggingInfo(debuggingInfo, "oid");
    deserializer.deserializeValue(oid);
    deserializer.validateDebuggingInfo(debuggingInfo, "hasParent_");
    deserializer.deserializeValue(hasParent_);
    std::unique_ptr<CatalogEntry> entry;
    switch (type) {
    case CatalogEntryType::NODE_TABLE_ENTRY:
    case CatalogEntryType::REL_GROUP_ENTRY: {
        entry = TableCatalogEntry::deserialize(deserializer, type);
    } break;
    case CatalogEntryType::SCALAR_MACRO_ENTRY: {
        entry = ScalarMacroCatalogEntry::deserialize(deserializer);
    } break;
    case CatalogEntryType::SEQUENCE_ENTRY: {
        entry = SequenceCatalogEntry::deserialize(deserializer);
    } break;
    case CatalogEntryType::TYPE_ENTRY: {
        entry = TypeCatalogEntry::deserialize(deserializer);
    } break;
    case CatalogEntryType::INDEX_ENTRY: {
        entry = IndexCatalogEntry::deserialize(deserializer);
    } break;
    default:
        KU_UNREACHABLE;
    }
    entry->type = type;
    entry->name = std::move(name);
    entry->oid = oid;
    entry->hasParent_ = hasParent_;
    entry->timestamp = transaction::Transaction::DUMMY_START_TIMESTAMP;
    return entry;
}

void CatalogEntry::copyFrom(const CatalogEntry& other) {
    type = other.type;
    name = other.name;
    oid = other.oid;
    timestamp = other.timestamp;
    deleted = other.deleted;
    hasParent_ = other.hasParent_;
}

} // namespace catalog
} // namespace kuzu
