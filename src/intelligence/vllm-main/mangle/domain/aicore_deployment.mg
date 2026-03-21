# ===----------------------------------------------------------------------=== #
# AI Core Deployment Rules - Mangle-Driven Configuration for SAP BTP AI Core
# 
# This module derives deployment configurations from existing rules:
#   - model_store_rules.mg (model definitions, hardware profiles)
#   - batching_rules.mg (scaling, batch sizes)
#   - t4_optimization.mg (GPU-specific settings)
#
# Usage:
#   Query `aicore_deployment_config(Model, Config)` to get deployment params
#   Query `aicore_artifact(Model, Artifact)` to get artifact definitions
# ===----------------------------------------------------------------------=== #

# =============================================================================
# Cross-File Dependencies (auto-resolved by MangleLoader)
# =============================================================================
#
# The MangleLoader loads all .mg files in directory order:
#   1. standard/  — base predicates and type rules
#   2. a2a/       — agent-to-agent protocol rules
#   3. toon/      — TOON format and pointer rules
#   4. domain/    — deployment, routing, and optimization rules
#
# Because files are concatenated into a single program before parsing,
# all predicates from earlier directories are available here. This module
# depends on predicates from:
#   - model_store_rules.mg  (model/4, hardware_profile/3)
#   - batching_rules.mg     (scaling_config/3, batch_size/2)
#   - t4_optimization.mg    (t4_gpu_config/3, t4_batch_limit/2)

# =============================================================================
# SAP AI Core Resource Plan Mapping
# =============================================================================

# Map internal hardware profiles to AI Core resource plans
aicore_resource_plan("t4", "gpu_nvidia_t4").
aicore_resource_plan("a10g", "gpu_nvidia_a10g"). 
aicore_resource_plan("a100_40", "gpu_nvidia_a100_40gb").
aicore_resource_plan("a100_80", "gpu_nvidia_a100_80gb").
aicore_resource_plan("v100", "gpu_nvidia_v100").
aicore_resource_plan("cpu_only", "infer.l").
aicore_resource_plan("m1_mac", "infer.l").  # Apple Silicon not available on AI Core

# Resource plan specifications (for validation)
aicore_plan_spec("gpu_nvidia_t4", 16, 4, 100).       # vram_gb, cpu, tok_per_sec
aicore_plan_spec("gpu_nvidia_a10g", 24, 4, 150).
aicore_plan_spec("gpu_nvidia_a100_40gb", 40, 8, 300).
aicore_plan_spec("gpu_nvidia_a100_80gb", 80, 16, 350).
aicore_plan_spec("gpu_nvidia_v100", 32, 8, 120).
aicore_plan_spec("infer.s", 0, 1, 10).
aicore_plan_spec("infer.m", 0, 2, 15).
aicore_plan_spec("infer.l", 0, 4, 25).

# =============================================================================
# AI Core Object Store Configuration
# =============================================================================

# SAP AI Core object store settings
# Bucket ID injected at runtime via AICORE_OBJECT_STORE_BUCKET env var.
# The gateway asserts this as a Mangle fact on startup (see main.zig).
# Fallback for local development only:
aicore_storage("bucket", "local-dev-bucket").
aicore_storage("prefix", "ai://default/").
aicore_storage("models_path", "llm-models/").
aicore_storage("embeddings_path", "embeddings/").

# Derive object store path from model definition
aicore_model_path(RepoId, Format, Path) :-
    aicore_storage("prefix", Prefix),
    aicore_storage("models_path", ModelsPath),
    format_path_segment(Format, FormatSeg),
    repo_to_filename(RepoId, Filename),
    Path = fn:concat(Prefix, ModelsPath, FormatSeg, Filename).

format_path_segment("gguf", "gguf/").
format_path_segment("safetensors", "safetensors/").
format_path_segment(_, "other/").

# Convert repo ID to safe filename
repo_to_filename(RepoId, Filename) :-
    Filename = fn:replace(RepoId, "/", "--").

# =============================================================================
# Model Artifact Derivation
# =============================================================================

# Derive AI Core artifact definition from model_def
aicore_artifact(RepoId, artifact{
    name: ArtifactName,
    kind: "model",
    url: ArtifactUrl,
    scenarioId: "ainuc-llm-inference",
    labels: Labels
}) :-
    model_def(RepoId, Format, SizeGB, Capabilities),
    artifact_name(RepoId, ArtifactName),
    aicore_model_path(RepoId, Format, ArtifactUrl),
    artifact_labels(RepoId, Format, SizeGB, Capabilities, Labels).

