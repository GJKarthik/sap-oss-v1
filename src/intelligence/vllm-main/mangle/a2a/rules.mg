# Agent-to-Agent (A2A) Protocol - Rules
# Derived predicates for service mesh communication
# No hardcoded facts - uses declared predicates from facts.mg

# =============================================================================
# SERVICE AVAILABILITY
# =============================================================================

# A service is routable if registered and available
Decl routable(service_name: string) :-
  service_registry(service_name, _, _),
  service_status(service_name, /available).

# A service is degraded but usable
Decl usable(service_name: string) :-
  service_registry(service_name, _, _),
  service_status(service_name, Status),
  Status = /available; Status = /degraded.

# =============================================================================
# INTENT ROUTING
# =============================================================================

# Resolve intent to service URL
Decl resolve_service_for_intent(intent_id: atom, url: string) :-
  intent_service_mapping(intent_id, service_name, endpoint_path),
  routable(service_name),
  service_registry(service_name, base_url, _),
  url = fn:concat(base_url, endpoint_path).

# Fallback intent resolution (if primary unavailable)
Decl resolve_fallback_service(intent_id: atom, url: string) :-
  intent_service_mapping(intent_id, primary_service, _),
  !routable(primary_service),
  service_capability(fallback_service, /chat),
  routable(fallback_service),
  service_registry(fallback_service, base_url, _),
  url = fn:concat(base_url, "/v1/chat/completions").

# =============================================================================
# REQUEST GENERATION
# =============================================================================

# Generate OpenAI-compliant request body
Decl a2a_request(service_name: string, prompt: string, body: string) :-
  service_registry(service_name, _, model),
  body = fn:json_object(
    "model", model,
    "messages", fn:json_array(
      fn:json_object("role", "user", "content", prompt)
    ),
    "temperature", 0.0
  ).

# Generate request with custom model
Decl a2a_request_with_model(service_name: string, model: string, prompt: string, body: string) :-
  service_registry(service_name, _, _),
  body = fn:json_object(
    "model", model,
    "messages", fn:json_array(
      fn:json_object("role", "user", "content", prompt)
    ),
    "temperature", 0.0
  ).

# =============================================================================
# RESPONSE ANALYSIS
# =============================================================================

# Extract optimization hints from response content
Decl optimization_hint(hint: string) :-
  api_response(_, content, _, _),
  fn:contains(content, "skewed distribution"),
  hint = "Use Isolation Forest".

Decl optimization_hint(hint: string) :-
  api_response(_, content, _, _),
  fn:contains(content, "time series pattern"),
  hint = "Use LSTM".

Decl optimization_hint(hint: string) :-
  api_response(_, content, _, _),
  fn:contains(content, "anomaly detected"),
  hint = "Investigate outliers".

# =============================================================================
# SERVICE HEALTH
# =============================================================================

# Service is healthy if recent responses have low latency
Decl service_healthy(service_name: string) :-
  api_response(req_id, _, latency_ms, _),
  api_request(req_id, service_name, _, _, _),
  latency_ms < 1000.

# Service is slow if latency exceeds threshold
Decl service_slow(service_name: string, avg_latency: float) :-
  service_registry(service_name, _, _),
  avg_latency = avg { api_response(req_id, _, latency, _) :
                      api_request(req_id, service_name, _, _, _),
                      latency },
  avg_latency > 2000.

# =============================================================================
# MODEL SELECTION
# =============================================================================

# Find best model for a specialization
Decl best_model_for(specialization: atom, model_name: string, service_name: string) :-
  model_specialization(model_name, specialization),
  model_registry(model_name, service_name, _),
  routable(service_name).

# Find model with sufficient context
Decl model_for_context(min_context: integer, model_name: string, service_name: string) :-
  model_registry(model_name, service_name, context_length),
  context_length >= min_context,
  routable(service_name).

# =============================================================================
# CAPABILITY MATCHING
# =============================================================================

# Find all services with a capability
Decl services_with_capability(capability: atom, service_name: string) :-
  service_capability(service_name, capability),
  routable(service_name).

# Check if intent can be fulfilled
Decl can_fulfill_intent(intent_id: atom) :-
  intent_service_mapping(intent_id, service_name, _),
  routable(service_name).

Decl cannot_fulfill_intent(intent_id: atom, reason: string) :-
  intent_service_mapping(intent_id, service_name, _),
  !routable(service_name),
  reason = fn:concat("Service unavailable: ", service_name).

# =============================================================================
# INTENT DETECTION
# =============================================================================
# Pattern-based intent classification

Decl detects_intent(pattern: string, intent_id: atom) :-
  keyword_pattern(pattern, intent_id),
  intent(intent_id).

Decl should_enhance(message_content: string, intent_id: atom) :-
  detects_intent(pattern, intent_id),
  fn:contains(message_content, pattern).

# =============================================================================
# PROMPT ENHANCEMENT
# =============================================================================
# Build enhanced prompts based on detected intent

Decl enhancement_config(intent_id: atom, system_prompt_text: string, temperature: float) :-
  system_prompt(intent_id, system_prompt_text),
  recommended_temp(intent_id, temperature).

Decl enhance_request(intent_id: atom, system_prompt_text: string, temperature: float, format_instr: string) :-
  system_prompt(intent_id, system_prompt_text),
  recommended_temp(intent_id, temperature),
  format_instruction(intent_id, format_instr).

Decl enhance_request_basic(intent_id: atom, system_prompt_text: string, temperature: float) :-
  system_prompt(intent_id, system_prompt_text),
  recommended_temp(intent_id, temperature),
  !format_instruction(intent_id, _).

# =============================================================================
# MODEL SELECTION BY CAPABILITY
# =============================================================================
# Select best model for a given intent

Decl best_model(intent_id: atom, model_name: atom) :-
  model_capability(model_name, intent_id),
  intent(intent_id).

Decl model_for_capability(capability: atom, model_name: atom, service_name: string) :-
  model_capability(model_name, capability),
  model_registry(model_name, service_name, _),
  routable(service_name).

# =============================================================================
# POINTER RESOLUTION
# =============================================================================
# Fractal and TOON pointer navigation

Decl resolve_fractal(pointer_id: string, full_url: string) :-
  fractal_pointer(pointer_id, target_service, target_resource, _),
  service_registry(target_service, base_url, _),
  routable(target_service),
  full_url = fn:concat(base_url, "/", target_resource).

Decl deep_pointer(pointer_id: string) :-
  fractal_pointer(pointer_id, _, _, depth),
  depth > 1.

# =============================================================================
# SERVICE HEALTH CONTRACT
# =============================================================================

# Health contract: every registered service must expose /health
Decl service_health_endpoint(service_name: string, health_url: string) :-
  service_registry(service_name, base_url, _),
  health_url = fn:concat(base_url, "/../health").

# All services in mesh are compliant when they follow the contract
Decl mesh_compliant() :-
  forall(service_registry(S, _, _), service_status(S, /available)).
