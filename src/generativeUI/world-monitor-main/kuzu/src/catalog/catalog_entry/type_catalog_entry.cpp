#include "catalog/catalog_entry/type_catalog_entry.h"

/**
 * P3-148: TypeCatalogEntry - User-Defined Type Metadata
 * 
 * Purpose:
 * Catalog entry for user-defined types (UDTs). Stores the type name
 * and the underlying LogicalType definition.
 * 
 * Architecture:
 * ```
 * CatalogEntry (base)
 *   └── TypeCatalogEntry
 *         └── type: LogicalType  // The type definition
 * ```
 * 
 * User-Defined Types:
 * ```
 * CREATE TYPE Point AS STRUCT(x DOUBLE, y DOUBLE)
 *   │
 *   ├── name = "Point"
 *   └── type = LogicalType::STRUCT([("x", DOUBLE), ("y", DOUBLE)])
 * 
 * CREATE TYPE Status AS ENUM('active', 'inactive', 'pending')
 *   │
 *   ├── name = "Status"
 *   └── type = LogicalType::ENUM(...enum values...)
 * ```
 * 
 * Type Categories:
 * ```
 * STRUCT types:
 *   CREATE TYPE Address AS STRUCT(street STRING, city STRING, zip INT64)
 * 
 * ENUM types:
 *   CREATE TYPE Color AS ENUM('red', 'green', 'blue')
 * 
 * Type aliases (future):
 *   CREATE TYPE UserId AS INT64
 * ```
 * 
 * Key Operations:
 * 
 * 1. serialize():
 *    - Calls CatalogEntry::serialize() for base fields
 *    - Serializes LogicalType via type.serialize()
 * 
 * 2. deserialize():
 *    - Creates new TypeCatalogEntry
 *    - Deserializes LogicalType via LogicalType::deserialize()
 * 
 * Usage in Query Processing:
 * ```
 * CREATE NODE TABLE Location (id INT64, coords Point, ...)
 *                                        │
 *                                  Looks up "Point" in types catalog
 *                                  Gets underlying STRUCT type
 * 
 * SELECT coords.x FROM Location
 *              │
 *        Property access on STRUCT type
 * ```
 * 
 * Type Resolution:
 * ```
 * ExpressionBinder encounters "Point" type name
 *   → catalog->getType(txn, "Point")
 *   → Returns TypeCatalogEntry
 *   → Gets underlying LogicalType for column definition
 * ```
 * 
 * Entry Type:
 * - CatalogEntryType::TYPE_ENTRY
 */

#include "common/serializer/deserializer.h"

namespace kuzu {
namespace catalog {

void TypeCatalogEntry::serialize(common::Serializer& serializer) const {
    CatalogEntry::serialize(serializer);
    serializer.writeDebuggingInfo("type");
    type.serialize(serializer);
}

std::unique_ptr<TypeCatalogEntry> TypeCatalogEntry::deserialize(
    common::Deserializer& deserializer) {
    std::string debuggingInfo;
    auto typeCatalogEntry = std::make_unique<TypeCatalogEntry>();
    deserializer.validateDebuggingInfo(debuggingInfo, "type");
    typeCatalogEntry->type = common::LogicalType::deserialize(deserializer);
    return typeCatalogEntry;
}

} // namespace catalog
} // namespace kuzu
