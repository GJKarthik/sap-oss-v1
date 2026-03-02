#include "graph/graph_entry.h"

/**
 * P3-169: GraphEntry - Named Graph Schema Definition
 * 
 * Purpose:
 * Represents a named graph schema in Kuzu. A graph entry defines which node
 * and relationship tables make up a named graph for GRAPH PROJECT queries.
 * 
 * Architecture:
 * ```
 * NativeGraphEntry
 *   ├── nodeInfos: vector<NativeGraphEntryTableInfo>
 *   │     └── entry: TableCatalogEntry*  (node table)
 *   │
 *   └── relInfos: vector<NativeGraphEntryTableInfo>
 *         └── entry: TableCatalogEntry*  (rel table)
 * ```
 * 
 * Graph Entry Hierarchy:
 * ```
 * GraphEntry (abstract)
 *   ├── NativeGraphEntry     // Tables from current database
 *   └── ExternalGraphEntry   // Tables from external source
 * ```
 * 
 * Key Methods:
 * | Method | Description |
 * |--------|-------------|
 * | getNodeTableIDs() | Get all node table IDs |
 * | getNodeEntries() | Get node table catalog entries |
 * | getRelEntries() | Get rel table catalog entries |
 * | getRelInfo() | Get info for specific rel table |
 * 
 * Usage Pattern:
 * ```cypher
 * CALL CREATE_GRAPH('myGraph', ['Person', 'Company'], ['KNOWS', 'WORKS_AT'])
 * 
 * // Then query the named graph
 * MATCH (n)-[r]->(m)
 * ON GRAPH myGraph
 * RETURN n, r, m
 * ```
 * 
 * NativeGraphEntryTableInfo:
 * - Wraps TableCatalogEntry for node/rel tables
 * - Provides metadata about table participation in graph
 * 
 * Integration:
 * - GraphEntrySet manages multiple named graphs
 * - OnDiskGraph provides storage for graph data
 * - Graph class provides runtime graph operations
 * 
 * Graph vs Schema:
 * - Schema defines tables independently
 * - Graph entry groups tables into logical graphs
 * - Enables multi-graph queries
 */

#include "common/exception/runtime.h"

using namespace kuzu::planner;
using namespace kuzu::binder;
using namespace kuzu::common;
using namespace kuzu::catalog;

namespace kuzu {
namespace graph {

NativeGraphEntry::NativeGraphEntry(std::vector<TableCatalogEntry*> nodeEntries,
    std::vector<TableCatalogEntry*> relEntries) {
    for (auto& entry : nodeEntries) {
        nodeInfos.emplace_back(entry);
    }
    for (auto& entry : relEntries) {
        relInfos.emplace_back(entry);
    }
}

std::vector<table_id_t> NativeGraphEntry::getNodeTableIDs() const {
    std::vector<table_id_t> result;
    for (auto& info : nodeInfos) {
        result.push_back(info.entry->getTableID());
    }
    return result;
}

std::vector<TableCatalogEntry*> NativeGraphEntry::getRelEntries() const {
    std::vector<TableCatalogEntry*> result;
    for (auto& info : relInfos) {
        result.push_back(info.entry);
    }
    return result;
}

std::vector<TableCatalogEntry*> NativeGraphEntry::getNodeEntries() const {
    std::vector<TableCatalogEntry*> result;
    for (auto& info : nodeInfos) {
        result.push_back(info.entry);
    }
    return result;
}

const NativeGraphEntryTableInfo& NativeGraphEntry::getRelInfo(table_id_t tableID) const {
    for (auto& info : relInfos) {
        if (info.entry->getTableID() == tableID) {
            return info;
        }
    }
    // LCOV_EXCL_START
    throw RuntimeException(stringFormat("Cannot find rel table with id {}", tableID));
    // LCOV_EXCL_STOP
}

} // namespace graph
} // namespace kuzu
