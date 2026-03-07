"""
Quantization Module - INT4/INT8 weight quantization for memory efficiency.

Implements:
- Per-group quantization with scales and zero points
- Fast SIMD dequantization 
- GPTQ-style and AWQ-style quantization
- Mixed precision per layer type
"""

from memory import memset_zero, memcpy
from sys.info import simdwidthof
from algorithm import vectorize, parallelize
from math import sqrt, abs as math_abs, min as math_min, max as math_max


alias SIMD_WIDTH = simdwidthof[DType.float32]()


# =============================================================================
# Quantization Configuration
# =============================================================================

struct QuantizationConfig:
    """Configuration for model quantization."""
    var bits: Int  # 4 or 8
    var group_size: Int  # Typically 128
    var symmetric: Bool  # Symmetric vs asymmetric quantization
    var per_channel: Bool  # Per-channel vs per-tensor
    
    # Per-layer precision (optional)
    var attention_bits: Int
    var ffn_bits: Int
    var embedding_bits: Int
    
    fn __init__(inout self, bits: Int = 4, group_size: Int = 128):
        self.bits = bits
        self.group_size = group_size
        self.symmetric = True
        self.per_channel = True
        self.attention_bits = bits
        self.ffn_bits = bits
        self.embedding_bits = 8  # Embeddings often need more precision
    
    fn max_int(self) -> Int:
        """Maximum integer value for this bit width."""
        if self.bits == 4:
            return 7 if self.symmetric else 15
        elif self.bits == 8:
            return 127 if self.symmetric else 255
        return 127
    
    fn min_int(self) -> Int:
        """Minimum integer value for this bit width."""
        if self.symmetric:
            return -self.max_int()
        return 0


# =============================================================================
# Quantized Tensor Storage
# =============================================================================

struct QuantizedTensor:
    """
    Storage for quantized weights.
    
    For INT4: 2 weights packed per byte
    For INT8: 1 weight per byte
    """
    var data: UnsafePointer[UInt8]  # Packed quantized weights
    var scales: UnsafePointer[Float32]  # Per-group scales
    var zero_points: UnsafePointer[Int8]  # Per-group zero points
    var num_elements: Int
    var num_groups: Int
    var bits: Int
    var group_size: Int
    var shape_m: Int
    var shape_n: Int
    
    fn __init__(inout self, shape_m: Int, shape_n: Int, bits: Int, group_size: Int):
        self.shape_m = shape_m
        self.shape_n = shape_n
        self.num_elements = shape_m * shape_n
        self.bits = bits
        self.group_size = group_size
        self.num_groups = (self.num_elements + group_size - 1) // group_size
        
        # Allocate storage
        var data_bytes: Int
        if bits == 4:
            data_bytes = (self.num_elements + 1) // 2  # 2 weights per byte
        else:
            data_bytes = self.num_elements
        
        self.data = UnsafePointer[UInt8].alloc(data_bytes)
        self.scales = UnsafePointer[Float32].alloc(self.num_groups)
        self.zero_points = UnsafePointer[Int8].alloc(self.num_groups)
    
    fn __del__(owned self):
        self.data.free()
        self.scales.free()
        self.zero_points.free()
    
    fn memory_bytes(self) -> Int:
        """Calculate memory usage in bytes."""
        var data_bytes: Int
        if self.bits == 4:
            data_bytes = (self.num_elements + 1) // 2
        else:
            data_bytes = self.num_elements
        return data_bytes + self.num_groups * 4 + self.num_groups


# =============================================================================
# Quantization Functions
# =============================================================================

