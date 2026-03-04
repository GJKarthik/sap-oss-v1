#include "optimizer/top_k_optimizer.h"

#include "planner/operator/logical_limit.h"
#include "planner/operator/logical_order_by.h"

using namespace kuzu::planner;
using namespace kuzu::common;

namespace kuzu {
namespace optimizer {

void TopKOptimizer::rewrite(planner::LogicalPlan* plan) {
    plan->setLastOperator(visitOperator(plan->getLastOperator()));
}

std::shared_ptr<LogicalOperator> TopKOptimizer::visitOperator(
    const std::shared_ptr<LogicalOperator>& op) {
    // bottom-up traversal
    for (auto i = 0u; i < op->getNumChildren(); ++i) {
        op->setChild(i, visitOperator(op->getChild(i)));
    }
    auto result = visitOperatorReplaceSwitch(op);
    result->computeFlatSchema();
    return result;
}

// Top-K Optimization: Convert ORDER BY + LIMIT patterns to efficient TOP-K operator.
//
// Pattern Recognition:
// We search for these patterns and rewrite them as TOP_K:
//   Pattern 1: ORDER BY -> PROJECTION -> MULTIPLICITY REDUCER -> LIMIT
//   Pattern 2: ORDER BY -> MULTIPLICITY REDUCER -> LIMIT
//
// Why TOP_K is more efficient:
// - Traditional ORDER BY + LIMIT: Sort ALL data, then take top K rows
//   - Time: O(n log n), Space: O(n)
// - TOP_K: Maintain a heap of K elements while scanning
//   - Time: O(n log k), Space: O(k)
//   - For k << n (typical case), this is much faster
//
// About the intermediate PROJECTION:
// The PROJECTION between ORDER BY and MULTIPLICITY REDUCER can appear when:
// - The query has SELECT clauses that rename or compute expressions
// - The planner inserts projection for column pruning
//
// Current behavior: We preserve the PROJECTION to maintain correctness.
// The projection ensures column names/expressions are computed correctly.
//
// Future optimization consideration:
// The PROJECTION could potentially be merged into ORDER BY or eliminated if:
// - It only renames columns (no computation)
// - All projected columns are already computed by ORDER BY
// - The schema after ORDER BY matches what LIMIT expects
// However, this requires careful analysis of expression equivalence.
//
// Implementation returns projectionOrOrderBy (not just orderBy) to preserve
// any intermediate projection that may be needed for correct results.
std::shared_ptr<LogicalOperator> TopKOptimizer::visitLimitReplace(
    std::shared_ptr<LogicalOperator> op) {
    auto limit = op->ptrCast<LogicalLimit>();
    if (!limit->hasLimitNum()) {
        return op; // Only skip without limit - no need to rewrite as TOP_K
    }
    
    auto multiplicityReducer = limit->getChild(0);
    KU_ASSERT(multiplicityReducer->getOperatorType() == LogicalOperatorType::MULTIPLICITY_REDUCER);
    
    auto projectionOrOrderBy = multiplicityReducer->getChild(0);
    std::shared_ptr<LogicalOrderBy> orderBy;
    
    // Pattern 1: ORDER BY -> PROJECTION -> MULTIPLICITY REDUCER -> LIMIT
    if (projectionOrOrderBy->getOperatorType() == LogicalOperatorType::PROJECTION) {
        if (projectionOrOrderBy->getChild(0)->getOperatorType() != LogicalOperatorType::ORDER_BY) {
            return op; // Not a TOP_K pattern
        }
        orderBy = std::static_pointer_cast<LogicalOrderBy>(projectionOrOrderBy->getChild(0));
        // Note: We keep the projection to ensure correct column names/expressions.
        // Future: Could analyze if projection is identity and skip it.
    } 
    // Pattern 2: ORDER BY -> MULTIPLICITY REDUCER -> LIMIT
    else if (projectionOrOrderBy->getOperatorType() == LogicalOperatorType::ORDER_BY) {
        orderBy = std::static_pointer_cast<LogicalOrderBy>(projectionOrOrderBy);
    } else {
        return op; // Not a recognized pattern
    }
    
    KU_ASSERT(orderBy != nullptr);
    
    // Convert to TOP_K by setting limit/skip on ORDER BY
    // The ORDER BY operator will use a heap-based algorithm when these are set
    if (limit->hasLimitNum()) {
        orderBy->setLimitNum(limit->getLimitNum());
    }
    if (limit->hasSkipNum()) {
        orderBy->setSkipNum(limit->getSkipNum());
    }
    
    // Return the operator tree up to (and including) any projection
    // This removes MULTIPLICITY_REDUCER and LIMIT from the tree
    return projectionOrOrderBy;
}

} // namespace optimizer
} // namespace kuzu
