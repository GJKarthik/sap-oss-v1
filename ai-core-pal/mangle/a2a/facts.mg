# Agent-to-Agent (A2A) Protocol - Facts
# Declarations only - no hardcoded ground facts
# Ground facts loaded from config at runtime

# =============================================================================
# SERVICE REGISTRY
# =============================================================================
# Services available in the mesh

Decl service_registry(
  service_name: string,
  base_url: string,
  default_model: string
).

Decl service_status(
  service_name: string,
  status: atom                        # /available|/unavailable|/degraded
) temporal.

Decl service_capability(
  service_name: string,
  capability: atom                    # /chat|/search|/graph|/mangle|/rag
).

# =============================================================================
# INTENT
# =============================================================================
# Intents that can be routed to services

Decl intent(intent_id: atom).

Decl intent_service_mapping(
  intent_id: atom,
  service_name: string,
  endpoint_path: string
).

# =============================================================================
# API INTERACTION
# =============================================================================
# Request and response tracking

Decl api_request(
  request_id: string,
  service_name: string,
  model: string,
  prompt: string,
  timestamp: datetime
) temporal.

Decl api_response(
  request_id: string,
  content: string,
  latency_ms: integer,
  timestamp: datetime
) temporal.

# =============================================================================
# MODEL REGISTRY
# =============================================================================
# Models available across services

Decl model_registry(
  model_name: string,
  service_name: string,
  context_length: integer
).

Decl model_specialization(
  model_name: string,
  specialization: atom               # /code|/analysis|/reasoning|/chat
).

Decl model_capability(
  model_name: atom,
  capability: atom                   # /code|/analysis|/log_analysis|/summarization
).

# =============================================================================
# PROMPT ENHANCEMENT
# =============================================================================
# Intent detection and prompt augmentation

Decl keyword_pattern(
  keyword: string,
  intent_id: atom
).

Decl system_prompt(
  intent_id: atom,
  prompt_text: string
).

Decl recommended_temp(
  intent_id: atom,
  temperature: float
).

Decl format_instruction(
  intent_id: atom,
  instruction: string
).

# =============================================================================
# POINTERS (Fractal Navigation)
# =============================================================================
# Cross-service navigation and linking

Decl fractal_pointer(
  pointer_id: string,
  target_service: string,
  target_resource: string,
  depth: integer
).

Decl toon_pointer(
  pointer_id: string,
  toon_path: string,
  value_type: atom
).
