#include "catalog/catalog_entry/table_catalog_entry.h"

/**
 * P3-145: TableCatalogEntry - Base Table Catalog Entry
 * 
 * Purpose:
 * Abstract base class for all table types (node tables, relationship tables).
 * Provides common property management, ALTER operations, and serialization.
 * 
 * Inheritance:
 * ```
 * CatalogEntry (base)
 *   └── TableCatalogEntry
 *         ├── NodeTableCatalogEntry (nodes/vertices)
 *         └── RelGroupCatalogEntry  (relationships/edges)
 * ```
 * 
 * Core Components:
 * ```
 * TableCatalogEntry {
 *   comment: string                      // User comment
 *   propertyCollection: PropertyDefinitionCollection  // Properties
 *   hasParent_: bool                     // Dependency flag
 * }
 * ```
 * 
 * ALTER Operations (handled by alter()):
 * ```
 * AlterType::RENAME            → rename(newName)
 * AlterType::RENAME_PROPERTY   → renameProperty(old, new)
 * AlterType::ADD_PROPERTY      → addProperty(definition)
 * AlterType::DROP_PROPERTY     → dropProperty(name)
 * AlterType::COMMENT           → setComment(comment)
 * AlterType::ADD_FROM_TO_CONNECTION     → addFromToConnection() [REL only]
 * AlterType::DROP_FROM_TO_CONNECTION    → dropFromToConnection() [REL only]
 * ```
 * 
 * Property Operations:
 * ```
 * containsProperty(name)  → bool
 * getPropertyID(name)     → property_id_t
 * getProperty(name/idx)   → PropertyDefinition
 * getColumnID(name/idx)   → column_id_t
 * getMaxColumnID()        → column_id_t
 * vacuumColumnIDs(next)   → compact after DROP
 * ```
 * 
 * Serialization:
 * ```
 * serialize():
 *   1. CatalogEntry::serialize()
 *   2. Write comment
 *   3. propertyCollection.serialize()
 * 
 * deserialize():
 *   1. Read comment + properties
 *   2. Dispatch to NodeTableCatalogEntry or RelGroupCatalogEntry
 *   3. Set comment + propertyCollection on result
 * ```
 * 
 * ALTER Flow:
 * ```
 * ALTER TABLE Person ADD age INT64
 *   │
 *   ├── 1. copy() → create new entry
 *   ├── 2. addProperty(PropertyDefinition)
 *   ├── 3. setOID(same OID)
 *   ├── 4. setTimestamp(newTS)
 *   └── 5. return newEntry → replaces old in version chain
 * ```
 * 
 * Virtual Methods (implemented by subclasses):
 * - copy() → unique_ptr<TableCatalogEntry>
 * - getBoundExtraCreateInfo() → unique_ptr<BoundExtraCreateCatalogEntryInfo>
 * - toCypher() → string (CREATE statement)
 */

#include "binder/ddl/bound_alter_info.h"
#include "catalog/catalog.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/serializer/deserializer.h"

using namespace kuzu::binder;
using namespace kuzu::common;

