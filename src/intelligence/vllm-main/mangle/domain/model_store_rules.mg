# ===----------------------------------------------------------------------=== #
# Model Store Rules - Mangle Configuration for HuggingFace/S3 Model Management
# Defines rules for model selection, storage, and routing
# ===----------------------------------------------------------------------=== #

# =============================================================================
# Model Definitions
# =============================================================================

# Model metadata: model_def(repo_id, format, size_gb, capabilities...)
model_def("microsoft/phi-2", "safetensors", 2.7, ["text-generation", "reasoning"]).
model_def("google/gemma-2b", "safetensors", 5.0, ["text-generation", "multilingual"]).
model_def("meta-llama/Llama-2-7b-chat-hf", "safetensors", 13.5, ["text-generation", "chat"]).
model_def("TheBloke/Llama-2-7B-GGUF", "gguf", 4.0, ["text-generation", "chat", "quantized"]).
model_def("TheBloke/Mistral-7B-Instruct-v0.2-GGUF", "gguf", 4.0, ["text-generation", "instruct", "quantized"]).
model_def("BAAI/bge-large-en-v1.5", "safetensors", 1.3, ["embedding", "retrieval"]).
model_def("sentence-transformers/all-MiniLM-L6-v2", "safetensors", 0.09, ["embedding", "semantic-search"]).
model_def("intfloat/e5-large-v2", "safetensors", 1.3, ["embedding", "retrieval", "multilingual"]).

# Quantization variants
gguf_variant("TheBloke/Llama-2-7B-GGUF", "llama-2-7b.Q4_K_M.gguf", 4.08).
gguf_variant("TheBloke/Llama-2-7B-GGUF", "llama-2-7b.Q5_K_M.gguf", 4.78).
gguf_variant("TheBloke/Llama-2-7B-GGUF", "llama-2-7b.Q8_0.gguf", 7.16).
gguf_variant("TheBloke/Mistral-7B-Instruct-v0.2-GGUF", "mistral-7b-instruct-v0.2.Q4_K_M.gguf", 4.37).
gguf_variant("TheBloke/Mistral-7B-Instruct-v0.2-GGUF", "mistral-7b-instruct-v0.2.Q5_K_M.gguf", 5.13).

# =============================================================================
# Storage Configuration
# =============================================================================

# S3 bucket configuration
storage_config("bucket", "hcp-055af4b0-2344-40d2-88fe-ddc1c4aad6c5").
storage_config("region", "us-east-1").
storage_config("prefix", "models/").
storage_config("max_model_size_gb", 50).

# Model storage path derivation
model_s3_path(RepoId, Revision, Path) :-
    storage_config("prefix", Prefix),
    Path = format("{}{}}/{}/", Prefix, RepoId, Revision).

# =============================================================================
# Hardware Profiles
# =============================================================================

# Hardware profile: hw_profile(name, vram_gb, compute_capability, max_batch_size)
hw_profile("t4", 16, 7.5, 32).
hw_profile("a10g", 24, 8.6, 64).
hw_profile("a100", 40, 8.0, 128).
hw_profile("cpu_only", 0, 0, 8).
hw_profile("m1_mac", 16, 0, 16).  # Apple Silicon unified memory

# Current hardware detection (would be set at runtime)
current_hardware("t4").

# =============================================================================
# Model Selection Rules
# =============================================================================

# Select model for task based on hardware constraints
select_model(Task, RepoId, Variant) :-
    current_hardware(HW),
    hw_profile(HW, VRAM, _, _),
    model_def(RepoId, Format, SizeGB, Capabilities),
    member(Task, Capabilities),
    fits_in_memory(SizeGB, VRAM, Format),
    select_variant(RepoId, Format, VRAM, Variant).

# Memory fit calculation
fits_in_memory(SizeGB, VRAM, "gguf") :-
    SizeGB * 1.1 < VRAM.  # GGUF with 10% overhead
fits_in_memory(SizeGB, VRAM, "safetensors") :-
    SizeGB * 1.5 < VRAM.  # Full precision needs more memory
