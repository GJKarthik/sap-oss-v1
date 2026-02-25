"""
Linear Layer Implementations

This module provides high-performance linear (dense) layer implementations
including support for various quantization methods.
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize
from memory import memset_zero
from sys.info import simdwidthof

alias SIMD_WIDTH = simdwidthof[DType.float16]()


struct LinearConfig:
    """Configuration for linear layers."""
    var in_features: Int
    var out_features: Int
    var bias: Bool
    var dtype: DType
    
    fn __init__(
        inout self,
        in_features: Int,
        out_features: Int,
        bias: Bool = True,
        dtype: DType = DType.float16,
    ):
        self.in_features = in_features
        self.out_features = out_features
        self.bias = bias
        self.dtype = dtype


struct Linear:
    """
    Standard linear (dense) layer.
    
    Computes: y = xW^T + b
    
    Supports:
    - FP16/BF16/FP32 weights
    - Optional bias
    - SIMD-optimized matmul
    """
    
    var config: LinearConfig
    var weight: Tensor[DType.float16]  # [out_features, in_features]
    var bias: Tensor[DType.float16]    # [out_features]
    var has_bias: Bool
    
    fn __init__(inout self, config: LinearConfig):
        self.config = config
        self.has_bias = config.bias
        
        # Initialize weight tensor
        self.weight = Tensor[DType.float16](config.out_features, config.in_features)
        
        # Initialize bias if needed
        if config.bias:
            self.bias = Tensor[DType.float16](config.out_features)
        else:
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            x: Input tensor [batch_size, seq_len, in_features]
        
        Returns:
            Output tensor [batch_size, seq_len, out_features]
        """
        # Matrix multiplication: x @ W^T
        var output = x @ self.weight.T()
        
        # Add bias if present
        if self.has_bias:
            output = output + self.bias
        
        return output
    
    fn num_parameters(self) -> Int:
        """Return total number of parameters."""
        var params = self.config.in_features * self.config.out_features
        if self.has_bias:
            params += self.config.out_features
        return params


struct ColumnParallelLinear:
    """
    Linear layer with column parallelism for tensor parallel inference.
    
    The weight matrix is split along the output dimension across GPUs.
    Each GPU computes a portion of the output, then results are gathered.
    
    GPU 0: W[:, 0:N/2]  -> y_0
    GPU 1: W[:, N/2:N]  -> y_1
    Final: concat(y_0, y_1)
    """
    
    var config: LinearConfig
    var weight: Tensor[DType.float16]
    var bias: Tensor[DType.float16]
    var has_bias: Bool
    var tp_size: Int
    var tp_rank: Int
    
    fn __init__(
        inout self,
        config: LinearConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.has_bias = config.bias
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        # Partition output features across GPUs
        let local_out_features = config.out_features // tp_size
        
        self.weight = Tensor[DType.float16](local_out_features, config.in_features)
        
        if config.bias:
            self.bias = Tensor[DType.float16](local_out_features)
        else:
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Forward pass with column parallelism."""
        var output = x @ self.weight.T()
        
        if self.has_bias:
            output = output + self.bias
        
        return output


struct RowParallelLinear:
    """
    Linear layer with row parallelism for tensor parallel inference.
    
    The weight matrix is split along the input dimension across GPUs.
    Each GPU processes a portion of the input, then results are reduced.
    
    GPU 0: x_0 @ W[0:N/2, :]  -> y_0
    GPU 1: x_1 @ W[N/2:N, :]  -> y_1
    Final: y_0 + y_1 (all-reduce)
    """
    
    var config: LinearConfig
    var weight: Tensor[DType.float16]
    var bias: Tensor[DType.float16]
    var has_bias: Bool
    var tp_size: Int
    var tp_rank: Int
    
    fn __init__(
        inout self,
        config: LinearConfig,
        tp_size: Int = 1,
        tp_rank: Int = 0,
    ):
        self.config = config
        self.has_bias = config.bias and (tp_rank == 0)  # Only rank 0 has bias
        self.tp_size = tp_size
        self.tp_rank = tp_rank
        
        # Partition input features across GPUs
        let local_in_features = config.in_features // tp_size
        
        self.weight = Tensor[DType.float16](config.out_features, local_in_features)
        
        if self.has_bias:
            self.bias = Tensor[DType.float16](config.out_features)
        else:
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Forward pass with row parallelism."""
        var output = x @ self.weight.T()
        
        # All-reduce would happen here in distributed setting
        # For now, just add bias on rank 0
        if self.has_bias:
            output = output + self.bias
        
        return output


struct QKVParallelLinear:
    """
    Fused QKV projection for attention layers.
    
    Computes Q, K, V projections in a single matrix multiplication
    for better efficiency.
    """
    
    var hidden_size: Int
    var num_heads: Int
    var num_kv_heads: Int
    var head_dim: Int
    var qkv_weight: Tensor[DType.float16]
    var qkv_bias: Tensor[DType.float16]
    var has_bias: Bool
    
    fn __init__(
        inout self,
        hidden_size: Int,
        num_heads: Int,
        num_kv_heads: Int,
        head_dim: Int,
        bias: Bool = False,
    ):
        self.hidden_size = hidden_size
        self.num_heads = num_heads
        self.num_kv_heads = num_kv_heads
        self.head_dim = head_dim
        self.has_bias = bias
        
        let q_size = num_heads * head_dim
        let kv_size = num_kv_heads * head_dim
        let total_size = q_size + 2 * kv_size
        
        self.qkv_weight = Tensor[DType.float16](total_size, hidden_size)
        
        if bias:
            self.qkv_bias = Tensor[DType.float16](total_size)
        else:
            self.qkv_bias = Tensor[DType.float16](0)
    
    fn forward(
        self,
        x: Tensor[DType.float16],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16], Tensor[DType.float16]]:
        """
        Forward pass returning separate Q, K, V tensors.
        
        Args:
            x: Input tensor [batch, seq, hidden]
        
        Returns:
            Tuple of (Q, K, V) tensors
        """
        # Single fused projection
        var qkv = x @ self.qkv_weight.T()
        
        if self.has_bias:
            qkv = qkv + self.qkv_bias
        
        # Split into Q, K, V
        let q_size = self.num_heads * self.head_dim
        let kv_size = self.num_kv_heads * self.head_dim
        
        let q = qkv[:, :, 0:q_size]
        let k = qkv[:, :, q_size:q_size + kv_size]
        let v = qkv[:, :, q_size + kv_size:]
        
        return (q, k, v)


