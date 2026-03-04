#include "planner/join_order/cost_model.h"

#include "common/constants.h"
#include "planner/join_order/join_order_util.h"
#include "planner/operator/logical_hash_join.h"

using namespace kuzu::common;

namespace kuzu {
namespace planner {

uint64_t CostModel::computeExtendCost(const LogicalPlan& childPlan) {
    return childPlan.getCost() + childPlan.getCardinality();
}

uint64_t CostModel::computeHashJoinCost(const std::vector<binder::expression_pair>& joinConditions,
    const LogicalPlan& probe, const LogicalPlan& build) {
    return computeHashJoinCost(LogicalHashJoin::getJoinNodeIDs(joinConditions), probe, build);
}

uint64_t CostModel::computeHashJoinCost(const binder::expression_vector& joinNodeIDs,
    const LogicalPlan& probe, const LogicalPlan& build) {
    uint64_t cost = 0ul;
    cost += probe.getCost();
    cost += build.getCost();
    cost += probe.getCardinality();
    cost += PlannerKnobs::BUILD_PENALTY *
            JoinOrderUtil::getJoinKeysFlatCardinality(joinNodeIDs, build.getLastOperatorRef());
    return cost;
}

uint64_t CostModel::computeMarkJoinCost(const std::vector<binder::expression_pair>& joinConditions,
    const LogicalPlan& probe, const LogicalPlan& build) {
    return computeMarkJoinCost(LogicalHashJoin::getJoinNodeIDs(joinConditions), probe, build);
}

uint64_t CostModel::computeMarkJoinCost(const binder::expression_vector& joinNodeIDs,
    const LogicalPlan& probe, const LogicalPlan& build) {
    return computeHashJoinCost(joinNodeIDs, probe, build);
}

// Intersect Cost Model:
// Intersect operator computes the intersection of multiple sorted lists (typically node IDs).
// It's used for multi-hop graph patterns like (a)-[r1]-(b)-[r2]-(c) where we need nodes
// that satisfy both edge patterns.
//
// Cost Calculation Strategy:
// The intersect operator uses a merge-based algorithm on sorted lists:
// 1. Build phase: Sort/organize each build side by join key
// 2. Probe phase: For each probe tuple, scan matching ranges in all build sides
// 3. Output: Only tuples present in ALL build sides
//
// Cost factors:
// - Probe cardinality: Number of tuples to probe against build sides
// - Build cardinalities: Size of each build side (determines lookup cost)
// - Selectivity: Intersect typically has HIGH selectivity (few matches)
//
// Formula:
//   Cost = probeCost + probeCardinality * log(avgBuildCardinality) + sum(buildCosts)
//
// The log factor models the binary search cost per probe tuple.
// We add a small INTERSECT_PENALTY to prefer hash joins when costs are similar,
// as hash joins are generally more robust.
//
// Design goal: Ensure intersect is picked for appropriate patterns:
// - When multiple edges need to be intersected (natural for graph patterns)
// - When build sides have similar cardinalities
// - When the intersection result is expected to be small
uint64_t CostModel::computeIntersectCost(const LogicalPlan& probePlan,
    const std::vector<LogicalPlan>& buildPlans) {
    uint64_t cost = 0ul;
    
    // Add probe side cost
    cost += probePlan.getCost();
    
    // Calculate average build cardinality for logarithmic lookup cost
    uint64_t totalBuildCardinality = 0;
    for (auto& buildPlan : buildPlans) {
        KU_ASSERT(buildPlan.getCardinality() >= 1);
        totalBuildCardinality += buildPlan.getCardinality();
        cost += buildPlan.getCost();
    }
    
    // Average build cardinality (at least 1)
    uint64_t avgBuildCardinality = std::max<uint64_t>(1, 
        totalBuildCardinality / std::max<size_t>(1, buildPlans.size()));
    
    // Probe cost: each probe tuple requires log(n) work per build side
    // Use integer approximation of log2
    uint64_t logFactor = 0;
    for (uint64_t n = avgBuildCardinality; n > 1; n >>= 1) {
        logFactor++;
    }
    logFactor = std::max<uint64_t>(1, logFactor);
    
    // Probe cost scales with probe cardinality and number of build sides
    cost += probePlan.getCardinality() * logFactor * buildPlans.size();
    
    // Add small penalty to prefer hash join when costs are very close
    // Intersect is the right choice for specific patterns; don't want to
    // accidentally pick it for general cases where hash join is better
    constexpr uint64_t INTERSECT_PENALTY = 10;
    cost += INTERSECT_PENALTY;
    
    return cost;
}

} // namespace planner
} // namespace kuzu
