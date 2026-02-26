# Code Generation Rules
# Generate Zig source code from Mangle specifications

# ============================================================================
# Zig code templates
# ============================================================================

# Generate DataType enum from dtype facts
zig_datatype_enum(Code) :-
    Code = "pub const DataType = enum(u32) {\n" ++
           zig_datatype_variants() ++
           "\n};".

zig_datatype_variant(Name, EnumVal, Line) :-
    dtype(Name, EnumVal, _, _),
    Line = "    " ++ Name ++ " = " ++ fn:to_string(EnumVal) ++ ",".

# Generate blockSize function
zig_block_size_fn(Code) :-
    Code = "pub fn blockSize(self: DataType) usize {\n" ++
           "    return switch (self) {\n" ++
           zig_block_size_cases() ++
           "    };\n}".

zig_block_size_case(Name, BlockSize, Line) :-
    dtype(Name, _, BlockSize, _),
    Line = "        ." ++ Name ++ " => " ++ fn:to_string(BlockSize) ++ ",".

# Generate blockElements function
zig_block_elements_fn(Code) :-
    Code = "pub fn blockElements(self: DataType) usize {\n" ++
           "    return switch (self) {\n" ++
           zig_block_elements_cases() ++
           "    };\n}".

# ============================================================================
# GGUF parsing code generation
# ============================================================================

# Generate GGUF metadata type enum
zig_gguf_type_enum(Code) :-
    Code = "pub const GGUFType = enum(u32) {\n" ++
           zig_gguf_type_variants() ++
           "\n};".

zig_gguf_type_variant(Name, TypeId, Line) :-
    gguf_type(Name, TypeId, _, _),
    Line = "    " ++ Name ++ " = " ++ fn:to_string(TypeId) ++ ",".

# Generate header struct
zig_gguf_header_struct(Code) :-
    Code = "pub const GGUFHeader = extern struct {\n" ++
           "    magic: u32,\n" ++
           "    version: u32,\n" ++
           "    n_tensors: u64,\n" ++
           "    n_kv: u64,\n" ++
           "};".

# ============================================================================
# Model architecture code generation
# ============================================================================

# Generate architecture enum
zig_arch_enum(Code) :-
    Code = "pub const Architecture = enum {\n" ++
           zig_arch_variants() ++
           "\n};".

zig_arch_variant(Name, Line) :-
    arch(Name, _),
    Line = "    " ++ Name ++ ",".

# Generate model config struct
zig_model_config_struct(Code) :-
    Code = "pub const ModelConfig = struct {\n" ++
           "    arch: Architecture,\n" ++
           "    n_layers: u32,\n" ++
           "    n_heads: u32,\n" ++
           "    n_kv_heads: u32,\n" ++
           "    dim: u32,\n" ++
           "    ff_dim: u32,\n" ++
           "    vocab_size: u32,\n" ++
           "    context_length: u32,\n" ++
           "    norm_eps: f32,\n" ++
           "    rope_base: f32,\n" ++
           "    rope_dim: u32,\n" ++
           "\n" ++
           "    pub fn headDim(self: ModelConfig) u32 {\n" ++
           "        return self.dim / self.n_heads;\n" ++
           "    }\n" ++
           "};".

# Generate known model configs
zig_known_configs(Code) :-
    Code = "pub const known_configs = std.ComptimeStringMap(ModelConfig, .{\n" ++
           zig_config_entries() ++
           "});".

zig_config_entry(Name, Entry) :-
    model_config(Arch, Name, NLayers, NHeads, NKVHeads, Dim, FFDim, Vocab, Ctx),
    Entry = "    .{ \"" ++ Name ++ "\", .{\n" ++
            "        .arch = ." ++ Arch ++ ",\n" ++
            "        .n_layers = " ++ fn:to_string(NLayers) ++ ",\n" ++
            "        .n_heads = " ++ fn:to_string(NHeads) ++ ",\n" ++
            "        .n_kv_heads = " ++ fn:to_string(NKVHeads) ++ ",\n" ++
            "        .dim = " ++ fn:to_string(Dim) ++ ",\n" ++
            "        .ff_dim = " ++ fn:to_string(FFDim) ++ ",\n" ++
            "        .vocab_size = " ++ fn:to_string(Vocab) ++ ",\n" ++
            "        .context_length = " ++ fn:to_string(Ctx) ++ ",\n" ++
            "    }},".

