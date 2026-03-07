#include "storage/predicate/column_predicate.h"

/**
 * P3-205: ColumnPredicate - Zone Map Filtering Predicates
 * 
 * Purpose:
 * Converts query predicates into column predicates for zone map filtering.
 * Enables skipping entire chunks based on min/max statistics.
 * 
 * Architecture:
 * ```
 * ColumnPredicate (abstract)
 *   ├── ColumnConstantPredicate   // column op constant
 *   └── ColumnNullPredicate       // IS NULL / IS NOT NULL
 * 
 * ColumnPredicateSet {
 *   predicates: vector<unique_ptr<ColumnPredicate>>
 * }
 * ```
 * 
 * ZoneMapCheckResult:
 * | Result | Description |
 * |--------|-------------|
 * | SKIP_SCAN | Entire chunk can be skipped |
 * | ALWAYS_SCAN | Chunk must be scanned |
 * 
 * checkZoneMap() Logic:
 * ```
 * ColumnPredicateSet::checkZoneMap(stats):
 *   FOR each predicate:
 *     IF predicate.checkZoneMap(stats) == SKIP_SCAN:
 *       RETURN SKIP_SCAN  // Short-circuit
 *   RETURN ALWAYS_SCAN
 * ```
 * 
 * Expression Analysis:
 * ```
 * isColumnRef(type):
 *   RETURN type == PROPERTY || type == VARIABLE
 * 
 * isCastedColumnRef(expr):
 *   IF expr is FUNCTION and name starts with "CAST":
 *     RETURN isColumnRef(expr.getChild(0))
 *   RETURN false
 * ```
 * 
 * tryConvert() Dispatch:
 * ```
 * tryConvert(property, predicate):
 *   IF predicate is comparison (=, <, >, <=, >=, <>):
 *     RETURN tryConvertToConstColumnPredicate()
 *   SWITCH predicate.type:
 *     IS_NULL: RETURN tryConvertToIsNull()
 *     IS_NOT_NULL: RETURN tryConvertToIsNotNull()
 *   RETURN nullptr  // Cannot convert
 * ```
 * 
 * tryConvertToConstColumnPredicate() Logic:
 * ```
 * tryConvertToConstColumnPredicate(column, predicate):
 *   IF child[0] is column ref AND child[1] is literal:
 *     value = literal.getValue()
 *     RETURN ColumnConstantPredicate(column, op, value)
 *   
 *   IF child[1] is column ref AND child[0] is literal:
 *     value = literal.getValue()
 *     op = reverseComparisonDirection(op)  // e.g., < becomes >
 *     RETURN ColumnConstantPredicate(column, op, value)
 *   
 *   RETURN nullptr
 * ```
 * 
 * Supported Predicates:
 * | Expression | Converts To |
 * |------------|-------------|
 * | col = 5 | ColumnConstantPredicate(col, =, 5) |
 * | 5 < col | ColumnConstantPredicate(col, >, 5) |
 * | col IS NULL | ColumnNullPredicate(col, IS_NULL) |
 * | col IS NOT NULL | ColumnNullPredicate(col, IS_NOT_NULL) |
 * 
 * Zone Map Optimization:
 * ```
 * Example: WHERE age > 50
 * 
 * Chunk 1: min=20, max=40 → SKIP_SCAN (max < 50)
 * Chunk 2: min=35, max=65 → ALWAYS_SCAN (overlaps)
 * Chunk 3: min=60, max=80 → ALWAYS_SCAN (all qualify)
 * ```
 * 
 * Usage:
 * ```cpp
 * auto predicate = ColumnPredicateUtil::tryConvert(property, expr);
 * if (predicate) {
 *   predicateSet.addPredicate(std::move(predicate));
 * }
 * 
 * // During scan
 * if (predicateSet.checkZoneMap(chunkStats) == SKIP_SCAN) {
 *   continue;  // Skip entire chunk
 * }
 * ```
 */

#include "binder/expression/literal_expression.h"
#include "binder/expression/scalar_function_expression.h"
#include "storage/predicate/constant_predicate.h"
#include "storage/predicate/null_predicate.h"

using namespace kuzu::binder;
using namespace kuzu::common;

