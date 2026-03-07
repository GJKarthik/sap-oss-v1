#include "planner/join_order/join_plan_solver.h"

#include "common/enums/extend_direction.h"

using namespace kuzu::binder;
using namespace kuzu::common;

namespace kuzu {
namespace planner {

LogicalPlan JoinPlanSolver::solve(const JoinTree& joinTree) {
    return solveTreeNode(*joinTree.root, nullptr);
}

LogicalPlan JoinPlanSolver::solveTreeNode(const JoinTreeNode& current, const JoinTreeNode* parent) {
    switch (current.type) {
    case TreeNodeType::NODE_SCAN: {
        return solveNodeScanTreeNode(current);
    }
    case TreeNodeType::REL_SCAN: {
        KU_ASSERT(parent != nullptr);
        return solveRelScanTreeNode(current, *parent);
    }
    case TreeNodeType::BINARY_JOIN: {
        return solveBinaryJoinTreeNode(current);
    }
    case TreeNodeType::MULTIWAY_JOIN: {
        return solveMultiwayJoinTreeNode(current);
    }
    default:
        KU_UNREACHABLE;
    }
}

static ExtendDirection getExtendDirection(const RelExpression& rel,
    const NodeExpression& boundNode) {
    if (rel.getDirectionType() == binder::RelDirectionType::BOTH) {
        return ExtendDirection::BOTH;
    }
    if (*rel.getSrcNode() == boundNode) {
        return ExtendDirection::FWD;
    } else {
        return ExtendDirection::BWD;
    }
}

static std::shared_ptr<binder::NodeExpression> getOtherNode(const RelExpression& rel,
    const NodeExpression& boundNode) {
    if (*rel.getSrcNode() == boundNode) {
        return rel.getDstNode();
    }
    return rel.getSrcNode();
}

LogicalPlan JoinPlanSolver::solveNodeScanTreeNode(const JoinTreeNode& treeNode) {
    auto& extraInfo = treeNode.extraInfo->constCast<ExtraScanTreeNodeInfo>();
    KU_ASSERT(extraInfo.nodeInfo != nullptr);
    auto& nodeInfo = *extraInfo.nodeInfo;
    auto boundNode = std::static_pointer_cast<NodeExpression>(nodeInfo.nodeOrRel);
    auto plan = LogicalPlan();
    planner->appendScanNodeTable(boundNode->getInternalID(), boundNode->getTableIDs(),
        nodeInfo.properties, plan);
    planner->appendFilters(nodeInfo.predicates, plan);
    for (auto& relInfo : extraInfo.relInfos) {
        auto rel = std::static_pointer_cast<RelExpression>(relInfo.nodeOrRel);
        auto nbrNode = getOtherNode(*rel, *boundNode);
        auto direction = getExtendDirection(*rel, *boundNode);
        planner->appendExtend(boundNode, nbrNode, rel, direction, relInfo.properties, plan);
        planner->appendFilters(relInfo.predicates, plan);
    }
    planner->appendFilters(extraInfo.predicates, plan);
    return plan;
}

LogicalPlan JoinPlanSolver::solveRelScanTreeNode(const JoinTreeNode& treeNode,
    const JoinTreeNode& parent) {
    auto& extraInfo = treeNode.extraInfo->constCast<ExtraScanTreeNodeInfo>();
    auto& relInfo = extraInfo.relInfos[0];
    auto rel = std::static_pointer_cast<RelExpression>(relInfo.nodeOrRel);
    std::shared_ptr<NodeExpression> boundNode = nullptr;
    std::shared_ptr<NodeExpression> nbrNode = nullptr;
    switch (parent.type) {
    case TreeNodeType::BINARY_JOIN: {
        auto& joinExtraInfo = parent.extraInfo->constCast<ExtraJoinTreeNodeInfo>();
        if (joinExtraInfo.joinNodes.size() == 1) {
            boundNode = joinExtraInfo.joinNodes[0];
        } else {
            boundNode = rel->getSrcNode();
        }
        nbrNode = getOtherNode(*rel, *boundNode);
    } break;
    case TreeNodeType::MULTIWAY_JOIN: {
        auto& joinExtraInfo = parent.extraInfo->constCast<ExtraJoinTreeNodeInfo>();
        KU_ASSERT(joinExtraInfo.joinNodes.size() == 1);
        nbrNode = joinExtraInfo.joinNodes[0];
        boundNode = getOtherNode(*rel, *nbrNode);
    } break;
    default:
        KU_UNREACHABLE;
    }
    auto direction = getExtendDirection(*rel, *boundNode);
    auto plan = LogicalPlan();
    planner->appendScanNodeTable(boundNode->getInternalID(), boundNode->getTableIDs(),
        expression_vector{}, plan);
    planner->appendExtend(boundNode, nbrNode, rel, direction, relInfo.properties, plan);
    planner->appendFilters(relInfo.predicates, plan);
    return plan;
}

LogicalPlan JoinPlanSolver::solveBinaryJoinTreeNode(const JoinTreeNode& treeNode) {
    auto probePlan = solveTreeNode(*treeNode.children[0], &treeNode);
    auto buildPlan = solveTreeNode(*treeNode.children[1], &treeNode);
    auto& extraInfo = treeNode.extraInfo->constCast<ExtraJoinTreeNodeInfo>();
    binder::expression_vector joinNodeIDs;
    for (auto& expr : extraInfo.joinNodes) {
        joinNodeIDs.push_back(expr->constCast<NodeExpression>().getInternalID());
    }
    auto plan = LogicalPlan();
    planner->appendHashJoin(joinNodeIDs, JoinType::INNER, probePlan, buildPlan, plan);
    planner->appendFilters(extraInfo.predicates, plan);
    return plan;
}

// Multiway Join Solver:
// Multiway joins are used for patterns like (a)-[r1]-(b)-[r2]-(c) where node 'b' must
// satisfy multiple edge relationships. This is more efficient than pairwise binary joins
// when the intersection is expected to be small.
//
// Current Plan Construction Issue:
// The appendIntersect() method modifies probePlan in-place and doesn't return the updated plan.
// This creates a mismatch with our expected pattern where we'd like to do:
//   planner->appendIntersect(..., &plan);  // Append to 'plan' directly
//
// Current Workaround:
// 1. Call appendIntersect() which modifies probePlan
// 2. Transfer the operator from probePlan to our result plan
// 3. Continue appending filters to result plan
//
// Future Improvement:
// Provide a consistent interface across all append* methods that either:
// - Option A: All methods take a plan reference and modify it in-place
// - Option B: All methods return a new LogicalPlan (immutable style)
// - Option C: All methods take an output plan parameter
//
// Currently, appendHashJoin() works with Option C (takes output plan parameter),
// while appendIntersect() uses in-place modification of probePlan.
// This inconsistency should be addressed for cleaner code.
LogicalPlan JoinPlanSolver::solveMultiwayJoinTreeNode(const JoinTreeNode& treeNode) {
    auto& extraInfo = treeNode.extraInfo->constCast<ExtraJoinTreeNodeInfo>();
    KU_ASSERT(extraInfo.joinNodes.size() == 1);
    auto& joinNode = extraInfo.joinNodes[0]->constCast<NodeExpression>();
    
    // Solve probe side - this will be the base of our multiway join
    auto probePlan = solveTreeNode(*treeNode.children[0], &treeNode);
    
    // Collect all build sides and their bound node IDs
    std::vector<LogicalPlan> buildPlans;
    expression_vector boundNodeIDs;
    for (auto i = 1u; i < treeNode.children.size(); ++i) {
        auto child = treeNode.children[i];
        KU_ASSERT(child->type == TreeNodeType::REL_SCAN);
        auto& childExtraInfo = child->extraInfo->constCast<ExtraScanTreeNodeInfo>();
        auto rel = std::static_pointer_cast<RelExpression>(childExtraInfo.relInfos[0].nodeOrRel);
        auto boundNode = *rel->getSrcNode() == joinNode ? rel->getDstNode() : rel->getSrcNode();
        buildPlans.push_back(solveTreeNode(*child, &treeNode).copy());
        boundNodeIDs.push_back(boundNode->constCast<NodeExpression>().getInternalID());
    }
    
    auto plan = LogicalPlan();
    
    // Note: appendIntersect modifies probePlan in-place rather than appending to 'plan'.
    // This is inconsistent with appendHashJoin which takes an output plan parameter.
    // We transfer the result to our plan after the call.
    // Future: Refactor appendIntersect to match appendHashJoin's interface:
    //   planner->appendIntersect(joinNodeID, boundNodeIDs, probePlan, buildPlans, plan);
    planner->appendIntersect(joinNode.getInternalID(), boundNodeIDs, probePlan, buildPlans);
    
    // Transfer the intersect operator to our result plan
    plan.setLastOperator(probePlan.getLastOperator());
    
    // Apply any predicates that couldn't be pushed into the intersect
    planner->appendFilters(extraInfo.predicates, plan);
    
    return plan;
}

} // namespace planner
} // namespace kuzu
