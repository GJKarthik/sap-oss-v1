% HuggingFace Hub Connector — API schema for model discovery and download
% Used by model_hub.zig to resolve dynamic model lookups via HF API
%
% API Base: https://huggingface.co/api
% Models endpoint: GET /api/models?search={query}&filter={filter}&sort=downloads&direction=-1
% Model info: GET /api/models/{repo_id}
% Download: GET /{repo_id}/resolve/{revision}/{filename}

% === HF API Configuration ===
% hf_api_config(base_url, api_version, default_revision)
hf_api_config("https://huggingface.co", "v1", "main").

% Token source: environment variable
% hf_token_env(env_var_name)
hf_token_env("HF_TOKEN").
hf_token_env("HUGGING_FACE_HUB_TOKEN").

% === Download Configuration ===
% hf_download_config(max_retries, timeout_seconds, chunk_size_bytes)
hf_download_config(3, 3600, 10485760).

% === GGUF File Patterns ===
% hf_gguf_pattern(quant_level, filename_suffix)
hf_gguf_pattern("q4_0", "Q4_0.gguf").
hf_gguf_pattern("q4_k_m", "Q4_K_M.gguf").
hf_gguf_pattern("q5_k_m", "Q5_K_M.gguf").
hf_gguf_pattern("q6_k", "Q6_K.gguf").
hf_gguf_pattern("q8_0", "Q8_0.gguf").
hf_gguf_pattern("f16", "f16.gguf").
hf_gguf_pattern("f32", "f32.gguf").

% === Model Search Result Ranking ===
% hf_sort_preference(sort_field, direction)
hf_sort_preference("downloads", "desc").
hf_sort_preference("lastModified", "desc").
hf_sort_preference("likes", "desc").

% === Object Store Persistence ===
% hf_cache_config(provider, bucket_env, prefix)
hf_cache_config("sap_object_store", "MODEL_CACHE_BUCKET", "models/gguf").
hf_cache_config("local", "MODEL_CACHE_DIR", "~/.cache/privatellm/models").

% === Rate Limiting for HF API ===
% hf_rate_limit(requests_per_minute, burst_size)
hf_rate_limit(30, 5).

% === Model Validation ===
% hf_validate_rule(check_name, required)
hf_validate_rule("sha256_checksum", "true").
hf_validate_rule("file_size_match", "true").
hf_validate_rule("gguf_magic_bytes", "true").