namespace kuzu {
namespace storage {

ZoneMapCheckResult ColumnPredicateSet::checkZoneMap(const MergedColumnChunkStats& stats) const {
    for (auto& predicate : predicates) {
        if (predicate->checkZoneMap(stats) == ZoneMapCheckResult::SKIP_SCAN) {
            return ZoneMapCheckResult::SKIP_SCAN;
        }
    }
    return ZoneMapCheckResult::ALWAYS_SCAN;
}

std::string ColumnPredicateSet::toString() const {
    if (predicates.empty()) {
        return {};
    }
    auto result = predicates[0]->toString();
    for (auto i = 1u; i < predicates.size(); ++i) {
        result += stringFormat(" AND {}", predicates[i]->toString());
    }
    return result;
}

static bool isColumnRef(ExpressionType type) {
    return type == ExpressionType::PROPERTY || type == ExpressionType::VARIABLE;
}

static bool isCastedColumnRef(const Expression& expr) {
    if (expr.expressionType == ExpressionType::FUNCTION) {
        const auto& funcExpr = expr.constCast<ScalarFunctionExpression>();
        if (funcExpr.getFunction().name.starts_with("CAST")) {
            KU_ASSERT(funcExpr.getNumChildren() > 0);
            return isColumnRef(funcExpr.getChild(0)->expressionType);
        }
    }
    return false;
}

static bool isColumnOrCastedColumnRef(const Expression& expr) {
    return isColumnRef(expr.expressionType) || isCastedColumnRef(expr);
}

static bool isColumnRefConstantPair(const Expression& left, const Expression& right) {
    return isColumnOrCastedColumnRef(left) && right.expressionType == ExpressionType::LITERAL;
}

static bool columnMatchesExprChild(const Expression& column, const Expression& expr) {
    return (expr.getNumChildren() > 0 && column == *expr.getChild(0));
}

static std::unique_ptr<ColumnPredicate> tryConvertToConstColumnPredicate(const Expression& column,
    const Expression& predicate) {
    if (isColumnRefConstantPair(*predicate.getChild(0), *predicate.getChild(1))) {
        if (column != *predicate.getChild(0) &&
            !columnMatchesExprChild(column, *predicate.getChild(0))) {
            return nullptr;
        }
        auto value = predicate.getChild(1)->constCast<LiteralExpression>().getValue();
        return std::make_unique<ColumnConstantPredicate>(column.toString(),
            predicate.expressionType, value);
    } else if (isColumnRefConstantPair(*predicate.getChild(1), *predicate.getChild(0))) {
        if (column != *predicate.getChild(1) &&
            !columnMatchesExprChild(column, *predicate.getChild(1))) {
            return nullptr;
        }
        auto value = predicate.getChild(0)->constCast<LiteralExpression>().getValue();
        auto expressionType =
            ExpressionTypeUtil::reverseComparisonDirection(predicate.expressionType);
        return std::make_unique<ColumnConstantPredicate>(column.toString(), expressionType, value);
    }
    // Not a predicate that runs on this property.
    return nullptr;
}

static std::unique_ptr<ColumnPredicate> tryConvertToIsNull(const Expression& column,
    const Expression& predicate) {
    // we only convert simple predicates
    if (isColumnOrCastedColumnRef(*predicate.getChild(0)) && column == *predicate.getChild(0)) {
        return std::make_unique<ColumnNullPredicate>(column.toString(), ExpressionType::IS_NULL);
    }
    return nullptr;
}

static std::unique_ptr<ColumnPredicate> tryConvertToIsNotNull(const Expression& column,
    const Expression& predicate) {
    if (isColumnOrCastedColumnRef(*predicate.getChild(0)) && column == *predicate.getChild(0)) {
        return std::make_unique<ColumnNullPredicate>(column.toString(),
            ExpressionType::IS_NOT_NULL);
    }
    return nullptr;
}

std::unique_ptr<ColumnPredicate> ColumnPredicateUtil::tryConvert(const Expression& property,
    const Expression& predicate) {
    if (ExpressionTypeUtil::isComparison(predicate.expressionType)) {
        return tryConvertToConstColumnPredicate(property, predicate);
    }
    switch (predicate.expressionType) {
    case common::ExpressionType::IS_NULL:
        return tryConvertToIsNull(property, predicate);
    case common::ExpressionType::IS_NOT_NULL:
        return tryConvertToIsNotNull(property, predicate);
    default:
        return nullptr;
    }
}

std::string ColumnPredicate::toString() {
    return stringFormat("{} {}", columnName, ExpressionTypeUtil::toParsableString(expressionType));
}

} // namespace storage
} // namespace kuzu
