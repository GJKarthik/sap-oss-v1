"""
Activation Functions

High-performance activation functions used in LLM architectures.
Includes SiLU, GELU, ReLU, and their variants.
"""

from tensor import Tensor, TensorShape
from math import exp, tanh, sqrt, erf
from algorithm import vectorize, parallelize
from sys.info import simdwidthof

alias SIMD_WIDTH = simdwidthof[DType.float16]()
alias PI: Float32 = 3.14159265358979323846
alias SQRT_2_OVER_PI: Float32 = 0.7978845608028654  # sqrt(2/pi)


# ==============================================
# SiLU (Swish) Activation
# ==============================================

fn silu[dtype: DType](x: SIMD[dtype, 1]) -> SIMD[dtype, 1]:
    """
    SiLU (Sigmoid Linear Unit) / Swish activation.
    
    SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))
    
    Used in: LLaMA, Mistral, Qwen, and most modern LLMs.
    """
    return x / (1 + exp(-x))


fn silu_tensor(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """Apply SiLU activation to a tensor."""
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_silu[width: Int](i: Int):
        let vals = x.load[width=width](i)
        let result = vals / (1 + exp(-vals))
        output.store[width=width](i, result)
    
    vectorize[apply_silu, SIMD_WIDTH](total_elements)
    
    return output


fn silu_and_mul(
    x: Tensor[DType.float16],
    gate: Tensor[DType.float16],
) -> Tensor[DType.float16]:
    """
    Fused SiLU activation and element-wise multiplication.
    
    output = SiLU(gate) * x
    
    This is the typical pattern in LLaMA-style MLPs:
    output = silu(gate_proj(x)) * up_proj(x)
    """
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_silu_mul[width: Int](i: Int):
        let x_vals = x.load[width=width](i)
        let gate_vals = gate.load[width=width](i)
        let silu_gate = gate_vals / (1 + exp(-gate_vals))
        output.store[width=width](i, silu_gate * x_vals)
    
    vectorize[apply_silu_mul, SIMD_WIDTH](total_elements)
    
    return output


# ==============================================
# GELU Activation
# ==============================================

fn gelu_exact[dtype: DType](x: SIMD[dtype, 1]) -> SIMD[dtype, 1]:
    """
    Exact GELU (Gaussian Error Linear Unit) activation.
    
    GELU(x) = x * Φ(x) = x * 0.5 * (1 + erf(x / sqrt(2)))
    
    Used in: GPT-2, BERT, and some transformers.
    """
    return x * 0.5 * (1 + erf(x / 1.4142135623730951))  # sqrt(2)


fn gelu_tanh[dtype: DType](x: SIMD[dtype, 1]) -> SIMD[dtype, 1]:
    """
    Fast GELU approximation using tanh.
    
    GELU(x) ≈ 0.5 * x * (1 + tanh(sqrt(2/π) * (x + 0.044715 * x³)))
    
    This is the "fast" GELU used in GPT-2 and many models.
    """
    let inner = SQRT_2_OVER_PI * (x + 0.044715 * x * x * x)
    return 0.5 * x * (1 + tanh(inner))


fn gelu_tensor(x: Tensor[DType.float16], approximate: Bool = True) -> Tensor[DType.float16]:
    """Apply GELU activation to a tensor."""
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    if approximate:
        @parameter
        fn apply_gelu_tanh[width: Int](i: Int):
            let vals = x.load[width=width](i)
            let inner = SQRT_2_OVER_PI * (vals + 0.044715 * vals * vals * vals)
            let result = 0.5 * vals * (1 + tanh(inner))
            output.store[width=width](i, result)
        
        vectorize[apply_gelu_tanh, SIMD_WIDTH](total_elements)
    else:
        @parameter
        fn apply_gelu_exact[width: Int](i: Int):
            let vals = x.load[width=width](i)
            let result = vals * 0.5 * (1 + erf(vals / 1.4142135623730951))
            output.store[width=width](i, result)
        
        vectorize[apply_gelu_exact, SIMD_WIDTH](total_elements)
    
    return output


fn gelu_new_tensor(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """
    "New GELU" activation (used in some GPT variants).
    
    Slightly different approximation coefficients.
    """
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_gelu_new[width: Int](i: Int):
        let vals = x.load[width=width](i)
        let cdf = 0.5 * (1.0 + tanh(SQRT_2_OVER_PI * (vals + 0.044715 * vals * vals * vals)))
        output.store[width=width](i, vals * cdf)
    
    vectorize[apply_gelu_new, SIMD_WIDTH](total_elements)
    
    return output


# ==============================================
# ReLU and Variants
# ==============================================

fn relu[dtype: DType](x: SIMD[dtype, 1]) -> SIMD[dtype, 1]:
    """
    ReLU (Rectified Linear Unit) activation.
    
    ReLU(x) = max(0, x)
    """
    return x if x > 0 else SIMD[dtype, 1](0)


fn relu_tensor(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """Apply ReLU activation to a tensor."""
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_relu[width: Int](i: Int):
        let vals = x.load[width=width](i)
        let zeros = SIMD[DType.float16, width](0)
        output.store[width=width](i, vals.max(zeros))
    
    vectorize[apply_relu, SIMD_WIDTH](total_elements)
    
    return output


fn leaky_relu_tensor(
    x: Tensor[DType.float16],
    negative_slope: Float16 = 0.01,
) -> Tensor[DType.float16]:
    """
    Leaky ReLU activation.
    
    LeakyReLU(x) = x if x > 0 else negative_slope * x
    """
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_leaky_relu[width: Int](i: Int):
        let vals = x.load[width=width](i)
        let zeros = SIMD[DType.float16, width](0)
        let mask = vals > zeros
        let result = mask.select(vals, vals * negative_slope)
        output.store[width=width](i, result)
    
    vectorize[apply_leaky_relu, SIMD_WIDTH](total_elements)
    
    return output


fn relu6_tensor(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """
    ReLU6 activation: min(max(0, x), 6)
    """
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_relu6[width: Int](i: Int):
        let vals = x.load[width=width](i)
        let zeros = SIMD[DType.float16, width](0)
        let sixes = SIMD[DType.float16, width](6)
        output.store[width=width](i, vals.max(zeros).min(sixes))
    
    vectorize[apply_relu6, SIMD_WIDTH](total_elements)
    
    return output


# ==============================================
# QuickGELU (Used in CLIP and some models)
# ==============================================

fn quick_gelu[dtype: DType](x: SIMD[dtype, 1]) -> SIMD[dtype, 1]:
    """
    QuickGELU activation.
    
    QuickGELU(x) = x * sigmoid(1.702 * x)
    
    A faster approximation of GELU used in OpenAI's CLIP.
    """
    return x * (1 / (1 + exp(-1.702 * x)))


fn quick_gelu_tensor(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """Apply QuickGELU activation to a tensor."""
    var output = Tensor[DType.float16](x.shape())
    
    let total_elements = x.num_elements()
    
    @parameter
    fn apply_quick_gelu[width: Int](i: Int):
        let vals = x.load[width=width](i)
        let sigmoid_vals = 1 / (1 + exp(-1.702 * vals))
        output.store[width=width](i, vals * sigmoid_vals)
    
    vectorize[apply_quick_gelu, SIMD_WIDTH](total_elements)
    
    return output


# ==============================================
# Activation Registry
# ==============================================

struct ActivationType:
    """Enum-like struct for activation types."""
    alias SILU = 0
    alias GELU = 1
    alias GELU_TANH = 2
    alias GELU_NEW = 3
    alias RELU = 4
    alias QUICK_GELU = 5


fn get_activation(
    x: Tensor[DType.float16],
    activation_type: Int,
) -> Tensor[DType.float16]:
    """
    Apply activation function based on type.
    
    This is useful for model configs that specify activation by name.
    """
    if activation_type == ActivationType.SILU:
        return silu_tensor(x)
    elif activation_type == ActivationType.GELU:
        return gelu_tensor(x, approximate=False)
    elif activation_type == ActivationType.GELU_TANH:
        return gelu_tensor(x, approximate=True)
    elif activation_type == ActivationType.GELU_NEW:
        return gelu_new_tensor(x)
    elif activation_type == ActivationType.RELU:
        return relu_tensor(x)
    elif activation_type == ActivationType.QUICK_GELU:
        return quick_gelu_tensor(x)
    else:
        # Default to SiLU
        return silu_tensor(x)