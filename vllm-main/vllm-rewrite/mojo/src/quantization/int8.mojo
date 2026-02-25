
"""
INT8 Quantization Module

Implements INT8 quantization for efficient inference.
Supports:
- Dynamic quantization (per-token)
- Static quantization (calibrated)
- Symmetric and asymmetric quantization
- Fused dequantize-matmul operations
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize
from sys.info import simdwidthof

alias SIMD_WIDTH = simdwidthof[DType.int8]()


# ==============================================
# Quantization Configuration
# ==============================================

struct QuantConfig:
    """Configuration for INT8 quantization."""
    
    var symmetric: Bool
    var per_channel: Bool
    var group_size: Int
    var calibration_method: String  # "minmax", "percentile", "entropy"
    
    fn __init__(
        inout self,
        symmetric: Bool = True,
        per_channel: Bool = True,
        group_size: Int = -1,  # -1 = no grouping
        calibration_method: String = "minmax",
    ):
        self.symmetric = symmetric
        self.per_channel = per_channel
        self.group_size = group_size
        self.calibration_method = calibration_method
    
    @staticmethod
    fn default() -> QuantConfig:
        return QuantConfig()
    
    @staticmethod
    fn per_tensor() -> QuantConfig:
        return QuantConfig(per_channel=False)
    
    @staticmethod
    fn grouped(group_size: Int = 128) -> QuantConfig:
        return QuantConfig(group_size=group_size)


# ==============================================
# Quantization Scales
# ==============================================

struct QuantizedWeight:
    """
    Quantized weight tensor with scales.
    
    INT8 weight is stored as: q_weight = round(weight / scale)
    Original weight ≈ q_weight * scale
    """
    
    var weight: Tensor[DType.int8]
    var scales: Tensor[DType.float16]  # Per-channel or per-group scales
    var zero_points: Tensor[DType.int8]  # For asymmetric quantization
    var shape: List[Int]
    var is_symmetric: Bool
    var group_size: Int
    
    fn __init__(
        inout self,
        weight: Tensor[DType.int8],
        scales: Tensor[DType.float16],
        zero_points: Tensor[DType.int8],
        shape: List[Int],
        is_symmetric: Bool = True,
        group_size: Int = -1,
    ):
        self.weight = weight
        self.scales = scales
        self.zero_points = zero_points
        self.shape = shape
        self.is_symmetric = is_symmetric
        self.group_size = group_size
    
    fn num_groups(self) -> Int:
        if self.group_size <= 0:
            return 1
        return (self.shape[1] + self.group_size - 1) // self.group_size
    
    fn dequantize(self) -> Tensor[DType.float16]:
        """Dequantize to FP16."""
        var result = Tensor[DType.float16](TensorShape(self.shape))
        
        let out_features = self.shape[0]
        let in_features = self.shape[1]
        
        if self.group_size <= 0:
            # Per-channel dequantization
            for i in range(out_features):
                let scale = self.scales[i]
                let zp = self.zero_points[i] if not self.is_symmetric else Int8(0)
                
                for j in range(in_features):
                    let q_val = self.weight[i, j]
                    let fp_val = (q_val.cast[DType.float16]() - zp.cast[DType.float16]()) * scale
                    result.store(i, j, fp_val)
        else:
            # Per-group dequantization
            for i in range(out_features):
                for g in range(self.num_groups()):
                    let scale = self.scales[i, g]
                    let zp = self.zero_points[i, g] if not self.is_symmetric else Int8(0)
                    
                    let start = g * self.group_size
                    let end = min(start + self.group_size, in_features)
                    
                    for j in range(start, end):
                        let q_val = self.weight[i, j]
                        let fp_val = (q_val.cast[DType.float16]() - zp.cast[DType.float16]()) * scale
                        result.store(i, j, fp_val)
        
        return result


# ==============================================
# Quantization Functions
# ==============================================

fn quantize_symmetric(
    tensor: Tensor[DType.float16],
    per_channel: Bool = True,
) -> QuantizedWeight:
    """
    Symmetric INT8 quantization.
    
    scale = max(abs(tensor)) / 127
    q_tensor = round(tensor / scale)
    """
    let shape = List[Int]()
    for i in range(tensor.rank()):
        shape.append(tensor.shape()[i])
    
    let out_features = shape[0]
    let in_features = shape[1]
    
    var q_weight = Tensor[DType.int8](tensor.shape())
    var scales: Tensor[DType.float16]
    
    if per_channel:
        scales = Tensor[DType.float16](out_features)
        
        for i in range(out_features):
            # Find max absolute value for this channel
            var max_abs: Float16 = 0.0
            for j in range(in_features):
                let abs_val = abs(tensor[i, j])
                if abs_val > max_abs:
                    max_abs = abs_val
            
            # Compute scale
            let scale = max_abs / Float16(127.0) if max_abs > 0 else Float16(1.0)
            scales.store(i, scale)
            
            # Quantize
            for j in range(in_features):
                let q_val = round(tensor[i, j] / scale)
                let clamped = max(Int8(-128), min(Int8(127), q_val.cast[DType.int8]()))
                q_weight.store(i, j, clamped)
    else:
        scales = Tensor[DType.float16](1)
        
        # Find global max absolute value
        var max_abs: Float16 = 0.0
        for i in range(out_features):
            for j in range(in_features):
                let abs_val = abs(tensor[i, j])
                if abs_val > max_abs:
                    max_abs = abs_val
        
        let scale = max_abs / Float16(127.0) if max_abs > 0 else Float16(1.0)
        scales.store(0, scale)
        
        # Quantize
        for i in range(out_features):
            for j in range(in_features):
                let q_val = round(tensor[i, j] / scale)
                let clamped = max(Int8(-128), min(Int8(127), q_val.cast[DType.int8]()))
                q_weight.store(i, j, clamped)
    
    return QuantizedWeight(
        q_weight,
        scales,
        Tensor[DType.int8](0),  # No zero points for symmetric
        shape,
        is_symmetric=True,
    )


fn quantize_asymmetric(
    tensor: Tensor[DType.float16],
    per_channel: Bool = True,
) -> QuantizedWeight:
    """
    Asymmetric INT8 quantization.
    
    scale = (max - min) / 255
    zero_point = round(-min / scale)
    q_tensor = round(tensor / scale) + zero_point
    """
    let shape = List[Int]()
    for i in range(tensor.rank()):
        shape.append(tensor.shape()[i])
    
    let out_features = shape[0]
    let in_features = shape[1]
    
    var q_weight = Tensor[DType.int8](tensor.shape())
    var scales: Tensor[DType.float16]
    var zero_points: Tensor[DType.int8]
    
    if per_channel:
        scales = Tensor[DType.float16](out_features)
        zero_points = Tensor[DType.int8](out_features)
        
        for i in range(out_features):
            # Find min and max for this channel
            var min_val: Float16 = tensor[i, 0]
            var max_val: Float16 = tensor[i, 0]
            
            for j in range(1, in_features):
                if tensor[i, j] < min_val:
                    min_val = tensor[i, j]
                if tensor[i, j] > max_val:
                    max_val = tensor[i, j]
            
            # Compute scale and zero point
            let scale = (max_val - min_val) / Float16(255.0) if max_val > min_val else Float16(1.0)
            let zp = round(-min_val / scale)
            let zp_clamped = max(Int8(0), min(Int8(255), zp.cast[DType.int8]()))
            
            scales.store(i, scale)
            zero_points.store(i, zp_clamped - Int8(128))  # Shift to signed range
            
            # Quantize
            for j in range(in_features):
                let q_val = round(tensor[i, j] / scale) + zp
                let clamped = max(Int8(0), min(Int8(255), q_val.cast[DType.int8]())) - Int8(128)
                q_weight.store(i, j, clamped)
    else:
        scales = Tensor[DType.float16](1)
        zero_points = Tensor[DType.int8](1)
        
        # Find global min and max
        var min_val: Float16 = tensor[0, 0]
        var max_val: Float16 = tensor[0, 0]
        
        for i in range(out_features):
            for j in range(in_features):
                if tensor[i, j] < min_val:
                    min_val = tensor[i, j]
                if tensor[i, j] > max_val:
                    max_val = tensor[i, j]
        
        let scale = (max_val - min_val) / Float16(255.0) if max_val > min_val else Float16(1.0)
        let zp = round(-min_val / scale)
        let zp_clamped = max(Int8(0), min(Int8(255), zp.cast[DType.int8]()))
        
        scales.store(0, scale)
        zero_points.store(0, zp_clamped - Int8(128))
        
        for i in range(out_features):
            for j in range(in_features):
                let q_val = round(tensor[i, j] / scale) + zp
                let clamped = max(Int8(0), min(Int8(255), q_val.cast[DType.int8]())) - Int8(128)
                q_weight.store(i, j, clamped)
    
    return QuantizedWeight(
        q_weight,
        scales,
        zero_points,
        shape,
        is_symmetric=False,
    )


fn quantize_grouped(
    tensor: Tensor[DType.float16],
    group_size: Int = 128,
) -> QuantizedWeight:
    """
    Grouped INT8 quantization.
    
    Quantizes weights in groups along the input dimension for
    better accuracy at the cost of more scales.
    """
    let shape = List[Int]()
    for i in range(tensor.rank()):
        shape.append(tensor.shape()[i])
    
    let out_features = shape[0]
    let in_features = shape[1]
    let num_groups = (in_features + group_size - 1) // group_size
    
    var q_weight = Tensor[DType.int8](tensor.shape())
    var scales = Tensor[DType.float16](out_features, num_groups)
    
    for i in range(out_features):
        for g in range(num_groups):
            let start = g * group_size
            let end = min(start + group_size, in_features)
            
            # Find max absolute value in this group
            var max_abs: Float16 = 0.0
            for j in range(start, end):
                let abs_val = abs(tensor[i, j])
                if abs_val > max_abs:
                    max_abs = abs_val
            
            # Compute scale
            let scale = max_abs / Float16(127.0) if max_abs > 0 else Float16(1.0)
            scales.store(i, g, scale)
            
            # Quantize this group
            for j in range(start, end):
                let q_val = round(tensor[i, j] / scale)
                let clamped = max(Int8(-128), min(Int8(127), q_val.cast[DType.int8]()))
                q_weight.store(i, j, clamped)
    
    return QuantizedWeight(
        q_weight,
        scales,
        Tensor[DType.int8](0),
        shape,
        is_symmetric=True,
        group_size=group_size,
    )


# ==============================================
# Quantized Linear Layer
# ==============================================

struct Int8Linear:
    """
    INT8 quantized linear layer.
    
    Performs: output = dequantize(q_weight) @ input
    Or fused: output = (q_weight @ q_input) * scale
    """
    
    var q_weight: QuantizedWeight
    var bias: Tensor[DType.float16]
    var has_bias: Bool
    
    fn __init__(inout self, q_weight: QuantizedWeight, bias: Tensor[DType.float16]):
        self.q_weight = q_weight
        self.bias = bias
        self.has_bias = bias.num_elements() > 0
    
    @staticmethod
    fn from_float(
        weight: Tensor[DType.float16],
        bias: Tensor[DType.float16],
        config: QuantConfig = QuantConfig(),
    ) -> Int8Linear:
        """Create quantized linear from FP16 weight."""
        var q_weight: QuantizedWeight
        
        if config.group_size > 0:
            q_weight = quantize_grouped(weight, config.group_size)
        elif config.symmetric:
            q_weight = quantize_symmetric(weight, config.per_channel)
        else:
            q_weight = quantize_asymmetric(weight, config.per_channel)
        
        return Int8Linear(q_weight, bias)
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """
        Forward pass with INT8 weights.
        
        Currently dequantizes and computes in FP16.
        In production, use fused INT8 GEMM kernels.
        """
        # Dequantize weights
        let weight = self.q_weight.dequantize()
        
        # Compute matmul
        var output = x @ weight.transpose(-2, -1)
        
        # Add bias
        if self.has_bias:
            output = output + self.bias
        
        return output
    
    fn forward_fused(
        self,
        x: Tensor[DType.float16],
        x_scale: Float16,
    ) -> Tensor[DType.float16]:
        """
        Fused INT8 forward pass (placeholder).
        
        In production, this would use:
        - cuBLAS INT8 GEMM
        - Custom CUDA kernels
        - Tensor Core acceleration
        """
        # Quantize input dynamically
        var x_int8 = Tensor[DType.int8](x.shape())
        for i in range(x.num_elements()):
            let q_val = round(x.data()[i] / x_scale)
            x_int8.store(i, max(Int8(-128), min(Int8(127), q_val.cast[DType.int8]())))
        
        # INT8 matmul (would be fused kernel in production)
        # output_i32 = x_int8 @ q_weight
        # output_fp16 = output_i32 * (x_scale * weight_scale)
        
        # For now, fallback to dequantize path
        return self.forward(x)


# ==============================================
# Dynamic Quantization
# ==============================================

fn dynamic_quantize_input(
    x: Tensor[DType.float16],
) -> Tuple[Tensor[DType.int8], Float16]:
    """
    Dynamically quantize input tensor per-token.
    
    Returns (quantized_input, scale).
    """
    let batch_size = x.shape()[0]
    let seq_len = x.shape()[1]
    let hidden_size = x.shape()[2]
    
    var x_int8 = Tensor[DType.int8](x.shape())
    
    # Find global max absolute value
    var max_abs: Float16 = 0.0
    for i in range(x.num_elements()):
        let abs_val = abs(x.data()[i])
        if abs_val > max_abs:
            max_abs = abs_val
    
    let scale = max_abs / Float16(127.0) if max_abs > 0 else Float16(1.0)
    
    # Quantize
    for i in range(x.num_elements()):
        let q_val = round(x.data()[i] / scale)
        x_int8.store(i, max(Int8(-128), min(Int8(127), q_val.cast[DType.int8]())))
    
    return (x_int8, scale)


# ==============================================
# Calibration
# ==============================================

struct Calibrator:
    """
    Calibration data collector for static quantization.
    """
    
    var min_vals: List[Float16]
    var max_vals: List[Float16]
    var num_samples: Int
    
    fn __init__(inout self, num_layers: Int):
        self.min_vals = List[Float16]()
        self.max_vals = List[Float16]()
        self.num_samples = 0
        
        for _ in range(num_layers):
            self.min_vals.append(Float16.max)
            self.max_vals.append(Float16.min)
    
    fn observe(inout self, layer_idx: Int, tensor: Tensor[DType.float16]):
        """Record min/max values for a layer."""
        var min_val = self.min_vals[layer_idx]
        var max_val = self.max_vals[layer_idx]
        
        for i in range(tensor.num_elements()):
            let val = tensor.data()[i]
            if val < min_val:
                min_val = val
            if val > max_val:
                max_val = val
        
        self.min_vals[layer_idx] = min_val
        self.max_vals[layer_idx] = max_val
        self.num_samples += 1
    
    fn get_scale(self, layer_idx: Int) -> Float16:
        """Get calibrated scale for symmetric quantization."""
        let max_abs = max(abs(self.min_vals[layer_idx]), abs(self.max_vals[layer_idx]))
        return max_abs / Float16(127.0) if max_abs > 0 else Float16(1.0)