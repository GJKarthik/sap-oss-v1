"""
Normalization Layer Implementations

This module provides high-performance normalization layers used in LLMs:
- RMSNorm (Root Mean Square Layer Normalization)
- LayerNorm (Layer Normalization)
- GroupNorm (Group Normalization)
"""

from tensor import Tensor, TensorShape
from math import sqrt, rsqrt
from algorithm import vectorize, parallelize
from sys.info import simdwidthof

alias SIMD_WIDTH = simdwidthof[DType.float16]()


struct RMSNorm:
    """
    Root Mean Square Layer Normalization.
    
    Used in models like LLaMA, Mistral, Qwen, etc.
    
    RMSNorm(x) = x * weight / sqrt(mean(x^2) + eps)
    
    Unlike LayerNorm, RMSNorm doesn't subtract the mean, making it
    more computationally efficient.
    """
    
    var hidden_size: Int
    var eps: Float32
    var weight: Tensor[DType.float16]
    
    fn __init__(
        inout self,
        hidden_size: Int,
        eps: Float32 = 1e-6,
    ):
        self.hidden_size = hidden_size
        self.eps = eps
        
        # Initialize weight to ones
        self.weight = Tensor[DType.float16](hidden_size)
        # In practice, weight would be initialized to 1.0
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            x: Input tensor [..., hidden_size]
        
        Returns:
            Normalized tensor [..., hidden_size]
        """
        # Compute variance (mean of squared values)
        let variance = self._compute_variance(x)
        
        # Compute rsqrt(variance + eps)
        let inv_std = rsqrt(variance + self.eps)
        
        # Normalize and scale
        return x * inv_std * self.weight
    
    fn _compute_variance(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Compute mean of squared values along last dimension."""
        let squared = x * x
        return squared.mean(axis=-1, keepdims=True)
    
    fn forward_with_residual(
        self,
        x: Tensor[DType.float16],
        residual: Tensor[DType.float16],
    ) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
        """
        Fused RMSNorm with residual addition.
        
        Computes: norm(x + residual), returns both norm output and updated residual.
        This fusion is common in transformer models.
        """
        # Add residual
        let hidden = x + residual
        
        # Normalize
        let normed = self.forward(hidden)
        
        return (normed, hidden)


