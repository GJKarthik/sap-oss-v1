#include "catalog/property_definition_collection.h"

/**
 * P3-150: PropertyDefinitionCollection - Table Property Management
 * 
 * Purpose:
 * Manages the collection of property definitions for tables. Handles
 * property ID allocation, column ID mapping, and ADD/DROP/RENAME operations.
 * 
 * Architecture:
 * ```
 * PropertyDefinitionCollection {
 *   definitions: map<property_id_t, PropertyDefinition>
 *   columnIDs: map<property_id_t, column_id_t>
 *   nameToPropertyIDMap: map<string, property_id_t>
 *   nextPropertyID: property_id_t
 *   nextColumnID: column_id_t
 * }
 * ```
 * 
 * ID Relationships:
 * ```
 * Property ID: Logical identifier (preserved across renames)
 * Column ID: Physical storage column (may change on vacuum)
 * 
 * Example:
 *   CREATE NODE TABLE Person (id INT64, name STRING, age INT64)
 *     definitions[0] = id   → columnIDs[0] = 0
 *     definitions[1] = name → columnIDs[1] = 1
 *     definitions[2] = age  → columnIDs[2] = 2
 * 
 *   ALTER TABLE Person DROP name
 *     definitions: {0: id, 2: age}  (gaps in IDs)
 *     columnIDs: {0: 0, 2: 2}
 * 
 *   vacuumColumnIDs(0):
 *     columnIDs: {0: 0, 2: 1}  (compacted)
 * ```
 * 
 * Key Operations:
 * 
 * 1. add(PropertyDefinition):
 *    - Assigns nextPropertyID
 *    - Assigns nextColumnID
 *    - Inserts into all maps
 * 
 * 2. drop(name):
 *    - Removes from definitions, columnIDs, nameToPropertyIDMap
 *    - Creates gaps in IDs (filled by vacuum)
 * 
 * 3. rename(oldName, newName):
 *    - Updates PropertyDefinition.name
 *    - Updates nameToPropertyIDMap
 *    - Property ID and Column ID unchanged
 * 
 * 4. vacuumColumnIDs(startID):
 *    - Reassigns column IDs sequentially
 *    - Called after DROP to compact storage
 * 
 * 5. getMaxColumnID():
 *    - Returns highest column ID
 *    - Used for storage allocation
 * 
 * 6. toCypher():
 *    - Generates column definitions for CREATE
 *    - Format: `name` TYPE,
 *    - Skips INTERNAL_ID columns
 * 
 * Serialization:
 * - nextColumnID, nextPropertyID, definitions map, columnIDs map
 * - Reconstructs nameToPropertyIDMap from definitions on deserialize
 * 
 * Used By:
 * - TableCatalogEntry (via propertyCollection member)
 * - NodeTableCatalogEntry
 * - RelGroupCatalogEntry
 */

#include <map>
#include <sstream>

#include "common/serializer/deserializer.h"
#include "common/serializer/serializer.h"
#include "common/string_utils.h"

using namespace kuzu::binder;
using namespace kuzu::common;