fits_in_memory(_, VRAM, _) :-
    VRAM == 0.  # CPU-only mode accepts any size

# Variant selection
select_variant(RepoId, "gguf", VRAM, Variant) :-
    VRAM >= 8,
    gguf_variant(RepoId, Variant, Size),
    Size < VRAM * 0.9.
select_variant(RepoId, "safetensors", _, "main") :-
    model_def(RepoId, "safetensors", _, _).
select_variant(RepoId, "gguf", VRAM, Variant) :-
    VRAM < 8,
    gguf_variant(RepoId, Variant, Size),
    contains(Variant, "Q4").  # Prefer Q4 for low VRAM

# =============================================================================
# Embedding Model Selection
# =============================================================================

# Select embedding model based on use case
embedding_model("semantic-search", "sentence-transformers/all-MiniLM-L6-v2") :-
    current_hardware(HW),
    hw_profile(HW, VRAM, _, _),
    VRAM < 4.  # Small model for limited VRAM

embedding_model("semantic-search", "BAAI/bge-large-en-v1.5") :-
    current_hardware(HW),
    hw_profile(HW, VRAM, _, _),
    VRAM >= 4.  # Better model when VRAM available

embedding_model("retrieval", "intfloat/e5-large-v2").
embedding_model("multilingual", "intfloat/e5-large-v2").

# =============================================================================
# Model Download Priority
# =============================================================================

# Priority order for model downloads
download_priority(1, "sentence-transformers/all-MiniLM-L6-v2").  # Essential embedding
download_priority(2, "BAAI/bge-large-en-v1.5").                   # Better embedding
download_priority(3, "TheBloke/Mistral-7B-Instruct-v0.2-GGUF").  # Main LLM
download_priority(4, "TheBloke/Llama-2-7B-GGUF").                 # Fallback LLM
download_priority(5, "microsoft/phi-2").                          # Small LLM

# Get models to download based on available storage
models_to_download(Models) :-
    storage_config("max_model_size_gb", MaxSize),
    findall(M, (download_priority(_, M), model_def(M, _, Size, _), Size < MaxSize), Models).

# =============================================================================
# Model Routing Rules
# =============================================================================

# Route request to appropriate model
route_request("chat", Model) :-
    select_model("chat", Model, _).
route_request("completion", Model) :-
    select_model("text-generation", Model, _).
route_request("embedding", Model) :-
    embedding_model("semantic-search", Model).
route_request("reasoning", Model) :-
    select_model("reasoning", Model, _).

# Fallback routing
route_request(_, "TheBloke/Mistral-7B-Instruct-v0.2-GGUF") :-
    current_hardware(HW),
    hw_profile(HW, VRAM, _, _),
    VRAM >= 8.
route_request(_, "microsoft/phi-2") :-
    current_hardware(HW),
    hw_profile(HW, VRAM, _, _),
    VRAM < 8.

# =============================================================================
# S3 Model Registry
# =============================================================================

# Track models that are synced to S3
# model_synced(repo_id, revision, s3_path, sync_time)
# This would be populated at runtime

model_needs_sync(RepoId) :-
    download_priority(_, RepoId),
    \+ model_synced(RepoId, _, _, _).

# =============================================================================
# Batch Configuration
# =============================================================================

# Batch size based on model and hardware
batch_size(RepoId, BatchSize) :-
    current_hardware(HW),
    hw_profile(HW, VRAM, _, MaxBatch),
    model_def(RepoId, _, SizeGB, _),
    AvailVRAM = VRAM - SizeGB,
    BatchSize = min(MaxBatch, floor(AvailVRAM / 0.5)).  # 0.5GB per batch item estimate

# =============================================================================
# Health Check Rules
# =============================================================================

model_healthy(RepoId) :-
    model_synced(RepoId, _, _, _),
    model_loaded(RepoId).

system_ready() :-
    route_request("embedding", EmbedModel),
    model_healthy(EmbedModel),
    route_request("chat", ChatModel),
    model_healthy(ChatModel).