# ============================================================================
# Operation code generation
# ============================================================================

# Generate operation enum
zig_op_enum(Code) :-
    Code = "pub const Op = enum {\n" ++
           "    // Tensor operations\n" ++
           zig_op_variants() ++
           "\n};".

zig_op_variant(OpName, Line) :-
    forward_op(OpName, _, _),
    Line = "    " ++ OpName ++ ",".

# ============================================================================
# Layer structure code generation
# ============================================================================

# Generate forward pass for an architecture
zig_forward_fn(Arch, Code) :-
    arch(Arch, _),
    Code = "pub fn forward_" ++ Arch ++ "(self: *Model, input: *Tensor) !*Tensor {\n" ++
           zig_forward_body(Arch) ++
           "    return output;\n}".

zig_forward_op_code(Arch, Order, OpName, Inputs, Output, Line) :-
    layer_op(Arch, Order, OpName, Inputs, Output),
    Line = "    // Step " ++ fn:to_string(Order) ++ ": " ++ OpName ++ "\n" ++
           "    const " ++ Output ++ " = try self." ++ OpName ++ "(" ++
           fn:join(Inputs, ", ") ++ ");".

# ============================================================================
# Activation function code generation
# ============================================================================

zig_activation_fn("silu", "    return x * (1.0 / (1.0 + @exp(-x)));").
zig_activation_fn("gelu", "    const c = 0.7978845608;\n    return 0.5 * x * (1.0 + std.math.tanh(c * (x + 0.044715 * x * x * x)));").
zig_activation_fn("relu", "    return @max(0, x);").

# ============================================================================
# SIMD kernel code generation
# ============================================================================

# Generate SIMD-optimized vector add
zig_simd_add_kernel(VecLen, Code) :-
    simd_vec_len(_, _, VecLen),
    Code = "fn simdAdd" ++ fn:to_string(VecLen) ++ "(a: []f32, b: []const f32) void {\n" ++
           "    const Vec = @Vector(" ++ fn:to_string(VecLen) ++ ", f32);\n" ++
           "    var i: usize = 0;\n" ++
           "    while (i + " ++ fn:to_string(VecLen) ++ " <= a.len) : (i += " ++ fn:to_string(VecLen) ++ ") {\n" ++
           "        const va: Vec = a[i..][0.." ++ fn:to_string(VecLen) ++ "].*;\n" ++
           "        const vb: Vec = b[i..][0.." ++ fn:to_string(VecLen) ++ "].*;\n" ++
           "        a[i..][0.." ++ fn:to_string(VecLen) ++ "].* = va + vb;\n" ++
           "    }\n" ++
           "    while (i < a.len) : (i += 1) a[i] += b[i];\n}".

# ============================================================================
# Full file generation
# ============================================================================

# Generate complete tensor.zig from Mangle specs
generate_tensor_zig(Code) :-
    Code = "//! Auto-generated from mangle/tensor_types.mg\n\n" ++
           "const std = @import(\"std\");\n\n" ++
           zig_datatype_enum() ++ "\n\n" ++
           zig_block_size_fn() ++ "\n\n" ++
           zig_block_elements_fn().

# Generate complete gguf.zig from Mangle specs
generate_gguf_zig(Code) :-
    Code = "//! Auto-generated from mangle/gguf_format.mg\n\n" ++
           "const std = @import(\"std\");\n\n" ++
           "pub const GGUF_MAGIC: u32 = 0x46554747;\n" ++
           "pub const GGUF_VERSION: u32 = 3;\n\n" ++
           zig_gguf_type_enum() ++ "\n\n" ++
           zig_gguf_header_struct().

# Generate complete model.zig from Mangle specs
generate_model_zig(Code) :-
    Code = "//! Auto-generated from mangle/model_arch.mg\n\n" ++
           "const std = @import(\"std\");\n\n" ++
           zig_arch_enum() ++ "\n\n" ++
           zig_model_config_struct() ++ "\n\n" ++
           zig_known_configs().