# For GGUF variants, create specific artifact per variant
aicore_artifact_variant(RepoId, VariantFile, artifact{
    name: ArtifactName,
    kind: "model",
    url: ArtifactUrl,
    scenarioId: "ainuc-llm-inference",
    labels: Labels
}) :-
    gguf_variant(RepoId, VariantFile, SizeGB),
    artifact_name_variant(VariantFile, ArtifactName),
    aicore_storage("prefix", Prefix),
    aicore_storage("models_path", ModelsPath),
    ArtifactUrl = fn:concat(Prefix, ModelsPath, "gguf/", VariantFile),
    variant_labels(RepoId, VariantFile, SizeGB, Labels).

# Artifact naming conventions
artifact_name(RepoId, Name) :-
    Name = fn:replace(fn:replace(RepoId, "/", "-"), "_", "-").

artifact_name_variant(VariantFile, Name) :-
    BaseName = fn:replace(VariantFile, ".gguf", ""),
    Name = fn:replace(fn:replace(BaseName, ".", "-"), "_", "-").

# Artifact labels
artifact_labels(RepoId, Format, SizeGB, Capabilities, labels{
    "ai.sap.com/model.repo": RepoId,
    "ai.sap.com/model.format": Format,
    "ai.sap.com/model.sizeGB": SizeGB,
    "ai.sap.com/model.capabilities": Capabilities
}).

variant_labels(RepoId, VariantFile, SizeGB, labels{
    "ai.sap.com/model.repo": RepoId,
    "ai.sap.com/model.variant": VariantFile,
    "ai.sap.com/model.sizeGB": SizeGB,
    "ai.sap.com/model.format": "gguf",
    "ai.sap.com/model.quantization": Quant
}) :-
    extract_quantization(VariantFile, Quant).

extract_quantization(File, "Q4_K_M") :- fn:contains(File, "Q4_K_M").
extract_quantization(File, "Q5_K_M") :- fn:contains(File, "Q5_K_M").
extract_quantization(File, "Q8_0") :- fn:contains(File, "Q8_0").
extract_quantization(File, "Q4_0") :- fn:contains(File, "Q4_0").
extract_quantization(File, "FP16") :- fn:contains(File, "FP16").
extract_quantization(_, "unknown").

# =============================================================================
# Scaling Rules (derived from model size and hardware)
# =============================================================================

# Derive scaling parameters from model size
aicore_scaling(RepoId, MinReplicas, MaxReplicas) :-
    model_def(RepoId, _, SizeGB, _),
    scaling_for_size(SizeGB, MinReplicas, MaxReplicas).

# GGUF variant scaling (more aggressive for quantized)
aicore_scaling_variant(RepoId, VariantFile, MinReplicas, MaxReplicas) :-
    gguf_variant(RepoId, VariantFile, SizeGB),
    scaling_for_size(SizeGB, MinReplicas, MaxReplicas).

# Size-based scaling thresholds
scaling_for_size(SizeGB, 1, 8) :- SizeGB < 3.       # Small models (< 3B params)
scaling_for_size(SizeGB, 2, 8) :- SizeGB >= 3, SizeGB < 5.  # Medium-small
scaling_for_size(SizeGB, 2, 4) :- SizeGB >= 5, SizeGB < 10. # Medium (7B)
scaling_for_size(SizeGB, 2, 2) :- SizeGB >= 10, SizeGB < 20. # Large (13B)
scaling_for_size(SizeGB, 1, 1) :- SizeGB >= 20.    # Very large

# =============================================================================
# Context Window Rules (derived from model size and VRAM)
# =============================================================================

# Derive context size from model and hardware
aicore_context(RepoId, HardwareProfile, ContextSize) :-
    model_def(RepoId, _, SizeGB, _),
    hw_profile(HardwareProfile, VRAM, _, _),
    context_for_config(SizeGB, VRAM, ContextSize).

