# Service Registry Schema for Mangle Proxy Mesh
# All services expose OpenAI-compliant /v1/chat/completions endpoints
# Mangle rules route requests to the appropriate upstream service

Package service_registry

Import base

# Service definition — each service has an OpenAI-compliant endpoint
Decl service /struct [
  id: /string,              # Unique service identifier
  name: /string,            # Human-readable name
  endpoint: /string,        # OpenAI-compliant endpoint URL
  port: /int,               # Default port
  health_endpoint: /string, # Health check URL
  model_name: /string,      # Model name exposed by this service
  capabilities: /list[/string],  # List of capabilities
  priority: /int,           # Routing priority (lower = higher priority)
  enabled: /bool            # Whether service is active
].

# Service health status
Decl service_health /struct [
  service_id: /string,
  status: health_status,
  latency_ms: /int,
  last_check: /string,
  error_message: /string
].

Decl health_status /kind [
  healthy,
  degraded,
  unhealthy,
  unknown
].

# ============================================================================
# Service Registry — All NucleusAI Services
# ============================================================================

# Neo4j Graph Service
Decl neo4j_service service{
  id: "neo4j-svc",
  name: "Neo4j Graph Database Service",
  endpoint: "http://localhost:9882/v1/chat/completions",
  port: 9882,
  health_endpoint: "http://localhost:9882/health",
  model_name: "neo4j-mcp-v1",
  capabilities: ["cypher", "graph", "gds", "schema", "neo4j", "nodes", "relationships"],
  priority: 1,
  enabled: true
}.

# SAP HANA PAL Service (existing mesh-gateway acts as both gateway AND HANA service)
Decl hana_service service{
  id: "hana-svc",
  name: "SAP HANA PAL Service",
  endpoint: "http://localhost:9881/v1/chat/completions",
  port: 9881,
  health_endpoint: "http://localhost:9881/health",
  model_name: "mcppal-mesh-gateway-v1",
  capabilities: ["hana", "pal", "sql", "vector", "timeseries", "clustering", "classification", "regression"],
  priority: 1,
  enabled: true
}.

# News & GDELT Service
Decl news_service service{
  id: "news-svc",
  name: "News & GDELT Ingestion Service",
  endpoint: "http://localhost:9883/v1/chat/completions",
  port: 9883,
  health_endpoint: "http://localhost:9883/health",
  model_name: "news-svc-v1",
  capabilities: ["news", "gdelt", "events", "sentiment", "geopolitical", "fred", "finnhub"],
  priority: 2,
  enabled: true
}.

# Object Store Service
Decl object_service service{
  id: "object-svc",
  name: "Object Store Service",
  endpoint: "http://localhost:9884/v1/chat/completions",
  port: 9884,
  health_endpoint: "http://localhost:9884/health",
  model_name: "object-store-v1",
  capabilities: ["s3", "gcs", "azure", "blob", "bucket", "object", "file", "upload", "download"],
  priority: 2,
  enabled: true
}.

# Elasticsearch Search Service
Decl search_service service{
  id: "search-svc",
  name: "Elasticsearch Search Service",
  endpoint: "http://localhost:9885/v1/chat/completions",
  port: 9885,
  health_endpoint: "http://localhost:9885/health",
  model_name: "elastic-search-v1",
  capabilities: ["elasticsearch", "search", "fulltext", "logs", "kibana", "index"],
  priority: 2,
  enabled: true
}.

# Universal Prompt / Agent Service
Decl agent_service service{
  id: "agent-svc",
  name: "Universal Prompt Agent Service",
  endpoint: "http://localhost:9886/v1/chat/completions",
  port: 9886,
  health_endpoint: "http://localhost:9886/health",
  model_name: "universal-prompt-v1",
  capabilities: ["agent", "rag", "memory", "embeddings", "discovery", "data"],
  priority: 1,
  enabled: true
}.

# Pipeline Service (LangHana)
Decl pipeline_service service{
  id: "pipeline-svc",
  name: "LangHana Pipeline Service",
  endpoint: "http://localhost:9887/v1/chat/completions",
  port: 9887,
  health_endpoint: "http://localhost:9887/health",
  model_name: "langhana-pipeline-v1",
  capabilities: ["pipeline", "vectorstore", "mmr", "langchain"],
  priority: 2,
  enabled: true
}.

# ============================================================================
# Service List — All registered services
# ============================================================================

Decl all_services /list[service] [
  neo4j_service,
  hana_service,
  news_service,
  object_service,
  search_service,
  agent_service,
  pipeline_service
].

# ============================================================================
# Routing Helper Facts
# ============================================================================

# Map capability keywords to service IDs
Decl capability_to_service(Capability, ServiceId) :-
  service(S),
  S.enabled = true,
  member(Capability, S.capabilities),
  ServiceId = S.id.

# Get service by ID
Decl get_service(ServiceId, Service) :-
  service(Service),
  Service.id = ServiceId.

# Get endpoint for service
Decl service_endpoint(ServiceId, Endpoint) :-
  service(S),
  S.id = ServiceId,
  Endpoint = S.endpoint.

# Find best service for capability (lowest priority wins)
Decl best_service_for(Capability, ServiceId) :-
  capability_to_service(Capability, ServiceId),
  service(S),
  S.id = ServiceId,
  not(exists(S2: service(S2), capability_to_service(Capability, S2.id), S2.priority < S.priority)).

End Package