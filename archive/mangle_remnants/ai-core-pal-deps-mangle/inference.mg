# Inference Pipeline Specification
# Declarative definition of the inference pipeline and sampling

# ============================================================================
# Inference stages: stage(name, order, description)
# ============================================================================

stage("tokenize", 1, "Convert input text to token IDs").
stage("embed", 2, "Look up token embeddings").
stage("forward", 3, "Run transformer forward pass").
stage("sample", 4, "Sample next token from logits").
stage("decode", 5, "Convert token ID to text").

# ============================================================================
# KV Cache configuration
# ============================================================================

# kv_cache_config(arch, max_seq_len, max_batch_size, dtype)
kv_cache_config("llama", 4096, 1, "F16").
kv_cache_config("phi2", 2048, 1, "F16").
kv_cache_config("phi3", 8192, 1, "F16").
kv_cache_config("gemma", 8192, 1, "F16").

# KV cache memory per layer (in bytes)
kv_cache_memory_per_layer(Arch, Name, Bytes) :-
    model_config(Arch, Name, _, _, NKVHeads, Dim, _, _, MaxSeq),
    kv_cache_config(Arch, MaxSeq, _, DType),
    dtype(DType, _, BytesPerElem, _),
    HeadDim = fn:div(Dim, NKVHeads),
    # K + V, both [seq_len, n_kv_heads, head_dim]
    Bytes = fn:mul(fn:mul(fn:mul(MaxSeq, NKVHeads), HeadDim), fn:mul(2, BytesPerElem)).

# ============================================================================
# Sampling methods
# ============================================================================

# sampler(name, description)
sampler("greedy", "Select token with highest probability").
sampler("temperature", "Scale logits by temperature before softmax").
sampler("top_k", "Keep only top K tokens before sampling").
sampler("top_p", "Keep tokens until cumulative probability > P (nucleus)").
sampler("min_p", "Keep tokens with probability > min_p * max_prob").
sampler("repetition_penalty", "Penalize previously generated tokens").
sampler("presence_penalty", "Flat penalty for tokens in context").
sampler("frequency_penalty", "Penalty proportional to token frequency").

# sampler_param(sampler, param, type, default, description)
sampler_param("temperature", "temp", "f32", 1.0, "Temperature value").
sampler_param("top_k", "k", "u32", 40, "Number of top tokens to keep").
sampler_param("top_p", "p", "f32", 0.9, "Cumulative probability threshold").
sampler_param("min_p", "min_p", "f32", 0.05, "Minimum probability ratio").
sampler_param("repetition_penalty", "penalty", "f32", 1.1, "Repetition penalty factor").
sampler_param("presence_penalty", "penalty", "f32", 0.0, "Presence penalty value").
sampler_param("frequency_penalty", "penalty", "f32", 0.0, "Frequency penalty value").

# Sampler order (default chain)
sampler_chain("default", ["repetition_penalty", "temperature", "top_k", "top_p"]).
sampler_chain("strict", ["repetition_penalty", "min_p", "temperature"]).
sampler_chain("creative", ["temperature", "top_p"]).

# ============================================================================
# Batch inference
# ============================================================================

# batch_config(name, max_batch_size, max_seq_len, continuous_batching)
batch_config("single", 1, 4096, false).
batch_config("small", 4, 2048, true).
batch_config("medium", 8, 2048, true).
batch_config("large", 32, 1024, true).

# ============================================================================
# Memory layout
# ============================================================================

# memory_region(name, purpose, allocation)
memory_region("weights", "Model weights (read-only)", "mmap").
memory_region("kv_cache", "Key-value cache", "heap").
memory_region("scratch", "Temporary computation buffers", "arena").
memory_region("output", "Output logits/tokens", "heap").

# scratch_buffer(operation, size_formula)
scratch_buffer("attention", "batch_size * n_heads * seq_len * seq_len * sizeof(f32)").
scratch_buffer("ffn", "batch_size * ff_dim * sizeof(f32)").
scratch_buffer("norm", "batch_size * dim * sizeof(f32)").

# ============================================================================
# Prompt processing modes
# ============================================================================

# prompt_mode(name, description)
prompt_mode("single", "Process entire prompt at once").
prompt_mode("chunked", "Process prompt in chunks for memory efficiency").
prompt_mode("streaming", "Process prompt token by token").

# chunk_config(mode, chunk_size)
chunk_config("chunked", 512).
chunk_config("streaming", 1).

# ============================================================================
# Generation modes
# ============================================================================

# gen_mode(name, description)
gen_mode("complete", "Generate until EOS or max_tokens").
gen_mode("fill_in_middle", "Fill in between prefix and suffix").
gen_mode("instruct", "Follow instruction format").
gen_mode("chat", "Multi-turn conversation").

# Stop conditions
stop_condition("eos_token", "Stop at end-of-sequence token").
stop_condition("max_tokens", "Stop at maximum token count").
stop_condition("stop_sequence", "Stop at specific text sequence").

# ============================================================================
# Performance optimizations
# ============================================================================

# optimization(name, applicable_to, description)
optimization("flash_attention", "attention", "Memory-efficient attention computation").
optimization("kv_cache_quantization", "kv_cache", "Quantize KV cache to reduce memory").
optimization("speculative_decoding", "generation", "Use draft model for faster generation").
optimization("continuous_batching", "batch", "Dynamic batch management").
optimization("paged_attention", "attention", "Virtual memory for KV cache").

# optimization_config(optimization, param, value)
optimization_config("flash_attention", "block_size", 128).
optimization_config("kv_cache_quantization", "dtype", "Q8_0").
optimization_config("speculative_decoding", "draft_tokens", 4).
optimization_config("paged_attention", "page_size", 16).

# ============================================================================
# Tokenizer configuration
# ============================================================================

# tokenizer_type(name, description)
tokenizer_type("bpe", "Byte Pair Encoding").
tokenizer_type("sentencepiece", "SentencePiece model").
tokenizer_type("tiktoken", "OpenAI tiktoken").

# special_tokens(arch, bos, eos, pad, unk)
special_tokens("llama", 1, 2, 0, 0).
special_tokens("phi2", 50256, 50256, 50256, 50256).
special_tokens("gemma", 2, 1, 0, 3).

# chat_template(arch, template)
chat_template("llama", "<s>[INST] {user} [/INST] {assistant}").
chat_template("phi2", "User: {user}\nAssistant: {assistant}").
chat_template("gemma", "<start_of_turn>user\n{user}<end_of_turn>\n<start_of_turn>model\n{assistant}").