namespace kuzu {
namespace catalog {

std::vector<binder::PropertyDefinition> PropertyDefinitionCollection::getDefinitions() const {
    std::vector<binder::PropertyDefinition> propertyDefinitions;
    for (auto i = 0u; i < nextPropertyID; i++) {
        if (definitions.contains(i)) {
            propertyDefinitions.push_back(definitions.at(i).copy());
        }
    }
    return propertyDefinitions;
}

const PropertyDefinition& PropertyDefinitionCollection::getDefinition(
    const std::string& name) const {
    return getDefinition(getPropertyID(name));
}

const PropertyDefinition& PropertyDefinitionCollection::getDefinition(
    property_id_t propertyID) const {
    KU_ASSERT(definitions.contains(propertyID));
    return definitions.at(propertyID);
}

column_id_t PropertyDefinitionCollection::getColumnID(const std::string& name) const {
    return getColumnID(getPropertyID(name));
}

column_id_t PropertyDefinitionCollection::getColumnID(property_id_t propertyID) const {
    KU_ASSERT(columnIDs.contains(propertyID));
    return columnIDs.at(propertyID);
}

void PropertyDefinitionCollection::vacuumColumnIDs(column_id_t nextColumnID) {
    this->nextColumnID = nextColumnID;
    columnIDs.clear();
    for (auto& [propertyID, definition] : definitions) {
        columnIDs.emplace(propertyID, this->nextColumnID++);
    }
}

void PropertyDefinitionCollection::add(const PropertyDefinition& definition) {
    auto propertyID = nextPropertyID++;
    columnIDs.emplace(propertyID, nextColumnID++);
    definitions.emplace(propertyID, definition.copy());
    nameToPropertyIDMap.emplace(definition.getName(), propertyID);
}

void PropertyDefinitionCollection::drop(const std::string& name) {
    KU_ASSERT(contains(name));
    auto propertyID = nameToPropertyIDMap.at(name);
    definitions.erase(propertyID);
    columnIDs.erase(propertyID);
    nameToPropertyIDMap.erase(name);
}

void PropertyDefinitionCollection::rename(const std::string& name, const std::string& newName) {
    KU_ASSERT(contains(name));
    auto idx = nameToPropertyIDMap.at(name);
    definitions[idx].rename(newName);
    nameToPropertyIDMap.erase(name);
    nameToPropertyIDMap.insert({newName, idx});
}

column_id_t PropertyDefinitionCollection::getMaxColumnID() const {
    column_id_t maxID = 0;
    for (auto [_, id] : columnIDs) {
        if (id > maxID) {
            maxID = id;
        }
    }
    return maxID;
}

property_id_t PropertyDefinitionCollection::getPropertyID(const std::string& name) const {
    KU_ASSERT(contains(name));
    return nameToPropertyIDMap.at(name);
}

std::string PropertyDefinitionCollection::toCypher() const {
    std::stringstream ss;
    for (auto& [_, def] : definitions) {
        auto& dataType = def.getType();
        // Avoid exporting internal ID
        if (dataType.getPhysicalType() == PhysicalTypeID::INTERNAL_ID) {
            continue;
        }
        auto typeStr = dataType.toString();
        StringUtils::replaceAll(typeStr, ":", " ");
        if (typeStr.find("MAP") != std::string::npos) {
            StringUtils::replaceAll(typeStr, "  ", ",");
        }
        ss << "`" << def.getName() << "`" << " " << typeStr << ",";
    }
    return ss.str();
}

void PropertyDefinitionCollection::serialize(Serializer& serializer) const {
    serializer.writeDebuggingInfo("nextColumnID");
    serializer.serializeValue(nextColumnID);
    serializer.writeDebuggingInfo("nextPropertyID");
    serializer.serializeValue(nextPropertyID);
    serializer.writeDebuggingInfo("definitions");
    serializer.serializeMap(definitions);
    serializer.writeDebuggingInfo("columnIDs");
    serializer.serializeUnorderedMap(columnIDs);
}

PropertyDefinitionCollection PropertyDefinitionCollection::deserialize(Deserializer& deserializer) {
    std::string debuggingInfo;
    column_id_t nextColumnID = 0;
    deserializer.validateDebuggingInfo(debuggingInfo, "nextColumnID");
    deserializer.deserializeValue(nextColumnID);
    property_id_t nextPropertyID = 0;
    deserializer.validateDebuggingInfo(debuggingInfo, "nextPropertyID");
    deserializer.deserializeValue(nextPropertyID);
    std::map<property_id_t, PropertyDefinition> definitions;
    deserializer.validateDebuggingInfo(debuggingInfo, "definitions");
    deserializer.deserializeMap(definitions);
    std::unordered_map<property_id_t, column_id_t> columnIDs;
    deserializer.validateDebuggingInfo(debuggingInfo, "columnIDs");
    deserializer.deserializeUnorderedMap(columnIDs);
    auto collection = PropertyDefinitionCollection();
    for (auto& [propertyID, definition] : definitions) {
        collection.nameToPropertyIDMap.insert({definition.getName(), propertyID});
    }
    collection.nextColumnID = nextColumnID;
    collection.nextPropertyID = nextPropertyID;
    collection.definitions = std::move(definitions);
    collection.columnIDs = std::move(columnIDs);
    return collection;
}

} // namespace catalog
} // namespace kuzu
