# Mangle ODPS Standard - Aggregations
# Standard aggregation operations
# Reference documentation for aggregation syntax

# =============================================================================
# AGGREGATION SYNTAX
# =============================================================================
# 
# Aggregations use set comprehension syntax:
#   result = agg { pattern : condition1, condition2 }
#
# Where:
#   - agg is the aggregation function (count, sum, max, min, avg)
#   - pattern is the expression to aggregate
#   - conditions filter what gets aggregated

# =============================================================================
# COUNT
# =============================================================================
# Counts matching items

# count { predicate(args) }
# Counts all matching facts
#
# Example: Count products per status
# Decl product_count(status: string, count: integer) :-
#   product(_, _, _, _, status),
#   count = count { product(_, _, _, _, status) }.

# =============================================================================
# SUM
# =============================================================================
# Sums numeric values

# sum { expression : conditions }
# Sums all matching values
#
# Example: Total measurements per product
# Decl total_measurements(product_id: string, total: float) :-
#   product(product_id, _, _, _, _),
#   total = sum { measurement(product_id, _, value, _) : value }.

# =============================================================================
# MAX
# =============================================================================
# Finds maximum value

# max { expression : conditions }
# Returns maximum matching value
#
# Example: Latest measurement timestamp
# Decl latest_measurement(product_id: string, latest: datetime) :-
#   product(product_id, _, _, _, _),
#   latest = max { measurement(product_id, _, _, ts) : ts }.

# =============================================================================
# MIN
# =============================================================================
# Finds minimum value

# min { expression : conditions }
# Returns minimum matching value
#
# Example: Earliest access grant
# Decl earliest_grant(product_id: string, earliest: datetime) :-
#   product(product_id, _, _, _, _),
#   earliest = min { access_grant(_, product_id, _, granted, _) : granted }.

# =============================================================================
# AVG
# =============================================================================
# Calculates average value

# avg { expression : conditions }
# Returns average of matching values
#
# Example: Average quality score
# Decl avg_quality(product_id: string, average: float) :-
#   product(product_id, _, _, _, _),
#   average = avg { measurement(product_id, _, value, _) : value }.

# =============================================================================
# COMBINING AGGREGATIONS
# =============================================================================
# Multiple aggregations in a single rule

# Example: Product statistics
# Decl product_stats(product_id: string, total: float, maximum: float, minimum: float) :-
#   product(product_id, _, _, _, _),
#   total = sum { measurement(product_id, _, v, _) : v },
#   maximum = max { measurement(product_id, _, v, _) : v },
#   minimum = min { measurement(product_id, _, v, _) : v }.

# =============================================================================
# GROUPED AGGREGATIONS
# =============================================================================
# Aggregations with grouping

# Example: Count by category
# Decl category_count(category: string, count: integer) :-
#   product_category(_, category),
#   count = count { product_category(_, category) }.

# Example: Sum by type
# Decl type_total(type: string, total: float) :-
#   resource(_, _, type, _),
#   total = sum { resource_property(uri, "size", size) : 
#                 resource(uri, _, type, _),
#                 fn:to_float(size) }.