fn quantize_tensor(
    weights: UnsafePointer[Float32],
    output: QuantizedTensor,
    config: QuantizationConfig,
):
    """
    Quantize FP32 weights to INT4/INT8.
    
    Uses per-group quantization for better accuracy.
    """
    var group_size = config.group_size
    var bits = config.bits
    var symmetric = config.symmetric
    
    for g in range(output.num_groups):
        var start = g * group_size
        var end = min(start + group_size, output.num_elements)
        var count = end - start
        
        # Find min/max in group
        var g_min = weights[start]
        var g_max = weights[start]
        for i in range(start + 1, end):
            g_min = math_min(g_min, weights[i])
            g_max = math_max(g_max, weights[i])
        
        # Compute scale and zero point
        var scale: Float32
        var zero_point: Int8
        
        if symmetric:
            var abs_max = math_max(math_abs(g_min), math_abs(g_max))
            scale = abs_max / Float32(config.max_int())
            zero_point = 0
        else:
            scale = (g_max - g_min) / Float32(config.max_int() - config.min_int())
            zero_point = Int8(-round(g_min / scale))
        
        # Clamp scale to avoid division by zero
        if scale < 1e-10:
            scale = 1e-10
        
        output.scales[g] = scale
        output.zero_points[g] = zero_point
        
        # Quantize weights in this group
        for i in range(count):
            var idx = start + i
            var q_val = Int(round(weights[idx] / scale)) + Int(zero_point)
            
            # Clamp to valid range
            q_val = max(config.min_int(), min(config.max_int(), q_val))
            
            # Pack into storage
            if bits == 4:
                var byte_idx = idx // 2
                var is_high = idx % 2
                if is_high == 0:
                    output.data[byte_idx] = UInt8(q_val & 0x0F)
                else:
                    output.data[byte_idx] = output.data[byte_idx] | UInt8((q_val & 0x0F) << 4)
            else:
                output.data[idx] = UInt8(q_val + 128)  # Offset for unsigned storage


