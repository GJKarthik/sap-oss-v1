#include "optimizer/optimizer.h"

/**
 * P3-163: Optimizer - Logical Plan Optimization
 * 
 * Purpose:
 * Optimizes logical query plans using a series of rewriters. Each optimizer
 * applies specific transformations to improve execution efficiency.
 * 
 * Architecture:
 * ```
 * LogicalPlan (from Planner)
 *   │
 *   └── Optimizer::optimize()
 *         │
 *         ├── RemoveFactorizationRewriter
 *         ├── CorrelatedSubqueryUnnestSolver
 *         ├── RemoveUnnecessaryJoinOptimizer
 *         ├── FilterPushDownOptimizer
 *         ├── ProjectionPushDownOptimizer
 *         ├── LimitPushDownOptimizer
 *         ├── HashJoinSIPOptimizer (if enableSemiMask)
 *         ├── TopKOptimizer
 *         ├── FactorizationRewriter
 *         ├── AggKeyDependencyOptimizer
 *         └── CardinalityUpdater (for EXPLAIN)
 * ```
 * 
 * Optimization Phases:
 * | Phase | Optimizer | Description |
 * |-------|-----------|-------------|
 * | 1 | RemoveFactorizationRewriter | Remove factorization for optimization |
 * | 2 | CorrelatedSubqueryUnnestSolver | Decorrelate subqueries |
 * | 3 | RemoveUnnecessaryJoinOptimizer | Eliminate redundant joins |
 * | 4 | FilterPushDownOptimizer | Push filters closer to scans |
 * | 5 | ProjectionPushDownOptimizer | Push projections down |
 * | 6 | LimitPushDownOptimizer | Push LIMIT into operators |
 * | 7 | HashJoinSIPOptimizer | Semi-join pruning |
 * | 8 | TopKOptimizer | Convert ORDER BY + LIMIT to TopK |
 * | 9 | FactorizationRewriter | Restore factorization structure |
 * | 10 | AggKeyDependencyOptimizer | Optimize aggregation keys |
 * 
 * Conditional Optimizations:
 * - HashJoinSIPOptimizer: Only if enableSemiMask=true
 * - CardinalityUpdater: Only for EXPLAIN LOGICAL
 * 
 * Configuration:
 * - enablePlanOptimizer: Master switch for all optimizations
 * - If disabled, only SchemaPopulator runs
 * 
 * Optimizer Interface:
 * Each optimizer implements:
 * ```cpp
 * class SomeOptimizer : public LogicalOperatorVisitor {
 *     void rewrite(LogicalPlan* plan);
 *     // Visits operator tree, applies transformations
 * };
 * ```
 * 
 * Key Optimizations:
 * 
 * 1. FilterPushDown:
 *    Before: Scan → Join → Filter
 *    After:  Scan+Filter → Join
 * 
 * 2. ProjectionPushDown:
 *    Before: Scan(all cols) → Project(a,b)
 *    After:  Scan(a,b)
 * 
 * 3. TopK:
 *    Before: Scan → OrderBy → Limit
 *    After:  Scan → TopK
 * 
 * Output:
 * - Optimized LogicalPlan
 * - Passed to PlanMapper for physical plan
 */

#include "main/client_context.h"
#include "optimizer/acc_hash_join_optimizer.h"
#include "optimizer/agg_key_dependency_optimizer.h"
#include "optimizer/cardinality_updater.h"
#include "optimizer/correlated_subquery_unnest_solver.h"
#include "optimizer/factorization_rewriter.h"
#include "optimizer/filter_push_down_optimizer.h"
#include "optimizer/limit_push_down_optimizer.h"
#include "optimizer/projection_push_down_optimizer.h"
#include "optimizer/remove_factorization_rewriter.h"
#include "optimizer/remove_unnecessary_join_optimizer.h"
#include "optimizer/schema_populator.h"
#include "optimizer/top_k_optimizer.h"
#include "planner/operator/logical_explain.h"
#include "transaction/transaction.h"

namespace kuzu {
namespace optimizer {

void Optimizer::optimize(planner::LogicalPlan* plan, main::ClientContext* context,
    const planner::CardinalityEstimator& cardinalityEstimator) {
    if (context->getClientConfig()->enablePlanOptimizer) {
        // Factorization structure should be removed before further optimization can be applied.
        auto removeFactorizationRewriter = RemoveFactorizationRewriter();
        removeFactorizationRewriter.rewrite(plan);

        auto correlatedSubqueryUnnestSolver = CorrelatedSubqueryUnnestSolver(nullptr);
        correlatedSubqueryUnnestSolver.solve(plan->getLastOperator().get());

        auto removeUnnecessaryJoinOptimizer = RemoveUnnecessaryJoinOptimizer();
        removeUnnecessaryJoinOptimizer.rewrite(plan);

        auto filterPushDownOptimizer = FilterPushDownOptimizer(context);
        filterPushDownOptimizer.rewrite(plan);

        auto projectionPushDownOptimizer =
            ProjectionPushDownOptimizer(context->getClientConfig()->recursivePatternSemantic);
        projectionPushDownOptimizer.rewrite(plan);

        auto limitPushDownOptimizer = LimitPushDownOptimizer();
        limitPushDownOptimizer.rewrite(plan);

        if (context->getClientConfig()->enableSemiMask) {
            // HashJoinSIPOptimizer should be applied after optimizers that manipulate hash join.
            auto hashJoinSIPOptimizer = HashJoinSIPOptimizer();
            hashJoinSIPOptimizer.rewrite(plan);
        }

        auto topKOptimizer = TopKOptimizer();
        topKOptimizer.rewrite(plan);

        auto factorizationRewriter = FactorizationRewriter();
        factorizationRewriter.rewrite(plan);

        // AggKeyDependencyOptimizer doesn't change factorization structure and thus can be put
        // after FactorizationRewriter.
        auto aggKeyDependencyOptimizer = AggKeyDependencyOptimizer();
        aggKeyDependencyOptimizer.rewrite(plan);

        // for EXPLAIN LOGICAL we need to update the cardinalities for the optimized plan
        // we don't need to do this otherwise as we don't use the cardinalities after planning
        if (plan->getLastOperatorRef().getOperatorType() == planner::LogicalOperatorType::EXPLAIN) {
            const auto& explain = plan->getLastOperatorRef().cast<planner::LogicalExplain>();
            if (explain.getExplainType() == common::ExplainType::LOGICAL_PLAN) {
                auto cardinalityUpdater = CardinalityUpdater(cardinalityEstimator,
                    transaction::Transaction::Get(*context));
                cardinalityUpdater.rewrite(plan);
            }
        }
    } else {
        // we still need to compute the schema for each operator even if we have optimizations
        // disabled
        auto schemaPopulator = SchemaPopulator{};
        schemaPopulator.rewrite(plan);
    }
}

} // namespace optimizer
} // namespace kuzu
