# ============================================================================
# UI5 Web Components Angular - Data Product Rules (ODPS 4.1)
# ============================================================================

# =============================================================================
# DATA PRODUCT DEFINITIONS
# =============================================================================

data_product("ui5-angular-service-v1", "public", "aicore-default").
data_product_owner("ui5-angular-service-v1", "UI Framework Team").
data_product_version("ui5-angular-service-v1", "1.0.0").

# =============================================================================
# OUTPUT PORTS - All public, AI Core OK
# =============================================================================

output_port("ui5-angular-service-v1", "component-generator", "public", "aicore-ok").
output_port("ui5-angular-service-v1", "code-completion", "public", "aicore-ok").
output_port("ui5-angular-service-v1", "documentation", "public", "aicore-ok").

# =============================================================================
# INPUT PORTS
# =============================================================================

input_port("ui5-angular-service-v1", "component-specs", "public", true).
input_port("ui5-angular-service-v1", "angular-templates", "public", true).

# =============================================================================
# ROUTING RULES - Default AI Core OK
# =============================================================================

data_product_route(Request, "aicore-ok") :-
    request_uses_product(Request, "ui5-angular-service-v1"),
    not contains_user_data(Request).

data_product_route(Request, "vllm-only") :-
    request_uses_product(Request, "ui5-angular-service-v1"),
    contains_user_data(Request).

# =============================================================================
# PROMPTING POLICY
# =============================================================================

prompting_policy("ui5-angular-service-v1", "max_tokens", 4096).
prompting_policy("ui5-angular-service-v1", "temperature", 0.5).
prompting_policy("ui5-angular-service-v1", "response_format", "code").

system_prompt("ui5-angular-service-v1", 
    "You are a UI5 Web Components expert for Angular development. " ++
    "Help developers create Angular components using UI5 Web Components. " ++
    "Provide TypeScript code examples and best practices. " ++
    "Follow Angular style guide and UI5 documentation standards.").

# =============================================================================
# REGULATORY COMPLIANCE
# =============================================================================

regulatory_framework("ui5-angular-service-v1", "MGF-Agentic-AI").

product_autonomy_level("ui5-angular-service-v1", "L3").
product_requires_human_oversight("ui5-angular-service-v1", false).

product_safety_control("ui5-angular-service-v1", "guardrails").
product_safety_control("ui5-angular-service-v1", "monitoring").

# =============================================================================
# QUALITY METRICS
# =============================================================================

quality_metric("ui5-angular-service-v1", "availability", "99.9%").
quality_metric("ui5-angular-service-v1", "latency_p95", "2000ms").
quality_metric("ui5-angular-service-v1", "throughput", "200 req/min").