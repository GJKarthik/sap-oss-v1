#include "catalog/catalog_entry/node_table_catalog_entry.h"

/**
 * P3-141: NodeTableCatalogEntry - Node Table Metadata
 * 
 * Purpose:
 * Catalog entry for node (vertex) tables in the graph database.
 * Extends TableCatalogEntry with node-specific metadata, primarily
 * the primary key constraint.
 * 
 * Architecture:
 * ```
 * CatalogEntry (base)
 *   └── TableCatalogEntry (table metadata + properties)
 *         └── NodeTableCatalogEntry
 *               └── primaryKeyName: string  // Required PK property
 * ```
 * 
 * Inheritance:
 * - From TableCatalogEntry: propertyCollection, tableID, comment
 * - Adds: primaryKeyName for uniqueness constraint
 * 
 * Primary Key:
 * ```
 * CREATE NODE TABLE Person (id INT64, name STRING, PRIMARY KEY(id))
 *                                                       │
 *                                          primaryKeyName = "id"
 * 
 * - Identifies unique nodes
 * - Used for index lookups
 * - Required for all node tables
 * ```
 * 
 * Key Operations:
 * 
 * 1. renameProperty(old, new):
 *    - Delegates to TableCatalogEntry
 *    - Updates primaryKeyName if PK is renamed
 *    - Case-insensitive comparison
 * 
 * 2. serialize(serializer):
 *    - Serializes TableCatalogEntry data
 *    - Writes primaryKeyName
 * 
 * 3. deserialize(deserializer):
 *    - Reads primaryKeyName
 *    - Returns new NodeTableCatalogEntry
 * 
 * 4. toCypher(info):
 *    - Generates: CREATE NODE TABLE `name` (..., PRIMARY KEY(`pk`))
 *    - Used for EXPORT DATABASE
 * 
 * 5. copy():
 *    - Deep copy with primaryKeyName
 *    - Used for version chain management
 * 
 * 6. getBoundExtraCreateInfo():
 *    - Returns BoundExtraCreateNodeTableInfo
 *    - Used for IMPORT DATABASE reconstruction
 * 
 * Entry Type:
 * - CatalogEntryType::NODE_TABLE_ENTRY
 * 
 * Usage in Catalog:
 * ```cpp
 * auto nodeEntry = catalog->getTableCatalogEntry(txn, "Person")
 *                         ->ptrCast<NodeTableCatalogEntry>();
 * string pk = nodeEntry->getPrimaryKeyName();
 * ```
 */

#include "binder/ddl/bound_create_table_info.h"
#include "common/serializer/deserializer.h"
#include "common/string_utils.h"

using namespace kuzu::binder;

namespace kuzu {
namespace catalog {

void NodeTableCatalogEntry::renameProperty(const std::string& propertyName,
    const std::string& newName) {
    TableCatalogEntry::renameProperty(propertyName, newName);
    if (common::StringUtils::caseInsensitiveEquals(propertyName, primaryKeyName)) {
        primaryKeyName = newName;
    }
}

void NodeTableCatalogEntry::serialize(common::Serializer& serializer) const {
    TableCatalogEntry::serialize(serializer);
    serializer.writeDebuggingInfo("primaryKeyName");
    serializer.write(primaryKeyName);
}

std::unique_ptr<NodeTableCatalogEntry> NodeTableCatalogEntry::deserialize(
    common::Deserializer& deserializer) {
    std::string debuggingInfo;
    std::string primaryKeyName;
    deserializer.validateDebuggingInfo(debuggingInfo, "primaryKeyName");
    deserializer.deserializeValue(primaryKeyName);
    auto nodeTableEntry = std::make_unique<NodeTableCatalogEntry>();
    nodeTableEntry->primaryKeyName = primaryKeyName;
    return nodeTableEntry;
}

std::string NodeTableCatalogEntry::toCypher(const ToCypherInfo& /*info*/) const {
    return common::stringFormat("CREATE NODE TABLE `{}` ({} PRIMARY KEY(`{}`));", getName(),
        propertyCollection.toCypher(), primaryKeyName);
}

std::unique_ptr<TableCatalogEntry> NodeTableCatalogEntry::copy() const {
    auto other = std::make_unique<NodeTableCatalogEntry>();
    other->primaryKeyName = primaryKeyName;
    other->copyFrom(*this);
    return other;
}

std::unique_ptr<BoundExtraCreateCatalogEntryInfo> NodeTableCatalogEntry::getBoundExtraCreateInfo(
    transaction::Transaction*) const {
    return std::make_unique<BoundExtraCreateNodeTableInfo>(primaryKeyName,
        copyVector(getProperties()));
}

} // namespace catalog
} // namespace kuzu