namespace kuzu {
namespace catalog {

std::unique_ptr<TableCatalogEntry> TableCatalogEntry::alter(transaction_t timestamp,
    const BoundAlterInfo& alterInfo, CatalogSet* tables) const {
    KU_ASSERT(!deleted);
    auto newEntry = copy();
    switch (alterInfo.alterType) {
    case AlterType::RENAME: {
        auto& renameTableInfo = *alterInfo.extraInfo->constPtrCast<BoundExtraRenameTableInfo>();
        newEntry->rename(renameTableInfo.newName);
    } break;
    case AlterType::RENAME_PROPERTY: {
        auto& renamePropInfo = *alterInfo.extraInfo->constPtrCast<BoundExtraRenamePropertyInfo>();
        newEntry->renameProperty(renamePropInfo.oldName, renamePropInfo.newName);
    } break;
    case AlterType::ADD_PROPERTY: {
        auto& addPropInfo = *alterInfo.extraInfo->constPtrCast<BoundExtraAddPropertyInfo>();
        newEntry->addProperty(addPropInfo.propertyDefinition);
    } break;
    case AlterType::DROP_PROPERTY: {
        auto& dropPropInfo = *alterInfo.extraInfo->constPtrCast<BoundExtraDropPropertyInfo>();
        newEntry->dropProperty(dropPropInfo.propertyName);
    } break;
    case AlterType::COMMENT: {
        auto& commentInfo = *alterInfo.extraInfo->constPtrCast<BoundExtraCommentInfo>();
        newEntry->setComment(commentInfo.comment);
    } break;
    case AlterType::ADD_FROM_TO_CONNECTION: {
        auto& connectionInfo =
            *alterInfo.extraInfo->constPtrCast<BoundExtraAlterFromToConnection>();
        newEntry->ptrCast<RelGroupCatalogEntry>()->addFromToConnection(connectionInfo.fromTableID,
            connectionInfo.toTableID, tables->getNextOIDNoLock());
    } break;
    case AlterType::DROP_FROM_TO_CONNECTION: {
        auto& connectionInfo =
            *alterInfo.extraInfo->constPtrCast<BoundExtraAlterFromToConnection>();
        newEntry->ptrCast<RelGroupCatalogEntry>()->dropFromToConnection(connectionInfo.fromTableID,
            connectionInfo.toTableID);
    } break;
    default: {
        KU_UNREACHABLE;
    }
    }
    newEntry->setOID(oid);
    newEntry->setTimestamp(timestamp);
    return newEntry;
}

column_id_t TableCatalogEntry::getMaxColumnID() const {
    return propertyCollection.getMaxColumnID();
}

void TableCatalogEntry::vacuumColumnIDs(column_id_t nextColumnID) {
    propertyCollection.vacuumColumnIDs(nextColumnID);
}

bool TableCatalogEntry::containsProperty(const std::string& propertyName) const {
    return propertyCollection.contains(propertyName);
}

property_id_t TableCatalogEntry::getPropertyID(const std::string& propertyName) const {
    return propertyCollection.getPropertyID(propertyName);
}

const PropertyDefinition& TableCatalogEntry::getProperty(const std::string& propertyName) const {
    return propertyCollection.getDefinition(propertyName);
}

const PropertyDefinition& TableCatalogEntry::getProperty(idx_t idx) const {
    return propertyCollection.getDefinition(idx);
}

column_id_t TableCatalogEntry::getColumnID(const std::string& propertyName) const {
    return propertyCollection.getColumnID(propertyName);
}

common::column_id_t TableCatalogEntry::getColumnID(common::idx_t idx) const {
    return propertyCollection.getColumnID(idx);
}

void TableCatalogEntry::addProperty(const PropertyDefinition& propertyDefinition) {
    propertyCollection.add(propertyDefinition);
}

void TableCatalogEntry::dropProperty(const std::string& propertyName) {
    propertyCollection.drop(propertyName);
}

void TableCatalogEntry::renameProperty(const std::string& propertyName,
    const std::string& newName) {
    propertyCollection.rename(propertyName, newName);
}

void TableCatalogEntry::serialize(Serializer& serializer) const {
    CatalogEntry::serialize(serializer);
    serializer.writeDebuggingInfo("comment");
    serializer.write(comment);
    serializer.writeDebuggingInfo("properties");
    propertyCollection.serialize(serializer);
}

std::unique_ptr<TableCatalogEntry> TableCatalogEntry::deserialize(Deserializer& deserializer,
    CatalogEntryType type) {
    std::string debuggingInfo;
    std::string comment;
    deserializer.validateDebuggingInfo(debuggingInfo, "comment");
    deserializer.deserializeValue(comment);
    deserializer.validateDebuggingInfo(debuggingInfo, "properties");
    auto propertyCollection = PropertyDefinitionCollection::deserialize(deserializer);
    std::unique_ptr<TableCatalogEntry> result;
    switch (type) {
    case CatalogEntryType::NODE_TABLE_ENTRY:
        result = NodeTableCatalogEntry::deserialize(deserializer);
        break;
    case CatalogEntryType::REL_GROUP_ENTRY:
        result = RelGroupCatalogEntry::deserialize(deserializer);
        break;
    default:
        KU_UNREACHABLE;
    }
    result->comment = std::move(comment);
    result->propertyCollection = std::move(propertyCollection);
    return result;
}

void TableCatalogEntry::copyFrom(const CatalogEntry& other) {
    CatalogEntry::copyFrom(other);
    auto& otherTable = ku_dynamic_cast<const TableCatalogEntry&>(other);
    comment = otherTable.comment;
    propertyCollection = otherTable.propertyCollection.copy();
}

BoundCreateTableInfo TableCatalogEntry::getBoundCreateTableInfo(
    transaction::Transaction* transaction, bool isInternal) const {
    auto extraInfo = getBoundExtraCreateInfo(transaction);
    return BoundCreateTableInfo(type, name, ConflictAction::ON_CONFLICT_THROW, std::move(extraInfo),
        isInternal, hasParent_);
}

} // namespace catalog
} // namespace kuzu
