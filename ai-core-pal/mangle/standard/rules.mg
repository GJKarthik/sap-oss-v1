# Mangle ODPS Standard - Rules
# Derived predicates computed from facts
# ODPS 4.1 compliant rule definitions

# =============================================================================
# QUALITY
# =============================================================================
# Quality scores derived from measurements

Decl quality(product_id: string, dimension: string, score: float) :-
  measurement(product_id, dimension, score, _),
  dimension = "accuracy"; dimension = "completeness"; dimension = "timeliness";
  dimension = "consistency"; dimension = "validity"; dimension = "uniqueness".

Decl quality_current(product_id: string, dimension: string, score: float, measured_at: datetime) :-
  measurement(product_id, dimension, score, measured_at),
  !measurement(product_id, dimension, _, newer),
  newer > measured_at.

Decl high_quality(product_id: string) :-
  quality(product_id, "accuracy", acc),
  quality(product_id, "completeness", comp),
  acc >= 95.0,
  comp >= 95.0.

Decl quality_issue(product_id: string, dimension: string, score: float) :-
  quality(product_id, dimension, score),
  score < 80.0.

# =============================================================================
# LINEAGE (Transitive)
# =============================================================================
# Recursive dependency resolution

Decl depends_on(product: string, source: string) :-
  lineage(product, source, _).

Decl depends_on(product: string, source: string) :-
  lineage(product, intermediate, _),
  depends_on(intermediate, source).

Decl upstream(product: string, count: integer) :-
  product(product, _, _, _, _),
  count = count { depends_on(product, _) }.

Decl downstream(product: string, count: integer) :-
  product(product, _, _, _, _),
  count = count { depends_on(_, product) }.

Decl orphan(product_id: string) :-
  product(product_id, _, _, _, "production"),
  !depends_on(_, product_id),
  !lineage(product_id, _, _).

Decl circular_dependency(product: string) :-
  depends_on(product, product).

# =============================================================================
# SLA COMPLIANCE
# =============================================================================
# SLA status derived from measurements

Decl sla_compliant(product_id: string) :-
  sla(product_id, _, target_avail, _),
  sla_measurement(product_id, actual_avail, _, _, _),
  actual_avail >= target_avail.

Decl sla_breach(product_id: string, gap: float) :-
  sla(product_id, _, target_avail, _),
  sla_measurement(product_id, actual_avail, _, _, _),
  actual_avail < target_avail,
  let gap = target_avail - actual_avail.

# =============================================================================
# ACCESS CONTROL
# =============================================================================
# Access status derived from grants

Decl has_access(consumer_id: string, product_id: string) :-
  access_grant(consumer_id, product_id, _, _, expires),
  expires > fn:now().

Decl access_expired(consumer_id: string, product_id: string, expired_at: datetime) :-
  access_grant(consumer_id, product_id, _, _, expired_at),
  expired_at <= fn:now().

Decl access_expiring_soon(consumer_id: string, product_id: string, days_remaining: integer) :-
  access_grant(consumer_id, product_id, _, _, expires),
  let days_remaining = fn:days_between(fn:now(), expires),
  days_remaining <= 30,
  days_remaining > 0.

# =============================================================================
# PRODUCT STATUS
# =============================================================================
# Product health derived from multiple factors

Decl product_healthy(product_id: string) :-
  product(product_id, _, _, _, "production"),
  high_quality(product_id),
  sla_compliant(product_id).

Decl product_needs_attention(product_id: string, reason: string) :-
  quality_issue(product_id, _, _),
  let reason = "quality_below_threshold".

Decl product_needs_attention(product_id: string, reason: string) :-
  sla_breach(product_id, _),
  let reason = "sla_breach".

Decl product_needs_attention(product_id: string, reason: string) :-
  product(product_id, _, _, _, "sunset"),
  depends_on(dependent, product_id),
  product(dependent, _, _, _, "production"),
  let reason = "sunset_with_dependents".

# =============================================================================
# LICENSE COMPLIANCE
# =============================================================================
# License obligations

Decl requires_attribution(product_id: string) :-
  license(product_id, _, _, true, _).

Decl commercial_allowed(product_id: string) :-
  license(product_id, _, _, _, true).

# =============================================================================
# RESOURCE AGGREGATION
# =============================================================================
# Resource counts and types

Decl resource_count(product_id: string, count: integer) :-
  product(product_id, _, _, _, _),
  count = count { resource(_, product_id, _, _) }.

Decl has_resource_type(product_id: string, type: string) :-
  resource(_, product_id, type, _).