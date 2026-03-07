# ============================================================================
# mcppal-mesh-gateway — Mangle Rules for MCP PAL Routing
# ============================================================================
#
# HTTP :9881  →  MCP JSON-RPC  →  Mangle Router  →  PAL Tools  →  HANA SQL
#
# Data source: sap-pal-webcomponents-sql (spec/, sql/, mangle/, facts/)
# No LLM backend — pure rule-based routing and SQL generation.

# ============================================================================
# Service Identity
# ============================================================================

service_id("mcppal-mesh-gateway").
service_version("1.0.0").
service_port(9881).

# MCP endpoints
endpoint("/mcp",    "POST", "MCP JSON-RPC protocol endpoint").
endpoint("/sse",    "GET",  "MCP Server-Sent Events transport").
endpoint("/health", "GET",  "Health check").

# ============================================================================
# MCP Tool Definitions
# ============================================================================

mcp_tool("pal-catalog", "List or search 162 SAP HANA PAL algorithms across 13 categories").
mcp_tool("pal-execute", "Generate HANA SQL CALL script for a PAL algorithm").
mcp_tool("pal-spec",    "Read ODPS YAML specification for a PAL algorithm").
mcp_tool("pal-sql",     "Retrieve SQL template for a PAL algorithm").

# ============================================================================
# Intent Detection Patterns
# ============================================================================
# intent_pattern(Intent, Pattern)
# The engine lowercases the user message and matches patterns.

# Catalog listing
intent_pattern(/pal_catalog, "list algorithm").
intent_pattern(/pal_catalog, "available algorithm").
intent_pattern(/pal_catalog, "pal catalog").
intent_pattern(/pal_catalog, "which pal").
intent_pattern(/pal_catalog, "what algorithm").
intent_pattern(/pal_catalog, "list categories").
intent_pattern(/pal_catalog, "show categories").
intent_pattern(/pal_catalog, "how many algorithm").

# Algorithm execution / SQL generation
intent_pattern(/pal_execute, "run pal").
intent_pattern(/pal_execute, "execute pal").
intent_pattern(/pal_execute, "call _sys_afl").
intent_pattern(/pal_execute, "generate sql").
intent_pattern(/pal_execute, "pal execute").
intent_pattern(/pal_execute, "create sql").
intent_pattern(/pal_execute, "hana call").

# Spec reading
intent_pattern(/pal_spec, "spec for").
intent_pattern(/pal_spec, "specification").
intent_pattern(/pal_spec, "odps spec").
intent_pattern(/pal_spec, "yaml spec").
intent_pattern(/pal_spec, "algorithm detail").
intent_pattern(/pal_spec, "parameters for").
intent_pattern(/pal_spec, "show spec").

# SQL template retrieval
intent_pattern(/pal_sql, "sql template").
intent_pattern(/pal_sql, "sql for").
intent_pattern(/pal_sql, "sqlscript").
intent_pattern(/pal_sql, "show sql").
intent_pattern(/pal_sql, "get sql").

# Search
intent_pattern(/pal_search, "search").
intent_pattern(/pal_search, "find algorithm").
intent_pattern(/pal_search, "lookup").

# ============================================================================
# Tool → Intent Mapping
# ============================================================================

tool_for_intent(/pal_catalog, "pal-catalog").
tool_for_intent(/pal_execute, "pal-execute").
tool_for_intent(/pal_spec,    "pal-spec").
tool_for_intent(/pal_sql,     "pal-sql").
tool_for_intent(/pal_search,  "pal-catalog").

# ============================================================================
# PAL Task → Default Algorithm Mapping
# ============================================================================

pal_for_task(/profiling,              "_SYS_AFL.PAL_UNIVARIATE_ANALYSIS").
pal_for_task(/outlier_detection,      "_SYS_AFL.PAL_ISOLATION_FOREST").
pal_for_task(/fraud_detection,        "_SYS_AFL.PAL_BENFORD").
pal_for_task(/clustering,             "_SYS_AFL.PAL_KMEANS").
pal_for_task(/anomaly_detection,      "_SYS_AFL.PAL_ISOLATION_FOREST").
pal_for_task(/missing_values,         "_SYS_AFL.PAL_MISSING_VALUE_HANDLING").
pal_for_task(/classification,         "_SYS_AFL.PAL_HGBT").
pal_for_task(/regression,             "_SYS_AFL.PAL_LINEAR_REGRESSION").
pal_for_task(/dimensionality_reduction, "_SYS_AFL.PAL_PCA").
pal_for_task(/scaling,                "_SYS_AFL.PAL_SCALE").
pal_for_task(/time_series,            "_SYS_AFL.PAL_ARIMA").
pal_for_task(/text_analysis,          "_SYS_AFL.PAL_SENTIMENT_ANALYSIS").
pal_for_task(/embedding,              "_SYS_AFL.PAL_TEXT_EMBEDDING").
pal_for_task(/fair_ml,                "_SYS_AFL.PAL_FAIR_ML").
pal_for_task(/recommendation,         "_SYS_AFL.PAL_ALS").
pal_for_task(/automl,                 "_SYS_AFL.PAL_AUTOML").

# ============================================================================
# Rules
# ============================================================================

# Resolve tool from user message
resolve_tool(Message, Tool) :-
    intent_pattern(Intent, Pattern),
    :fn:contains(Message, Pattern),
    tool_for_intent(Intent, Tool).

# Get default algorithm for a task
default_algorithm(Task, Procedure) :-
    pal_for_task(Task, Procedure).