# GGUF variant context (can use larger context due to quantization)
aicore_context_variant(RepoId, VariantFile, HardwareProfile, ContextSize) :-
    gguf_variant(RepoId, VariantFile, SizeGB),
    hw_profile(HardwareProfile, VRAM, _, _),
    context_for_gguf(SizeGB, VRAM, VariantFile, ContextSize).

# Context calculation based on model size and available VRAM
context_for_config(SizeGB, VRAM, 8192) :- SizeGB < 3, VRAM >= 16.
context_for_config(SizeGB, VRAM, 4096) :- SizeGB >= 3, SizeGB < 8, VRAM >= 16.
context_for_config(SizeGB, VRAM, 2048) :- SizeGB >= 8, VRAM >= 16.
context_for_config(_, VRAM, 2048) :- VRAM < 16, VRAM >= 8.
context_for_config(_, VRAM, 1024) :- VRAM < 8.

# GGUF-specific context (quantization allows larger context)
context_for_gguf(SizeGB, VRAM, File, 8192) :- 
    SizeGB < 5, VRAM >= 16, fn:contains(File, "Q4").
context_for_gguf(SizeGB, VRAM, File, 4096) :- 
    SizeGB >= 5, SizeGB < 8, VRAM >= 16, fn:contains(File, "Q4").
context_for_gguf(SizeGB, VRAM, File, 4096) :- 
    SizeGB < 5, VRAM >= 16, fn:contains(File, "Q8").
context_for_gguf(SizeGB, VRAM, _, 2048) :- SizeGB >= 8, VRAM >= 16.
context_for_gguf(_, _, _, 2048).  # Default fallback

# =============================================================================
# Parallel Request Rules (derived from hardware and model)
# =============================================================================

aicore_parallel(RepoId, HardwareProfile, ParallelRequests) :-
    model_def(RepoId, _, SizeGB, _),
    hw_profile(HardwareProfile, VRAM, _, MaxBatch),
    parallel_for_config(SizeGB, VRAM, MaxBatch, ParallelRequests).

parallel_for_config(SizeGB, VRAM, MaxBatch, Parallel) :-
    AvailVRAM = VRAM - SizeGB * 1.2,  # Model + 20% overhead
    Parallel = fn:min(MaxBatch, fn:max(1, fn:floor(AvailVRAM / 0.5))).

# =============================================================================
# Complete Deployment Configuration Query
# =============================================================================

# Query to get full deployment config for a model
aicore_deployment_config(RepoId, HardwareProfile, config{
    scenario: "ainuc-llm-inference",
    executable: "llm-server",
    model: RepoId,
    resourcePlan: ResourcePlan,
    artifact: Artifact,
    minReplicas: MinReplicas,
    maxReplicas: MaxReplicas,
    contextSize: ContextSize,
    parallelRequests: ParallelRequests,
    parameters: parameters{
        "dockerImage": DockerImage,
        "modelFile": ModelFile,
        "mangleEnabled": "true"
    }
}) :-
    # Get resource plan from hardware mapping
    aicore_resource_plan(HardwareProfile, ResourcePlan),
    # Get artifact definition
    aicore_artifact(RepoId, Artifact),
    # Get scaling parameters
    aicore_scaling(RepoId, MinReplicas, MaxReplicas),
    # Get context size
    aicore_context(RepoId, HardwareProfile, ContextSize),
    # Get parallel requests
    aicore_parallel(RepoId, HardwareProfile, ParallelRequests),
    # Derive other parameters
    docker_image_for_plan(ResourcePlan, DockerImage),
    model_file_from_repo(RepoId, ModelFile).

# GGUF variant deployment config (preferred for inference)
aicore_deployment_config_gguf(RepoId, VariantFile, HardwareProfile, config{
    scenario: "ainuc-llm-inference",
    executable: "llm-server",
    model: RepoId,
    variant: VariantFile,
    resourcePlan: ResourcePlan,
    artifact: Artifact,
    minReplicas: MinReplicas,
    maxReplicas: MaxReplicas,
    contextSize: ContextSize,
    parallelRequests: ParallelRequests,
    parameters: parameters{
        "dockerImage": DockerImage,
        "modelFile": VariantFile,
        "mangleEnabled": "true"
    }
}) :-
    aicore_resource_plan(HardwareProfile, ResourcePlan),
    aicore_artifact_variant(RepoId, VariantFile, Artifact),
    aicore_scaling_variant(RepoId, VariantFile, MinReplicas, MaxReplicas),
    aicore_context_variant(RepoId, VariantFile, HardwareProfile, ContextSize),
    gguf_variant(RepoId, VariantFile, SizeGB),
    hw_profile(HardwareProfile, VRAM, _, MaxBatch),
    parallel_for_config(SizeGB, VRAM, MaxBatch, ParallelRequests),
    docker_image_for_plan(ResourcePlan, DockerImage).

