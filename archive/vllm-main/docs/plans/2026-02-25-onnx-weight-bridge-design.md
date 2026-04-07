# ONNX Weight Bridge Design

## Problem

The ONNX parser in `llama.zig` (lines 1700-2235) can parse protobuf and extract
initializer tensors, but cannot produce usable inference weights because:

1. Tensor name mapping is fragile (hardcoded `indexOf` patterns, misses many conventions)
2. INT8 quantized ONNX models fall through to `fillDeterministic()` (garbage weights)
3. No extraction of quantization scales/zero-points from companion initializers
4. Architecture detection from tensor shapes is heuristic-only

## Approach

Direct weight bridge in `llama.zig` — extend the existing `loadFromONNX()` path
with a data-driven name mapper, INT8 dequant kernels, and quantization metadata
extraction. Weights load into the existing `TransformerWeights` struct and flow
through the Mojo inference pipeline unchanged.

## Components

### 1. Tensor Name Mapping Registry

Replace hardcoded `indexOf` calls in `loadONNXTensorToWeights()` with a const
array of `TensorMapping` structs.

Supported naming conventions:

| Target Weight       | HF Optimum                                      | PyTorch / GPT-2         |
|---------------------|------------------------------------------------|-------------------------|
| token_embedding     | model.embed_tokens.weight                      | transformer.wte.weight  |
| layers[L].wq        | model.layers.L.self_attn.q_proj.weight         | h.L.attn.c_attn (split) |
| layers[L].wk        | model.layers.L.self_attn.k_proj.weight         | h.L.attn.c_attn (split) |
| layers[L].wv        | model.layers.L.self_attn.v_proj.weight         | h.L.attn.c_attn (split) |
| layers[L].wo        | model.layers.L.self_attn.o_proj.weight         | h.L.attn.c_proj.weight  |
| layers[L].w_gate    | model.layers.L.mlp.gate_proj.weight            | h.L.mlp.w1.weight       |
| layers[L].w_up      | model.layers.L.mlp.up_proj.weight              | h.L.mlp.w3.weight       |
| layers[L].w_down    | model.layers.L.mlp.down_proj.weight            | h.L.mlp.w2.weight       |
| layers[L].attn_norm | model.layers.L.input_layernorm.weight          | h.L.ln_1.weight         |
| layers[L].ffn_norm  | model.layers.L.post_attention_layernorm.weight | h.L.ln_2.weight         |
| final_norm          | model.norm.weight                              | ln_f.weight             |
| lm_head             | lm_head.weight                                 | (tied to embedding)     |

Fused QKV tensors (GPT-2 `c_attn`) are split along dim 0 into Q, K, V using
`n_heads` and `n_kv_heads` from the inferred config.

Unknown tensors are logged at info level and skipped (not errors).

### 2. INT8 Dequantization Kernels

New functions in `llama.zig`:

- `dequantINT8PerTensor(dst, src, n, scale, zero_point)` — single scale/zp
- `dequantINT8PerChannel(dst, src, rows, cols, scales, zero_points)` — per-row
- `dequantINT8Symmetric(dst, src, n, scale)` — zero_point=0 fast path

Formula: `dst[i] = (cast(f32, src[i]) - cast(f32, zero_point)) * scale`

All convert to f32 into the existing `TransformerWeights` buffers.

### 3. Quantization Metadata Extraction

ONNX quantized models store scales/zero-points as separate initializers:

- Weight: `*.weight` (uint8/int8)
- Scale: `*.weight_scale` (float32)
- Zero point: `*.weight_zero_point` (uint8/int8)

The loader builds a `StringHashMap(ONNXTensorInfo)` from all initializers, then
for each INT8 weight tensor looks up the companion `_scale` and `_zero_point`
tensors. If found, uses INT8 dequant. If missing, logs a warning and skips.

### 4. Architecture Detection Enhancement

- Parse `producer_name` (field 2 in ModelProto) to select naming convention
  (optimum → HF patterns, pytorch → PyTorch patterns, fallback → try all)
- Parse `opset_import` version for compatibility checking
- Count unique layer prefixes for reliable `n_layers` detection
- Detect SwiGLU vs standard FFN from presence of `gate_proj` tensors

### 5. Inference Connection

No changes to the Mojo inference pipeline:

```
ONNX file
  -> protobuf parse (existing)
  -> initializer extraction (existing)
  -> tensor name mapping (NEW)
  -> INT8 dequant / FP32/FP16/BF16 dequant (NEW + existing)
  -> TransformerWeights (existing)
  -> createModelWithWeights() (existing)
  -> Model -> Mojo inference (existing)
```

## Files Modified

- `zig/deps/llama/llama.zig` — all ONNX bridge code lives here

## Testing

1. Unit tests: INT8 dequant kernels (per-tensor, per-channel, symmetric),
   tensor name matching for each naming convention, fused QKV splitting
2. Integration test: Synthetic ONNX protobuf with known weights -> load ->
   verify weight buffers match expected values
3. E2E smoke test: Small ONNX model -> generate tokens -> verify non-garbage
