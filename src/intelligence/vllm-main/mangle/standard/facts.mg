# Mangle ODPS Standard - Facts
# Base predicates for data product definitions
# ODPS 4.1 compliant fact declarations

# =============================================================================
# DOCUMENT
# =============================================================================
# Root document container

Decl document(
  id: string,
  schema_url: string,
  version: string
).

Decl document_metadata(
  document_id: string,
  created_by: string,
  created_at: datetime,
  modified_at: datetime
).

# =============================================================================
# PRODUCT
# =============================================================================
# Data product core facts

Decl product(
  id: string,
  name: string,
  description: string,
  version: string,
  status: string                      # draft|production|sunset|retired
).

Decl product_owner(
  product_id: string,
  name: string,
  email: string,
  role: string                        # owner|steward|support
).

Decl product_tag(
  product_id: string,
  tag: string
).

Decl product_category(
  product_id: string,
  category: string
).

# =============================================================================
# MEASUREMENT
# =============================================================================
# Raw measurements (quality, SLA, usage derived from these)

Decl measurement(
  product_id: string,
  metric: string,
  value: float,
  timestamp: datetime
) temporal.

# =============================================================================
# LINEAGE
# =============================================================================
# Data lineage relationships

Decl lineage(
  target: string,
  source: string,
  type: string                        # source|derived|enriched
).

Decl column_lineage(
  target_product: string,
  target_column: string,
  source_product: string,
  source_column: string
).

# =============================================================================
# ACCESS
# =============================================================================
# Access control facts

Decl access_grant(
  consumer_id: string,
  product_id: string,
  role: string,
  granted_at: datetime,
  expires_at: datetime
) temporal.

Decl access_role(
  product_id: string,
  role_name: string,
  permissions: string                 # read|write|admin
).

# =============================================================================
# SLA
# =============================================================================
# Service level agreement definitions

Decl sla(
  product_id: string,
  tier: string,
  availability_target: float,
  latency_max_ms: integer
).

Decl sla_measurement(
  product_id: string,
  actual_availability: float,
  actual_latency_ms: integer,
  period_start: datetime,
  period_end: datetime
) temporal.

# =============================================================================
# LICENSE
# =============================================================================
# Licensing and legal

Decl license(
  product_id: string,
  license_type: string,
  spdx_id: string,
  attribution_required: boolean,
  commercial_use: boolean
).

# =============================================================================
# RESOURCE (Platform Artifacts)
# =============================================================================
# Physical resources backing data products

Decl resource(
  uri: string,
  product_id: string,
  type: string,                       # hana_table|object_store|graph|vector
  name: string
).

Decl resource_property(
  resource_uri: string,
  property: string,
  value: string
).

# =============================================================================
# SERVICE
# =============================================================================
# Available service endpoints

Decl service(
  product_id: string,
  service_name: string,
  endpoint_url: string,
  protocol: string                    # rest|graphql|grpc|odata
).

Decl service_operation(
  service_name: string,
  operation: string,
  method: string,
  path: string
).