# Docker image selection based on resource plan
docker_image_for_plan(Plan, "ainuc-llm-server:cuda-latest") :-
    fn:starts_with(Plan, "gpu_").
docker_image_for_plan(Plan, "ainuc-llm-server:cpu-latest") :-
    fn:starts_with(Plan, "infer.").
docker_image_for_plan(_, "ainuc-llm-server:latest").

# Model file derivation
model_file_from_repo(RepoId, File) :-
    model_def(RepoId, "gguf", _, _),
    gguf_variant(RepoId, File, _).
model_file_from_repo(RepoId, "model.safetensors") :-
    model_def(RepoId, "safetensors", _, _).

# =============================================================================
# Deployment Recommendations
# =============================================================================

# Recommend best deployment config for a task
recommend_deployment(Task, HardwareProfile, Config) :-
    route_request(Task, RepoId),
    model_def(RepoId, "gguf", _, _),
    gguf_variant(RepoId, VariantFile, _),
    best_variant_for_hardware(RepoId, HardwareProfile, VariantFile),
    aicore_deployment_config_gguf(RepoId, VariantFile, HardwareProfile, Config).

recommend_deployment(Task, HardwareProfile, Config) :-
    route_request(Task, RepoId),
    model_def(RepoId, Format, _, _),
    Format \= "gguf",
    aicore_deployment_config(RepoId, HardwareProfile, Config).

# Select best variant for hardware
best_variant_for_hardware(RepoId, HardwareProfile, VariantFile) :-
    hw_profile(HardwareProfile, VRAM, _, _),
    findall(V-S, (gguf_variant(RepoId, V, S), S < VRAM * 0.9), Variants),
    sort(2, @>=, Variants, Sorted),  # Sort by size descending
    Sorted = [VariantFile-_|_].      # Pick largest that fits

# =============================================================================
# Validation Rules
# =============================================================================

# Validate deployment config
valid_deployment(Config) :-
    Config = config{resourcePlan: Plan, minReplicas: Min, maxReplicas: Max, _},
    aicore_plan_spec(Plan, _, _, _),
    Min >= 1,
    Max >= Min,
    Max =< 16.

# Check if model fits in resource plan
model_fits_plan(RepoId, Plan) :-
    model_def(RepoId, _, SizeGB, _),
    aicore_plan_spec(Plan, VRAM, _, _),
    SizeGB * 1.2 < VRAM.

model_fits_plan_gguf(RepoId, VariantFile, Plan) :-
    gguf_variant(RepoId, VariantFile, SizeGB),
    aicore_plan_spec(Plan, VRAM, _, _),
    SizeGB * 1.1 < VRAM.  # GGUF needs less overhead

# =============================================================================
# List All Deployable Models for Hardware
# =============================================================================

deployable_models(HardwareProfile, Models) :-
    aicore_resource_plan(HardwareProfile, Plan),
    findall(
        model{repo: R, variant: V, size: S},
        (gguf_variant(R, V, S), model_fits_plan_gguf(R, V, Plan)),
        Models
    ).

# =============================================================================
# Tests
# =============================================================================

test_aicore_t4() :-
    aicore_deployment_config_gguf(
        "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
        "mistral-7b-instruct-v0.2.Q4_K_M.gguf",
        "t4",
        Config
    ),
    Config.resourcePlan = "gpu_nvidia_t4",
    Config.minReplicas >= 1,
    Config.maxReplicas =< 8.

test_scaling() :-
    scaling_for_size(2.7, 1, 8),   # Phi-2 should scale to 8
    scaling_for_size(7.0, 2, 4),   # 7B should scale to 4
    scaling_for_size(13.0, 2, 2).  # 13B limited to 2

test_context() :-
    context_for_config(2.7, 16, 8192),  # Small model, full context
    context_for_config(7.0, 16, 4096),  # Medium model
    context_for_config(13.0, 16, 2048). # Large model