# ============================================================================
# Bidirectional API Communication Flows
# ============================================================================
# api_request(Method, URL, Body)
#
# When a "profile" intent is detected, request data profiling from search-svc
# and then use the result to recommend a PAL algorithm.

api_request("POST", "http://search-svc:8080/v1/chat/completions", "{\"model\":\"es-search-v1\",\"messages\":[{\"role\":\"user\",\"content\":\"profile table SALES_DATA\"}]}") :-
    detected_intent(/pal_execute),
    table_name("SALES_DATA").

# Forward reasoning: if search-svc returns a profile, create an optimization hint
optimization_hint(Table, "Use Isolation Forest for outliers") :-
    api_response("http://search-svc:8080/v1/chat/completions", Response),
    :fn:contains(Response, "skewed distribution").

# ============================================================================
# Dynamic Kernel Hot-Reloading
# ============================================================================
#
# Selects the optimal Mojo kernel version based on real-time GPU telemetry.
# The Zig runtime injects gpu_telemetry/3 facts every N seconds.
#
# Fact format (injected by GpuTelemetryPoller):
#   gpu_telemetry("sm_version", 75).        % SM 7.5 = Turing (T4)
#   gpu_telemetry("memory_util_pct", 72).   % 0-100
#   gpu_telemetry("temperature_c", 68).      % Celsius
#   gpu_telemetry("power_draw_w", 55).       % Watts (T4 TDP = 70W)
#   gpu_telemetry("compute_util_pct", 85).   % 0-100

# Kernel variant catalog — each variant targets specific hardware profiles
kernel_variant("embedding",  "simd_f32",    "CPU-only SIMD, any arch").
kernel_variant("embedding",  "tensor_fp16", "T4+ Tensor Core FP16 GEMM").
kernel_variant("embedding",  "tensor_int8", "T4+ INT8 quantized, 2x throughput").
kernel_variant("similarity", "simd_f32",    "CPU SIMD cosine/dot").
kernel_variant("similarity", "tensor_fp16", "GPU FP16 batch similarity").
kernel_variant("similarity", "tensor_int8", "GPU INT8 batch similarity").
kernel_variant("attention",  "standard",    "O(N^2) attention").
kernel_variant("attention",  "flash_v2",    "Flash Attention v2, O(N) memory").

# Thermal throttling threshold — back off to lighter kernels
gpu_thermal_throttle :-
    gpu_telemetry("temperature_c", Temp),
    Temp > 78.

# Power headroom — can run heavy kernels
gpu_power_headroom :-
    gpu_telemetry("power_draw_w", Power),
    Power < 60.

# Memory pressure — switch to quantized kernels
gpu_memory_pressure :-
    gpu_telemetry("memory_util_pct", MemUtil),
    MemUtil > 85.

# Has Tensor Cores (SM >= 7.0)
gpu_has_tensor_cores :-
    gpu_telemetry("sm_version", SM),
    SM >= 70.

# Has INT8 Tensor Cores (SM >= 7.5, Turing+)
gpu_has_int8_tensor :-
    gpu_telemetry("sm_version", SM),
    SM >= 75.

# ---- Kernel selection rules (highest-priority match wins) ----

# Under thermal throttle: always use lightweight SIMD
select_kernel(Op, "simd_f32") :-
    kernel_variant(Op, "simd_f32", _),
    gpu_thermal_throttle.

# Memory pressure + INT8 available: use quantized kernels
select_kernel(Op, "tensor_int8") :-
    kernel_variant(Op, "tensor_int8", _),
    gpu_memory_pressure,
    gpu_has_int8_tensor,
    not gpu_thermal_throttle.

# Power headroom + Tensor Cores: use FP16
select_kernel(Op, "tensor_fp16") :-
    kernel_variant(Op, "tensor_fp16", _),
    gpu_has_tensor_cores,
    gpu_power_headroom,
    not gpu_memory_pressure,
    not gpu_thermal_throttle.

# INT8 preferred when available and no thermal issues
select_kernel(Op, "tensor_int8") :-
    kernel_variant(Op, "tensor_int8", _),
    gpu_has_int8_tensor,
    not gpu_thermal_throttle.

# Tensor Core FP16 fallback
select_kernel(Op, "tensor_fp16") :-
    kernel_variant(Op, "tensor_fp16", _),
    gpu_has_tensor_cores,
    not gpu_thermal_throttle.

# CPU SIMD fallback (always available)
select_kernel(Op, "simd_f32") :-
    kernel_variant(Op, "simd_f32", _),
    not gpu_has_tensor_cores.

# Flash Attention: use when Tensor Cores available and not throttled
select_kernel("attention", "flash_v2") :-
    kernel_variant("attention", "flash_v2", _),
    gpu_has_tensor_cores,
    not gpu_thermal_throttle.

# Standard attention fallback
select_kernel("attention", "standard") :-
    kernel_variant("attention", "standard", _),
    not gpu_has_tensor_cores.
select_kernel("attention", "standard") :-
    kernel_variant("attention", "standard", _),
    gpu_thermal_throttle.

# ============================================================================
# Tests
# ============================================================================

test_service_identity() :-
    service_id("mcppal-mesh-gateway").

test_mcp_tool_exists() :-
    mcp_tool("pal-catalog", _).

test_intent_catalog() :-
    intent_pattern(/pal_catalog, "list algorithm").

test_pal_task_mapping() :-
    pal_for_task(/clustering, "_SYS_AFL.PAL_KMEANS").
