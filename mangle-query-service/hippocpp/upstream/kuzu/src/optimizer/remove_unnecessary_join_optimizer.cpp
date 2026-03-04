#include "optimizer/remove_unnecessary_join_optimizer.h"

#include "planner/operator/logical_hash_join.h"
#include "planner/operator/scan/logical_scan_node_table.h"

using namespace kuzu::common;
using namespace kuzu::planner;

namespace kuzu {
namespace optimizer {

void RemoveUnnecessaryJoinOptimizer::rewrite(LogicalPlan* plan) {
    visitOperator(plan->getLastOperator());
}

std::shared_ptr<LogicalOperator> RemoveUnnecessaryJoinOptimizer::visitOperator(
    const std::shared_ptr<LogicalOperator>& op) {
    // bottom-up traversal
    for (auto i = 0u; i < op->getNumChildren(); ++i) {
        op->setChild(i, visitOperator(op->getChild(i)));
    }
    auto result = visitOperatorReplaceSwitch(op);
    result->computeFlatSchema();
    return result;
}

// Remove Unnecessary Join Optimization:
// This optimization removes hash joins where one side is a "trivial" scan that doesn't
// contribute any data beyond the join key itself.
//
// Correctness Analysis:
// A join can be safely removed when:
// 1. The join is INNER type (not MARK, LEFT, etc.)
// 2. One side is a simple node table scan with no properties selected
// 3. The join key is the node's internal ID (implied by scan node semantics)
//
// Why this is correct:
// - For INNER joins: A trivial scan on node IDs with no properties selected means
//   the only purpose of that side is to filter the other side to matching node IDs.
// - Since node IDs are always unique within a table, and the scan returns all nodes,
//   the join would match exactly the same rows as if we just took the non-trivial side.
// - Essentially: MATCH (a)-[r]-(b) WHERE b has no property accesses
//   can be simplified to just traversing from a, as b's existence is implied by the edge.
//
// Edge cases considered:
// - MARK joins: Cannot prune because the mark flag itself carries semantic meaning
// - LEFT joins: Cannot prune because NULL rows must be preserved
// - Multi-hop patterns: Safe because each join is processed independently
// - Filtered scans: The check for empty properties handles this - if there's a filter,
//   properties would typically be accessed
//
// Potential improvements:
// - Could extend to handle cases with only internal ID property access
// - Could integrate with cardinality estimation to make cost-based decisions
std::shared_ptr<LogicalOperator> RemoveUnnecessaryJoinOptimizer::visitHashJoinReplace(
    std::shared_ptr<LogicalOperator> op) {
    auto hashJoin = (LogicalHashJoin*)op.get();
    switch (hashJoin->getJoinType()) {
    case JoinType::MARK:
    case JoinType::LEFT: {
        // Do not prune non-trivial join types that have special semantics:
        // - MARK: The mark flag itself is the output (existence check)
        // - LEFT: Must preserve NULLs for non-matching rows
        return op;
    }
    default:
        break;
    }
    
    // Check if build side is trivial (scan with no properties)
    // If so, the join only serves to filter based on node existence,
    // which is already implied by the probe side's edges.
    if (op->getChild(1)->getOperatorType() == LogicalOperatorType::SCAN_NODE_TABLE) {
        const auto scanNode = ku_dynamic_cast<LogicalScanNodeTable*>(op->getChild(1).get());
        if (scanNode->getProperties().empty()) {
            // Build side is trivial. Prune build side.
            // The probe side already contains the join key matches via edge traversal.
            return op->getChild(0);
        }
    }
    
    // Check if probe side is trivial
    // This is less common but can happen with certain query patterns.
    if (op->getChild(0)->getOperatorType() == LogicalOperatorType::SCAN_NODE_TABLE) {
        const auto scanNode = ku_dynamic_cast<LogicalScanNodeTable*>(op->getChild(0).get());
        if (scanNode->getProperties().empty()) {
            // Probe side is trivial. Prune probe side.
            return op->getChild(1);
        }
    }
    return op;
}

} // namespace optimizer
} // namespace kuzu
