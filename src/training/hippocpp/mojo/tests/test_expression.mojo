# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Tests for the HippoCPP Expression Module."""


fn test_expression_type_identity():
    """Test ExpressionType identity and equality."""
    from expression import ExpressionType

    let lit = ExpressionType.LITERAL
    let col = ExpressionType.COLUMN
    let lit2 = ExpressionType.LITERAL

    assert_true(lit != col)
    assert_true(lit == lit2)
    print("✓ ExpressionType identity tests passed")


fn test_comparison_symbols():
    """Test ComparisonType symbol generation."""
    from expression import ComparisonType

    assert_equal(ComparisonType.EQUAL.get_symbol(), "=")
    assert_equal(ComparisonType.NOT_EQUAL.get_symbol(), "<>")
    assert_equal(ComparisonType.LESS_THAN.get_symbol(), "<")
    assert_equal(ComparisonType.LESS_THAN_OR_EQUAL.get_symbol(), "<=")
    assert_equal(ComparisonType.GREATER_THAN.get_symbol(), ">")
    assert_equal(ComparisonType.GREATER_THAN_OR_EQUAL.get_symbol(), ">=")
    assert_equal(ComparisonType.IS_NULL.get_symbol(), "IS NULL")
    assert_equal(ComparisonType.IS_NOT_NULL.get_symbol(), "IS NOT NULL")
    assert_equal(ComparisonType.LIKE.get_symbol(), "LIKE")
    assert_equal(ComparisonType.NOT_LIKE.get_symbol(), "NOT LIKE")
    assert_equal(ComparisonType.IN.get_symbol(), "IN")
    assert_equal(ComparisonType.NOT_IN.get_symbol(), "NOT IN")
    print("✓ ComparisonType symbol tests passed")


fn test_aggregate_names():
    """Test AggregateType name generation."""
    from expression import AggregateType

    assert_equal(AggregateType.COUNT.get_name(), "COUNT")
    assert_equal(AggregateType.SUM.get_name(), "SUM")
    assert_equal(AggregateType.AVG.get_name(), "AVG")
    assert_equal(AggregateType.MIN.get_name(), "MIN")
    assert_equal(AggregateType.MAX.get_name(), "MAX")
    assert_equal(AggregateType.COUNT_STAR.get_name(), "COUNT(*)")
    assert_equal(AggregateType.COLLECT.get_name(), "COLLECT")
    assert_equal(AggregateType.STD_DEV.get_name(), "STDDEV")
    assert_equal(AggregateType.VARIANCE.get_name(), "VARIANCE")
    print("✓ AggregateType name tests passed")


fn test_literal_expressions():
    """Test literal expression creation via factory."""
    from expression import ExpressionFactory
    from common import LogicalType

    let null_expr = ExpressionFactory.literal_null()
    assert_true(null_expr.literal_value.is_null)

    let bool_expr = ExpressionFactory.literal_bool(True)
    assert_true(bool_expr.is_literal())
    assert_true(bool_expr.literal_value.to_bool())

    let int_expr = ExpressionFactory.literal_int(99)
    assert_true(int_expr.is_literal())
    assert_equal(int_expr.literal_value.to_int(), 99)

    let dbl_expr = ExpressionFactory.literal_double(3.14)
    assert_true(dbl_expr.is_literal())

    let str_expr = ExpressionFactory.literal_string("hello")
    assert_true(str_expr.is_literal())
    print("✓ Literal expression tests passed")


fn test_column_reference():
    """Test column reference expressions."""
    from expression import ExpressionFactory
    from common import LogicalType

    let col = ExpressionFactory.column_ref("Person", "name", LogicalType.STRING)
    assert_true(col.is_column())
    assert_equal(col.table_name, "Person")
    assert_equal(col.column_name, "name")
    assert_true(not col.has_alias())
    print("✓ Column reference tests passed")


fn test_comparison_expressions():
    """Test comparison expression creation."""
    from expression import ExpressionFactory, ComparisonType
    from common import LogicalType

    let left = ExpressionFactory.column_ref("", "age", LogicalType.INT32)
    let right = ExpressionFactory.literal_int(18)
    let comp = ExpressionFactory.comparison(ComparisonType.GREATER_THAN, left, right)

    assert_true(comp.is_comparison())
    assert_equal(comp.get_num_children(), 2)
    assert_true(comp.data_type == LogicalType.BOOL)
    print("✓ Comparison expression tests passed")


fn test_logical_expressions():
    """Test AND/OR/NOT expressions."""
    from expression import ExpressionFactory, ComparisonType
    from common import LogicalType

    let c1 = ExpressionFactory.comparison(
        ComparisonType.EQUAL,
        ExpressionFactory.column_ref("", "x", LogicalType.INT32),
        ExpressionFactory.literal_int(1)
    )
    let c2 = ExpressionFactory.comparison(
        ComparisonType.EQUAL,
        ExpressionFactory.column_ref("", "y", LogicalType.INT32),
        ExpressionFactory.literal_int(2)
    )

    var children = List[ExpressionFactory.Expression]()
    children.append(c1)
    children.append(c2)

    let conj = ExpressionFactory.conjunction(children)
    assert_equal(conj.get_num_children(), 2)

    let neg = ExpressionFactory.negation(c1)
    assert_equal(neg.get_num_children(), 1)
    print("✓ Logical expression tests passed")


fn test_aggregate_expressions():
    """Test aggregate expression creation."""
    from expression import ExpressionFactory, AggregateType
    from common import LogicalType

    let sum_expr = ExpressionFactory.aggregate(
        AggregateType.SUM,
        ExpressionFactory.column_ref("", "salary", LogicalType.DOUBLE)
    )
    assert_true(sum_expr.is_aggregate())
    assert_equal(sum_expr.get_num_children(), 1)

    let count_star = ExpressionFactory.count_star()
    assert_true(count_star.is_aggregate())
    assert_equal(count_star.get_num_children(), 0)

    let star = ExpressionFactory.star()
    assert_true(not star.is_literal())
    print("✓ Aggregate expression tests passed")


fn main():
    """Run all expression tests."""
    print("Running expression module tests...")
    test_expression_type_identity()
    test_comparison_symbols()
    test_aggregate_names()
    test_literal_expressions()
    test_column_reference()
    test_comparison_expressions()
    test_logical_expressions()
    test_aggregate_expressions()
    print("All expression tests passed! ✓")