struct LayerNorm:
    """
    Layer Normalization.
    
    Used in models like GPT-2, BERT, etc.
    
    LayerNorm(x) = (x - mean(x)) / sqrt(var(x) + eps) * weight + bias
    
    Normalizes across the feature dimension, computing mean and variance
    per token independently.
    """
    
    var hidden_size: Int
    var eps: Float32
    var weight: Tensor[DType.float16]  # gamma
    var bias: Tensor[DType.float16]    # beta
    var has_bias: Bool
    var elementwise_affine: Bool
    
    fn __init__(
        inout self,
        hidden_size: Int,
        eps: Float32 = 1e-5,
        elementwise_affine: Bool = True,
        bias: Bool = True,
    ):
        self.hidden_size = hidden_size
        self.eps = eps
        self.elementwise_affine = elementwise_affine
        self.has_bias = bias and elementwise_affine
        
        if elementwise_affine:
            self.weight = Tensor[DType.float16](hidden_size)
            if bias:
                self.bias = Tensor[DType.float16](hidden_size)
            else:
                self.bias = Tensor[DType.float16](0)
        else:
            self.weight = Tensor[DType.float16](0)
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            x: Input tensor [..., hidden_size]
        
        Returns:
            Normalized tensor [..., hidden_size]
        """
        # Compute mean
        let mean = x.mean(axis=-1, keepdims=True)
        
        # Compute variance
        let centered = x - mean
        let variance = (centered * centered).mean(axis=-1, keepdims=True)
        
        # Normalize
        let inv_std = rsqrt(variance + self.eps)
        var output = centered * inv_std
        
        # Apply affine transformation
        if self.elementwise_affine:
            output = output * self.weight
            if self.has_bias:
                output = output + self.bias
        
        return output


struct GroupNorm:
    """
    Group Normalization.
    
    Divides channels into groups and normalizes within each group.
    Less commonly used in LLMs but useful for some architectures.
    """
    
    var num_groups: Int
    var num_channels: Int
    var eps: Float32
    var weight: Tensor[DType.float16]
    var bias: Tensor[DType.float16]
    var has_bias: Bool
    var affine: Bool
    
    fn __init__(
        inout self,
        num_groups: Int,
        num_channels: Int,
        eps: Float32 = 1e-5,
        affine: Bool = True,
        bias: Bool = True,
    ):
        self.num_groups = num_groups
        self.num_channels = num_channels
        self.eps = eps
        self.affine = affine
        self.has_bias = bias and affine
        
        if affine:
            self.weight = Tensor[DType.float16](num_channels)
            if bias:
                self.bias = Tensor[DType.float16](num_channels)
            else:
                self.bias = Tensor[DType.float16](0)
        else:
            self.weight = Tensor[DType.float16](0)
            self.bias = Tensor[DType.float16](0)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """
        Forward pass.
        
        Args:
            x: Input tensor [batch, channels, ...]
        
        Returns:
            Normalized tensor [batch, channels, ...]
        """
        let batch_size = x.shape()[0]
        let channels_per_group = self.num_channels // self.num_groups
        
        # Reshape for group normalization
        # [batch, groups, channels_per_group, ...]
        var reshaped = x.reshape(
            batch_size, self.num_groups, channels_per_group, -1
        )
        
        # Compute mean and variance per group
        let mean = reshaped.mean(axis=(2, 3), keepdims=True)
        let variance = ((reshaped - mean) ** 2).mean(axis=(2, 3), keepdims=True)
        
        # Normalize
        let inv_std = rsqrt(variance + self.eps)
        var output = (reshaped - mean) * inv_std
        
        # Reshape back
        output = output.reshape(x.shape())
        
        # Apply affine transformation
        if self.affine:
            output = output * self.weight.reshape(1, -1, 1, 1)
            if self.has_bias:
                output = output + self.bias.reshape(1, -1, 1, 1)
        
        return output


# ==============================================
# Fused Normalization Kernels
# ==============================================

fn fused_add_rmsnorm(
    x: Tensor[DType.float16],
    residual: Tensor[DType.float16],
    weight: Tensor[DType.float16],
    eps: Float32,
) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
    """
    Fused residual addition and RMSNorm.
    
    This is a common operation in transformer models:
    hidden = x + residual
    output = rmsnorm(hidden)
    
    Fusing these operations reduces memory bandwidth by avoiding
    an intermediate write of `hidden`.
    
    Args:
        x: Input tensor
        residual: Residual tensor
        weight: RMSNorm weight
        eps: Epsilon for numerical stability
    
    Returns:
        Tuple of (normalized output, updated residual)
    """
    # Add residual
    let hidden = x + residual
    
    # Compute RMSNorm
    let variance = (hidden * hidden).mean(axis=-1, keepdims=True)
    let inv_std = rsqrt(variance + eps)
    let normed = hidden * inv_std * weight
    
    return (normed, hidden)


fn fused_add_layernorm(
    x: Tensor[DType.float16],
    residual: Tensor[DType.float16],
    weight: Tensor[DType.float16],
    bias: Tensor[DType.float16],
    eps: Float32,
) -> Tuple[Tensor[DType.float16], Tensor[DType.float16]]:
    """
    Fused residual addition and LayerNorm.
    
    Args:
        x: Input tensor
        residual: Residual tensor
        weight: LayerNorm weight (gamma)
        bias: LayerNorm bias (beta)
        eps: Epsilon for numerical stability
    
    Returns:
        Tuple of (normalized output, updated residual)
    """
    # Add residual
    let hidden = x + residual
    
    # Compute LayerNorm
    let mean = hidden.mean(axis=-1, keepdims=True)
    let centered = hidden - mean
    let variance = (centered * centered).mean(axis=-1, keepdims=True)
    let inv_std = rsqrt(variance + eps)
    let normed = centered * inv_std * weight + bias
    
    return (normed, hidden)


# ==============================================
# SIMD-Optimized Implementations
# ==============================================

fn rmsnorm_simd[
    dtype: DType, width: Int
](
    x: Tensor[dtype],
    weight: Tensor[dtype],
    eps: SIMD[dtype, 1],
) -> Tensor[dtype]:
    """
    SIMD-optimized RMSNorm implementation.
    
    Processes `width` elements at a time using SIMD operations.
    """
    let batch_size = x.shape()[0]
    let seq_len = x.shape()[1]
    let hidden_size = x.shape()[2]
    
    var output = Tensor[dtype](batch_size, seq_len, hidden_size)
    
    # Process each token
    for b in range(batch_size):
        for s in range(seq_len):
            # Compute variance using SIMD
            var sum_sq = SIMD[dtype, width](0)
            
            @parameter
            fn accumulate[simd_width: Int](i: Int):
                let vals = x.load[width=simd_width](b, s, i)
                sum_sq += vals * vals
            
            vectorize[accumulate, width](hidden_size)
            
            let variance = sum_sq.reduce_add() / hidden_size
            let inv_std = rsqrt(variance + eps)
            
            # Normalize and scale using SIMD
            @parameter
            fn normalize[simd_width: Int](i: Int):
                let vals = x.load[width=simd_width](b, s, i)
                let w = weight.load[width=simd_width](i)
                let normed = vals * inv_std * w
                output.store[width=simd_width](b, s, i, normed)
            
            vectorize[normalize, width](hidden_size)
    
    return output