struct MergedColumnParallelLinear:
    """
    Merged linear layer for gate and up projections in MLP.
    
    Used in models like LLaMA where gate_proj and up_proj can be fused:
    gate_up = [gate_proj(x), up_proj(x)]
    """
    
    var hidden_size: Int
    var intermediate_size: Int
    var weight: Tensor[DType.float16]
    var tp_size: Int
    
    fn __init__(
        inout self,
        hidden_size: Int,
        intermediate_size: Int,
        tp_size: Int = 1,
    ):
        self.hidden_size = hidden_size
        self.intermediate_size = intermediate_size
        self.tp_size = tp_size
        
        let local_intermediate = intermediate_size // tp_size
        
        # Fused gate and up projections
        self.weight = Tensor[DType.float16](2 * local_intermediate, hidden_size)
    
    fn forward(
        self,
        x: Tensor[DType.float16],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """
        Forward pass returning gate and up outputs.
        
        Returns:
            Tuple of (gate_output, up_output)
        """
        var gate_up = x @ self.weight.T()
        
        let local_intermediate = self.intermediate_size // self.tp_size
        let gate = gate_up[:, :, 0:local_intermediate]
        let up = gate_up[:, :, local_intermediate:]
        
        return (gate, up)


# ==============================================
# Quantized Linear Layers
# ==============================================

struct Int8Linear:
    """
    INT8 quantized linear layer.
    
    Uses symmetric per-tensor or per-channel quantization.
    """
    
    var config: LinearConfig
    var weight: Tensor[DType.int8]
    var scale: Tensor[DType.float16]
    var bias: Tensor[DType.float16]
    var has_bias: Bool
    var per_channel: Bool
    
    fn __init__(
        inout self,
        config: LinearConfig,
        per_channel: Bool = True,
    ):
        self.config = config
        self.has_bias = config.bias
        self.per_channel = per_channel
        
        self.weight = Tensor[DType.int8](config.out_features, config.in_features)
        
        if per_channel:
            self.scale = Tensor[DType.float16](config.out_features)
        else:
            self.scale = Tensor[DType.float16](1)
        
        if config.bias:
            self.bias = Tensor[DType.float16](config.out_features)
        else:
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Forward pass with INT8 computation."""
        # Quantize input
        # Compute in INT8
        # Dequantize output
        # For now, cast and compute in FP16
        var weight_fp16 = self.weight.cast[DType.float16]()
        
        if self.per_channel:
            # Scale per output channel
            weight_fp16 = weight_fp16 * self.scale.reshape(-1, 1)
        else:
            weight_fp16 = weight_fp16 * self.scale[0]
        
        var output = x @ weight_fp16.T()
        
        if self.has_bias:
            output = output + self.bias
        
        return output


struct Int4Linear:
    """
    INT4 quantized linear layer (AWQ/GPTQ style).
    
    Uses asymmetric quantization with zero-points.
    Weights are packed 2 per byte.
    """
    
    var config: LinearConfig
    var qweight: Tensor[DType.int32]  # Packed INT4 weights
    var scales: Tensor[DType.float16]
    var zeros: Tensor[DType.float16]
    var bias: Tensor[DType.float16]
    var has_bias: Bool
    var group_size: Int
    
    fn __init__(
        inout self,
        config: LinearConfig,
        group_size: Int = 128,
    ):
        self.config = config
        self.has_bias = config.bias
        self.group_size = group_size
        
        let num_groups = (config.in_features + group_size - 1) // group_size
        
        # Packed weights: 8 INT4 values per INT32
        let packed_cols = (config.in_features + 7) // 8
        self.qweight = Tensor[DType.int32](config.out_features, packed_cols)
        
        # Per-group scales and zeros
        self.scales = Tensor[DType.float16](config.out_features, num_groups)
        self.zeros = Tensor[DType.float16](config.out_features, num_groups)
        
        if config.bias:
            self.bias = Tensor[DType.float16](config.out_features)
        else:
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Forward pass with INT4 computation."""
        # Dequantize weights and compute
        # This would typically call an optimized CUDA kernel
        # Placeholder implementation
        
        var output = Tensor[DType.float16](
            x.shape()[0], x.shape()[1], self.config.out_features
        )
        
        # TODO: Implement efficient INT4 matmul
        # For now, return zeros
        
        if self.has_bias:
            output = output + self.bias
        
        return output