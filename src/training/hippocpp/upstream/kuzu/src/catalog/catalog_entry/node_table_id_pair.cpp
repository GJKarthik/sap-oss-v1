#include "catalog/catalog_entry/node_table_id_pair.h"

/**
 * P3-151: NodeTableIDPair - Relationship Endpoint Pair
 * 
 * Purpose:
 * Represents a pair of source and destination node table IDs for
 * relationship tables. Used by RelGroupCatalogEntry to define
 * valid endpoint connections.
 * 
 * Structure:
 * ```
 * NodeTableIDPair {
 *   srcTableID: table_id_t   // Source node table ID
 *   dstTableID: table_id_t   // Destination node table ID
 * }
 * ```
 * 
 * Usage in Relationships:
 * ```
 * CREATE REL TABLE Follows (FROM Person TO Person, since DATE)
 *   │
 *   └── Creates RelGroupCatalogEntry with:
 *         fromToConnection = { NodeTableIDPair(PersonID, PersonID) }
 * 
 * CREATE REL TABLE Likes (FROM Person TO Post | Photo, ...)
 *   │
 *   └── Creates RelGroupCatalogEntry with:
 *         fromToConnection = {
 *           NodeTableIDPair(PersonID, PostID),
 *           NodeTableIDPair(PersonID, PhotoID)
 *         }
 * ```
 * 
 * Multi-Label Relationships:
 * ```
 * (a:Person)-[r:KNOWS]->(b)   // b could be Person or Organization
 *                              │
 *                              └── RelGroup stores multiple pairs:
 *                                    (Person → Person)
 *                                    (Person → Organization)
 * ```
 * 
 * Serialization:
 * - serialize(): Writes srcTableID then dstTableID
 * - deserialize(): Reads srcTableID then dstTableID
 * 
 * Used By:
 * - RelGroupCatalogEntry.fromToConnectionSet
 * - Relationship table creation/alteration
 * - Query planning for relationship traversal
 * 
 * Operations on RelGroupCatalogEntry:
 * - addFromToConnection(srcID, dstID): Add new pair
 * - dropFromToConnection(srcID, dstID): Remove pair
 * - isSingleDirectionRelTable(): Check if all pairs have same src & dst
 */

#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"

using namespace kuzu::common;

namespace kuzu {
namespace catalog {

void NodeTableIDPair::serialize(Serializer& serializer) const {
    serializer.writeDebuggingInfo("srcTableID");
    serializer.serializeValue(srcTableID);
    serializer.writeDebuggingInfo("dstTableID");
    serializer.serializeValue(dstTableID);
}

NodeTableIDPair NodeTableIDPair::deserialize(Deserializer& deser) {
    std::string debuggingInfo;
    table_id_t srcTableID = INVALID_TABLE_ID;
    table_id_t dstTableID = INVALID_TABLE_ID;
    deser.validateDebuggingInfo(debuggingInfo, "srcTableID");
    deser.deserializeValue(srcTableID);
    deser.validateDebuggingInfo(debuggingInfo, "dstTableID");
    deser.deserializeValue(dstTableID);
    return NodeTableIDPair{srcTableID, dstTableID};
}

} // namespace catalog
} // namespace kuzu
