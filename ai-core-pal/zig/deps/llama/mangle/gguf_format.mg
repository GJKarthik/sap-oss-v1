# GGUF (GGML Unified Format) File Format Specification
# Declarative definition of the GGUF binary format

# Magic bytes and version
gguf_magic(0x46554747).  # "GGUF" in little-endian
gguf_version(3).

# Metadata value types: gguf_type(name, type_id, size_bytes, is_array)
gguf_type("uint8", 0, 1, false).
gguf_type("int8", 1, 1, false).
gguf_type("uint16", 2, 2, false).
gguf_type("int16", 3, 2, false).
gguf_type("uint32", 4, 4, false).
gguf_type("int32", 5, 4, false).
gguf_type("float32", 6, 4, false).
gguf_type("bool", 7, 1, false).
gguf_type("string", 8, 0, false).  # variable length
gguf_type("array", 9, 0, true).
gguf_type("uint64", 10, 8, false).
gguf_type("int64", 11, 8, false).
gguf_type("float64", 12, 8, false).

# File header layout: header_field(name, offset, type, description)
header_field("magic", 0, "uint32", "Magic number 'GGUF'").
header_field("version", 4, "uint32", "Format version (currently 3)").
header_field("n_tensors", 8, "uint64", "Number of tensors in file").
header_field("n_kv", 16, "uint64", "Number of key-value pairs in metadata").

# Required metadata keys for LLM models
required_key("general.architecture", "string", "Model architecture type").
required_key("general.name", "string", "Model name").
required_key("general.file_type", "uint32", "Quantization type").

# Architecture-specific keys: arch_key(arch, key, type, description)
arch_key("llama", "llama.context_length", "uint32", "Maximum context length").
arch_key("llama", "llama.embedding_length", "uint32", "Embedding dimension").
arch_key("llama", "llama.block_count", "uint32", "Number of transformer blocks").
arch_key("llama", "llama.attention.head_count", "uint32", "Number of attention heads").
arch_key("llama", "llama.attention.head_count_kv", "uint32", "Number of KV heads (GQA)").
arch_key("llama", "llama.feed_forward_length", "uint32", "FFN hidden dimension").
arch_key("llama", "llama.rope.dimension_count", "uint32", "RoPE dimensions").
arch_key("llama", "llama.rope.freq_base", "float32", "RoPE base frequency").
arch_key("llama", "llama.attention.layer_norm_rms_epsilon", "float32", "RMS norm epsilon").

arch_key("phi2", "phi2.context_length", "uint32", "Maximum context length").
arch_key("phi2", "phi2.embedding_length", "uint32", "Embedding dimension").
arch_key("phi2", "phi2.block_count", "uint32", "Number of transformer blocks").
arch_key("phi2", "phi2.attention.head_count", "uint32", "Number of attention heads").
arch_key("phi2", "phi2.attention.head_count_kv", "uint32", "Number of KV heads").
arch_key("phi2", "phi2.feed_forward_length", "uint32", "FFN hidden dimension").
arch_key("phi2", "phi2.rope.dimension_count", "uint32", "RoPE dimensions").
arch_key("phi2", "phi2.attention.layer_norm_epsilon", "float32", "Layer norm epsilon").

# Tokenizer metadata keys
tokenizer_key("tokenizer.ggml.model", "string", "Tokenizer model type").
tokenizer_key("tokenizer.ggml.tokens", "array", "Token strings").
tokenizer_key("tokenizer.ggml.token_type", "array", "Token types").
tokenizer_key("tokenizer.ggml.merges", "array", "BPE merges").
tokenizer_key("tokenizer.ggml.bos_token_id", "uint32", "Begin of sequence token").
tokenizer_key("tokenizer.ggml.eos_token_id", "uint32", "End of sequence token").
tokenizer_key("tokenizer.ggml.padding_token_id", "uint32", "Padding token").

# Tensor naming patterns: tensor_pattern(arch, pattern, description)
tensor_pattern("llama", "token_embd.weight", "Token embedding matrix").
tensor_pattern("llama", "blk.{N}.attn_q.weight", "Query projection").
tensor_pattern("llama", "blk.{N}.attn_k.weight", "Key projection").
tensor_pattern("llama", "blk.{N}.attn_v.weight", "Value projection").
tensor_pattern("llama", "blk.{N}.attn_output.weight", "Output projection").
tensor_pattern("llama", "blk.{N}.attn_norm.weight", "Pre-attention RMS norm").
tensor_pattern("llama", "blk.{N}.ffn_gate.weight", "FFN gate (SiLU)").
tensor_pattern("llama", "blk.{N}.ffn_up.weight", "FFN up projection").
tensor_pattern("llama", "blk.{N}.ffn_down.weight", "FFN down projection").
tensor_pattern("llama", "blk.{N}.ffn_norm.weight", "Pre-FFN RMS norm").
tensor_pattern("llama", "output_norm.weight", "Final RMS norm").
tensor_pattern("llama", "output.weight", "Output projection / LM head").

tensor_pattern("phi2", "token_embd.weight", "Token embedding matrix").
tensor_pattern("phi2", "blk.{N}.attn_qkv.weight", "QKV combined projection").
tensor_pattern("phi2", "blk.{N}.attn_output.weight", "Output projection").
tensor_pattern("phi2", "blk.{N}.attn_norm.weight", "Attention layer norm").
tensor_pattern("phi2", "blk.{N}.attn_norm.bias", "Attention layer norm bias").
tensor_pattern("phi2", "blk.{N}.ffn_up.weight", "FFN up projection").
tensor_pattern("phi2", "blk.{N}.ffn_down.weight", "FFN down projection").
tensor_pattern("phi2", "blk.{N}.ffn_norm.weight", "FFN layer norm").
tensor_pattern("phi2", "blk.{N}.ffn_norm.bias", "FFN layer norm bias").
tensor_pattern("phi2", "output_norm.weight", "Final layer norm").
tensor_pattern("phi2", "output_norm.bias", "Final layer norm bias").
tensor_pattern("phi2", "output.weight", "Output projection").
tensor_pattern("phi2", "output.bias", "Output bias").

# Tensor info structure: tensor_info_field(name, type, description)
tensor_info_field("name", "string", "Tensor name").
tensor_info_field("n_dims", "uint32", "Number of dimensions").
tensor_info_field("dims", "uint64[]", "Dimension sizes").
tensor_info_field("dtype", "uint32", "Data type enum").
tensor_info_field("offset", "uint64", "Offset in data section").

# Validation rules
valid_gguf(File) :-
    file_magic(File, Magic),
    gguf_magic(Magic),
    file_version(File, Version),
    gguf_version(SupportedVersion),
    Version =< SupportedVersion.

valid_tensor(File, TensorName) :-
    tensor_in_file(File, TensorName),
    tensor_dtype(File, TensorName, DType),
    dtype(DType, _, _, _).

# Derive all required tensors for an architecture
required_tensor(Arch, Pattern) :- tensor_pattern(Arch, Pattern, _).

# Check if model has all required tensors
complete_model(File, Arch) :-
    file_architecture(File, Arch),
    forall(required_tensor(Arch, Pattern), 
           tensor_matches_pattern(File, Pattern)).