fn dequantize_group_simd[width: Int](
    data: UnsafePointer[UInt8],
    scale: Float32,
    zero_point: Int8,
    output: UnsafePointer[Float32],
    start_idx: Int,
    count: Int,
    bits: Int,
):
    """SIMD-optimized dequantization of a group."""
    var zp = Float32(zero_point)
    
    if bits == 8:
        @parameter
        fn dequant_8[w: Int](i: Int):
            var packed = (data + start_idx + i).simd_load[w]()
            var as_int = packed.cast[DType.float32]() - 128.0
            var dequant = (as_int - zp) * scale
            (output + start_idx + i).simd_store[w](dequant)
        
        vectorize[dequant_8, width](count)
    else:  # INT4 - process 2 weights per byte
        var half_count = count // 2  # number of full bytes

        @parameter
        fn dequant_4[w: Int](byte_i: Int):
            var idx = start_idx + byte_i * 2
            var byte_val = data[start_idx // 2 + byte_i]
            var lo = Int(byte_val & 0x0F)
            var hi = Int((byte_val >> 4) & 0x0F)
            # Sign extend for signed INT4
            if lo > 7:
                lo -= 16
            if hi > 7:
                hi -= 16
            output[idx] = Float32(lo - Int(zero_point)) * scale
            output[idx + 1] = Float32(hi - Int(zero_point)) * scale

        vectorize[dequant_4, width](half_count)

        # Handle odd trailing element
        if count % 2 != 0:
            var idx = start_idx + half_count * 2
            var byte_val = data[idx // 2]
            var q_val = Int(byte_val & 0x0F)
            if q_val > 7:
                q_val -= 16
            output[idx] = Float32(q_val - Int(zero_point)) * scale


fn dequantize_tensor(
    quantized: QuantizedTensor,
    output: UnsafePointer[Float32],
):
    """Dequantize entire tensor to FP32."""
    var group_size = quantized.group_size
    
    for g in range(quantized.num_groups):
        var start = g * group_size
        var end = min(start + group_size, quantized.num_elements)
        var count = end - start
        
        dequantize_group_simd[SIMD_WIDTH](
            quantized.data,
            quantized.scales[g],
            quantized.zero_points[g],
            output,
            start,
            count,
            quantized.bits
        )


# =============================================================================
# Quantized Matrix Multiplication
# =============================================================================

fn quantized_matmul(
    A: UnsafePointer[Float32],  # [M, K] FP32 activations
    B_quant: QuantizedTensor,   # [K, N] quantized weights
    C: UnsafePointer[Float32],  # [M, N] output
    M: Int,
    K: Int,
    N: Int,
):
    """
    Matrix multiply with quantized weights.
    
    Fused Implementation: Dequantizes on-the-fly during dot-product accumulation.
    """
    var group_size = B_quant.group_size
    var bits = B_quant.bits
    
    for m in range(M):
        for n in range(N):
            var acc = Float32(0.0)
            for k in range(K):
                let b_idx = k * N + n
                let g = b_idx // group_size
                
                # Fused dequantization logic
                var q_val: Int
                if bits == 4:
                    let byte_idx = b_idx // 2
                    let is_high = b_idx % 2
                    if is_high == 0:
                        q_val = Int(B_quant.data[byte_idx] & 0x0F)
                    else:
                        q_val = Int((B_quant.data[byte_idx] >> 4) & 0x0F)
                    if q_val > 7: q_val -= 16
                else:
                    q_val = Int(B_quant.data[b_idx]) - 128
                
                let b_val = Float32(q_val - Int(B_quant.zero_points[g])) * B_quant.scales[g]
                acc += A[m * K + k] * b_val
            C[m * N + n] = acc


fn quantized_matmul_tiled(
    A: UnsafePointer[Float32],
    B_quant: QuantizedTensor,
    C: UnsafePointer[Float32],
    M: Int,
    K: Int,
    N: Int,
    tile_m: Int = 32,
    tile_n: Int = 32,
    tile_k: Int = 32,
):
    """
    Tiled quantized matmul for better cache utilization.

    B_tile is stored in column-major order [ni, ki] so that for a fixed
    output column n, the K-dimension values are contiguous — enabling
    SIMD loads over the K reduction axis.
    """
    # Allocate B tile in column-major layout: B_tile[ni * tile_k + ki].
    var B_tile = UnsafePointer[Float32].alloc(tile_k * tile_n)

    # Initialize C to zero.
    memset_zero(C.bitcast[UInt8](), M * N * 4)

    # Tile over K dimension.
    for k_start in range(0, K, tile_k):
        var k_end = min(k_start + tile_k, K)
        var k_size = k_end - k_start

        # Tile over N dimension.
        for n_start in range(0, N, tile_n):
            var n_end = min(n_start + tile_n, N)
            var n_size = n_end - n_start

            # Dequantize B tile into column-major layout B_tile[ni * k_size + ki].
            for ni in range(n_size):
                var n = n_start + ni
                for ki in range(k_size):
                    var k = k_start + ki
                    var b_idx = k * N + n
                    var g = b_idx // B_quant.group_size
                    var scale = B_quant.scales[g]
                    var zp = B_quant.zero_points[g]

                    var q_val: Int
                    if B_quant.bits == 4:
                        var byte_idx = b_idx // 2
                        var is_high = b_idx % 2
                        if is_high == 0:
                            q_val = Int(B_quant.data[byte_idx] & 0x0F)
                        else:
                            q_val = Int((B_quant.data[byte_idx] >> 4) & 0x0F)
                        if q_val > 7:
                            q_val = q_val - 16
                    else:
                        q_val = Int(B_quant.data[b_idx]) - 128

                    B_tile[ni * k_size + ki] = Float32(q_val - Int(zp)) * scale

            # Tile over M dimension.
            for m_start in range(0, M, tile_m):
                var m_end = min(m_start + tile_m, M)
                var m_size = m_end - m_start

                # Compute C tile += A tile @ B tile using SIMD over K.
                for mi in range(m_size):
                    var m = m_start + mi
                    var a_row = A + m * K + k_start  # pointer to A[m, k_start]

                    for ni in range(n_size):
                        var n = n_start + ni
                        var b_col = B_tile + ni * k_size  # pointer to B_tile column ni

                        # Vectorized dot product over k_size elements.
                        var acc = Float32(0.0)

                        @parameter
                        fn dot_simd[width: Int](ki: Int):
                            var a_vec = (a_row + ki).simd_load[width]()
                            var b_vec = (b_col + ki).simd_load[width]()
                            acc += (a_vec * b_vec).reduce_add()

                        vectorize[dot_simd, SIMD_WIDTH](k_size)

                        C[m * N + n] += acc

    B_tile.free()


# =============================================================================
# Model Quantization
# =============================================================================

struct QuantizedModel:
    """Container for quantized model weights."""
    var config: QuantizationConfig
    var embeddings: QuantizedTensor
    var attention_qkv: List[QuantizedTensor]  # Per layer
    var attention_out: List[QuantizedTensor]
    var ffn_up: List[QuantizedTensor]
    var ffn_down: List[QuantizedTensor]
    var ffn_gate: List[QuantizedTensor]
    var lm_head: QuantizedTensor
    var num_layers: Int
    
    fn __init__(inout self, num_layers: Int, config: QuantizationConfig):
        self.config = config
        self.num_layers = num_layers
        self.attention_qkv = List[QuantizedTensor]()
        self.attention_out = List[QuantizedTensor]()
        self.ffn_up = List[QuantizedTensor]()
        self.ffn_down = List[QuantizedTensor]()
        self.ffn_gate = List[QuantizedTensor]()
        # embeddings and lm_head initialized later
    
    fn total_memory_mb(self) -> Float32:
        """Calculate total memory usage."""
        var total = self.embeddings.memory_bytes()
        total += self.lm_head.memory_bytes()
        
        for i in range(self.num_layers):
            total += self.attention_qkv[i].memory_bytes()
            total += self.attention_out[i].memory_bytes()
            total += self.ffn_up[i].memory_bytes()
            total += self.ffn_down[i].memory_bytes()
            total += self.ffn_gate[i].memory_bytes()
        
        return Float32(total) / (1024.0 * 1024.0)


fn calculate_compression_ratio(
    original_params: Int,
    bits: Int,
    group_size: Int,
) -> Float32:
    """Calculate memory savings from quantization."""
    var fp32_bytes = original_params * 4
    
    var quant_bytes: Int
    if bits == 4:
        quant_bytes = original_params // 2  # 2 weights per byte
    else:
        quant_bytes = original_params
    
    # Add scale/zero point overhead
    var num_groups = (original_params + group_size - 1) // group_size
    var overhead = num_groups * 5  # 4 bytes scale + 1 byte zp
    
    var total_quant = quant_bytes + overhead
    return Float32(fp32_bytes) / Float32(total_quant)


# =============================================================================
# GGUF Q4_K_M Quantization (llama.cpp Compatible)
# =============================================================================
#
# Q4_K_M is the recommended quantization format for llama.cpp models:
# - 4-bit weights with k-quant optimization
# - Superior accuracy vs standard INT4
# - Block size: QK_K = 256 elements
# - Each block has 8 sub-blocks of 32 elements (super-blocks)
#
# Block layout (total ~144 bytes per 256 weights):
#   - d: Float16 scale for the block
#   - dmin: Float16 minimum value offset  
#   - scales: 12 bytes (6-bit scales for 8 sub-blocks, packed)
#   - qs: 128 bytes (4-bit quantized values, 256/2 = 128)

alias QK_K: Int = 256  # Super-block size for k-quants
alias K_SCALE_SIZE: Int = 12  # Bytes for sub-block scales


struct BlockQ4K:
    """
    GGUF Q4_K_M block structure.
    
    Each block contains 256 weights (QK_K) with:
    - d: Scale factor (float16)
    - dmin: Minimum offset (float16)  
    - scales: 6-bit scales for 8 sub-blocks (12 bytes packed)
    - qs: 4-bit quantized weights (128 bytes)
    """
    var d: Float16       # 2 bytes - scale
    var dmin: Float16    # 2 bytes - minimum offset
    var scales: StaticTuple[UInt8, 12]  # 12 bytes - sub-block scales
    var qs: StaticTuple[UInt8, 128]     # 128 bytes - quantized values
    
    fn __init__(inout self):
        self.d = Float16(0)
        self.dmin = Float16(0)
        self.scales = StaticTuple[UInt8, 12]()
        self.qs = StaticTuple[UInt8, 128]()


fn dequantize_q4_k_m_block(
    block: BlockQ4K,
    output: UnsafePointer[Float32],
):
    """
    Dequantize a single Q4_K_M block (256 weights) to FP32.
    
    Q4_K_M format uses super-blocks of 256 with 8 sub-blocks of 32 each.
    Each sub-block has its own 6-bit scale factor.
    """
    var d = Float32(block.d)
    var dmin = Float32(block.dmin)
    
    # Unpack the 6-bit scales from 12 bytes into 8 scale values
    # Layout: scales[0-5] contain low 4 bits, scales[6-11] contain high 2 bits
    var sc = StaticTuple[UInt8, 8]()
    for i in range(4):
        sc[i] = block.scales[i] & 0x3F
    for i in range(4):
        sc[4 + i] = (block.scales[4 + i] & 0x0F) | ((block.scales[i] >> 6) << 4)
    
    # Process 8 sub-blocks of 32 weights each
    for sub_block in range(8):
        var scale_idx = sub_block
        var sub_scale = Float32(sc[scale_idx])
        
        # Each sub-block has 32 weights = 16 bytes of qs (2 weights per byte)
        var qs_offset = sub_block * 16
        
        for i in range(16):
            var qs_byte = block.qs[qs_offset + i]
            
            # Lower 4 bits
            var q_lo = Int(qs_byte & 0x0F)
            var out_idx_lo = sub_block * 32 + i * 2
            output[out_idx_lo] = d * sub_scale * Float32(q_lo) - dmin
            
            # Upper 4 bits
            var q_hi = Int((qs_byte >> 4) & 0x0F)
            var out_idx_hi = sub_block * 32 + i * 2 + 1
            output[out_idx_hi] = d * sub_scale * Float32(q_hi) - dmin


fn dequantize_q4_k_m(
    data: UnsafePointer[UInt8],
    num_blocks: Int,
    output: UnsafePointer[Float32],
):
    """
    Dequantize Q4_K_M quantized data to FP32.
    
    Args:
        data: Raw Q4_K_M block data
        num_blocks: Number of 256-element blocks
        output: Output FP32 buffer (must hold num_blocks * 256 floats)
    """
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2  # 144 bytes per block
    
    for b in range(num_blocks):
        var block_ptr = data + b * block_size
        
        # Parse block structure
        var block = BlockQ4K()
        
        # Read d and dmin (2 bytes each as float16)
        var d_bytes = block_ptr.bitcast[UInt16]()[0]
        var dmin_bytes = (block_ptr + 2).bitcast[UInt16]()[0]
        block.d = Float16.from_bits(d_bytes)
        block.dmin = Float16.from_bits(dmin_bytes)
        
        # Read scales (12 bytes)
        for i in range(K_SCALE_SIZE):
            block.scales[i] = (block_ptr + 4 + i)[0]
        
        # Read qs (128 bytes)
        for i in range(QK_K // 2):
            block.qs[i] = (block_ptr + 4 + K_SCALE_SIZE + i)[0]
        
        # Dequantize this block
        dequantize_q4_k_m_block(block, output + b * QK_K)


fn dequantize_q4_k_m_simd[width: Int](
    data: UnsafePointer[UInt8],
    num_blocks: Int,
    output: UnsafePointer[Float32],
):
    """
    SIMD-optimized Q4_K_M dequantization.
    
    Processes multiple weights in parallel using SIMD.
    """
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2  # 144 bytes
    
    @parameter
    fn process_block(b: Int):
        var block_ptr = data + b * block_size
        var out_ptr = output + b * QK_K
        
        # Read d and dmin
        var d_bits = block_ptr.bitcast[UInt16]()[0]
        var dmin_bits = (block_ptr + 2).bitcast[UInt16]()[0]
        var d = Float32(Float16.from_bits(d_bits))
        var dmin = Float32(Float16.from_bits(dmin_bits))
        
        # Unpack scales
        var scales_ptr = block_ptr + 4
        var sc0 = scales_ptr[0] & 0x3F
        var sc1 = scales_ptr[1] & 0x3F
        var sc2 = scales_ptr[2] & 0x3F
        var sc3 = scales_ptr[3] & 0x3F
        var sc4 = (scales_ptr[4] & 0x0F) | ((scales_ptr[0] >> 6) << 4)
        var sc5 = (scales_ptr[5] & 0x0F) | ((scales_ptr[1] >> 6) << 4)
        var sc6 = (scales_ptr[6] & 0x0F) | ((scales_ptr[2] >> 6) << 4)
        var sc7 = (scales_ptr[7] & 0x0F) | ((scales_ptr[3] >> 6) << 4)
        
        var scales = StaticTuple[Float32, 8](
            Float32(sc0), Float32(sc1), Float32(sc2), Float32(sc3),
            Float32(sc4), Float32(sc5), Float32(sc6), Float32(sc7)
        )
        
        var qs_ptr = block_ptr + 4 + K_SCALE_SIZE
        
        # Process each sub-block with SIMD
        for sb in range(8):
            var sub_scale = d * scales[sb]
            var qs_offset = sb * 16
            
            # Process 16 bytes (32 weights) with SIMD vectorization
            @parameter
            fn dequant_pair[w: Int](i: Int):
                var qs_byte = qs_ptr[qs_offset + i]
                var q_lo = Float32(Int(qs_byte & 0x0F))
                var q_hi = Float32(Int((qs_byte >> 4) & 0x0F))

                var out_idx = sb * 32 + i * 2
                out_ptr[out_idx] = sub_scale * q_lo - dmin
                out_ptr[out_idx + 1] = sub_scale * q_hi - dmin

            vectorize[dequant_pair, width](16)
    
    # Parallelize across blocks
    parallelize[process_block](num_blocks)


struct Q4KMTensor:
    """
    Storage for Q4_K_M quantized tensor (GGUF format).
    
    Optimized for llama.cpp model loading.
    """
    var data: UnsafePointer[UInt8]
    var num_blocks: Int
    var num_elements: Int
    var shape: Tuple[Int, Int]
    
    fn __init__(inout self, rows: Int, cols: Int):
        self.shape = (rows, cols)
        self.num_elements = rows * cols
        self.num_blocks = (self.num_elements + QK_K - 1) // QK_K
        
        var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2  # 144 bytes
        self.data = UnsafePointer[UInt8].alloc(self.num_blocks * block_size)
    
    fn __del__(owned self):
        self.data.free()
    
    fn from_raw_data(inout self, raw_data: UnsafePointer[UInt8], num_bytes: Int):
        """Load from raw GGUF data."""
        memcpy(self.data.bitcast[UInt8](), raw_data.bitcast[UInt8](), num_bytes)
    
    fn dequantize(self, output: UnsafePointer[Float32]):
        """Dequantize to FP32."""
        dequantize_q4_k_m_simd[SIMD_WIDTH](self.data, self.num_blocks, output)
    
    fn memory_bytes(self) -> Int:
        """Memory usage in bytes."""
        var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
        return self.num_blocks * block_size
    
    fn compression_ratio(self) -> Float32:
        """Compression ratio vs FP32."""
        var fp32_bytes = self.num_elements * 4
        return Float32(fp32_bytes) / Float32(self.memory_bytes())


# =============================================================================
# Q4_K_M Quantized Matrix Multiplication
# =============================================================================

fn q4_k_m_matmul(
    activations: UnsafePointer[Float32],  # [M, K] FP32 input
    weights: Q4KMTensor,                   # [K, N] Q4_K_M weights
    output: UnsafePointer[Float32],        # [M, N] FP32 output
    M: Int,
    K: Int, 
    N: Int,
):
    """
    Matrix multiply with Q4_K_M quantized weights.
    
    Fused dequantization during computation for memory efficiency.
    """
    var block_size = 2 + 2 + K_SCALE_SIZE + QK_K // 2
    
    # For each output row
    for m in range(M):
        # For each output column
        for n in range(N):
            var acc = Float32(0.0)
            
            # Iterate over K dimension
            for k in range(K):
                # Find which block and position within block
                var weight_idx = k * N + n
                var block_idx = weight_idx // QK_K
                var pos_in_block = weight_idx % QK_K
                
                # Dequantize single weight
                var block_ptr = weights.data + block_idx * block_size
                var d_bits = block_ptr.bitcast[UInt16]()[0]
                var dmin_bits = (block_ptr + 2).bitcast[UInt16]()[0]
                var d = Float32(Float16.from_bits(d_bits))
                var dmin = Float32(Float16.from_bits(dmin_bits))
                
                # Get sub-block scale
                var sub_block = pos_in_block // 32
                var scales_ptr = block_ptr + 4
                var sc: UInt8
                if sub_block < 4:
                    sc = scales_ptr[sub_block] & 0x3F
                else:
                    sc = (scales_ptr[sub_block] & 0x0F) | ((scales_ptr[sub_block - 4] >> 6) << 4)
                
                # Get quantized value
                var qs_idx = pos_in_block // 2
                var qs_byte = (block_ptr + 4 + K_SCALE_SIZE)[qs_idx]
                var q_val: Int
                if pos_in_block % 2 == 0:
                    q_val = Int(qs_byte & 0x0F)
                else:
                    q_val = Int((qs_byte >> 4) & 0x0F)
                
                var weight = d * Float32(sc) * Float32(q_val) - dmin
                acc += activations[m * K + k] * weight
            
            output[m * N + n] = acc


# =============================================================================
# AWQ-Style Quantization (Activation-Aware)
# =============================================================================

fn compute_awq_scales(
    weights: UnsafePointer[Float32],
    activations: UnsafePointer[Float32],
    num_weights: Int,
    num_activations: Int,
    group_size: Int,
) -> UnsafePointer[Float32]:
    """
    Compute AWQ-style scales based on activation magnitudes.
    
    Weights with higher activation magnitudes get more precision.
    """
    var num_groups = (num_weights + group_size - 1) // group_size
    var scales = UnsafePointer[Float32].alloc(num_groups)
    
    for g in range(num_groups):
        var start = g * group_size
        var end = min(start + group_size, num_weights)
        
        # Compute average activation magnitude for this group
        var act_sum = Float32(0.0)
        for i in range(start, end):
            var act_idx = i % num_activations
            act_sum += math_abs(activations[act_idx])
        var avg_act = act_sum / Float32(end - start)
        
        # Find weight range
        var w_max = Float32(0.0)
        for i in range(start, end):
            w_max = math_max(w_max, math_abs(weights[i]))
        
        # Scale factor: protect weights with high activations
        scales[g] = w_max * (1.0 + avg_act * 0.1)
    
    return scales