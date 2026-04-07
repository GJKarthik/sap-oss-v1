# Tensor Data Types (GGML-compatible)
# These facts define the supported tensor data types and their properties

# Base tensor types: dtype(name, enum_value, block_size_bytes, elements_per_block)
dtype("F32", 0, 4, 1).
dtype("F16", 1, 2, 1).
dtype("Q4_0", 2, 18, 32).
dtype("Q4_1", 3, 20, 32).
dtype("Q5_0", 6, 22, 32).
dtype("Q5_1", 7, 24, 32).
dtype("Q8_0", 8, 34, 32).
dtype("Q8_1", 9, 36, 32).
dtype("Q2_K", 10, 84, 256).
dtype("Q3_K", 11, 110, 256).
dtype("Q4_K", 12, 144, 256).
dtype("Q5_K", 13, 176, 256).
dtype("Q6_K", 14, 210, 256).
dtype("Q8_K", 15, 292, 256).
dtype("IQ2_XXS", 16, 66, 256).
dtype("IQ2_XS", 17, 74, 256).
dtype("IQ3_XXS", 18, 98, 256).
dtype("IQ1_S", 19, 50, 256).
dtype("IQ4_NL", 20, 50, 32).
dtype("IQ3_S", 21, 110, 256).
dtype("IQ2_S", 22, 82, 256).
dtype("IQ4_XS", 23, 36, 32).
dtype("I8", 24, 1, 1).
dtype("I16", 25, 2, 1).
dtype("I32", 26, 4, 1).
dtype("I64", 27, 8, 1).
dtype("F64", 28, 8, 1).
dtype("BF16", 30, 2, 1).

# Derived: quantized types (block_elements > 1)
quantized_dtype(Name) :- dtype(Name, _, _, BlockElems), BlockElems > 1.

# Derived: float types
float_dtype(Name) :- dtype(Name, _, _, 1), fn:string_contains(Name, "F").
float_dtype("BF16").

# Derived: integer types  
int_dtype(Name) :- dtype(Name, _, _, 1), fn:string_contains(Name, "I").

# Compute bytes needed for N elements
bytes_for(DType, NumElements, Bytes) :-
    dtype(DType, _, BlockSize, BlockElems),
    NumBlocks = fn:div(NumElements + BlockElems - 1, BlockElems),
    Bytes = fn:mul(NumBlocks, BlockSize).

# SIMD vector lengths for different architectures
simd_vec_len("x86_64", "avx2", 8).     # 256-bit / 32-bit = 8 floats
simd_vec_len("x86_64", "avx512", 16).  # 512-bit / 32-bit = 16 floats
simd_vec_len("aarch64", "neon", 4).    # 128-bit / 32-bit = 4 floats

# Operation support matrix: op_supported(dtype, operation)
op_supported(DType, "add") :- float_dtype(DType).
op_supported(DType, "mul") :- float_dtype(DType).
op_supported(DType, "matmul") :- float_dtype(DType).
op_supported(DType, "softmax") :- float_dtype(DType).
op_supported(DType, "rms_norm") :- float_dtype(DType).
op_supported(DType, "layer_norm") :- float_dtype(DType).

# Quantized types need dequantization before ops
needs_dequant(DType, Op) :- quantized_dtype(DType), op_supported("F32", Op).