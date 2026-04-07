# ONNX Weight Bridge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete the ONNX weight bridge so ONNX models load into TransformerWeights and run through the existing Mojo inference pipeline.

**Architecture:** Extend `loadFromONNX()` in `llama.zig` with a data-driven tensor name mapping registry, INT8 dequantization kernels, quantization metadata extraction via a StringHashMap lookup, and enhanced architecture detection from ONNX ModelProto metadata. All weights dequant to f32 into the existing `TransformerWeights` struct — no Mojo-side changes.

**Tech Stack:** Zig 0.15, ONNX protobuf format, existing Zig test harness via `cd zig && zig build test`

**Design doc:** `docs/plans/2026-02-25-onnx-weight-bridge-design.md`

---

### Task 1: INT8 Dequantization Kernels — Tests

**Files:**
- Modify: `zig/deps/llama/llama.zig` (append tests after line 3170)

**Step 1: Write failing tests for all three INT8 dequant functions**

Append at end of file:

```zig
test "dequantINT8PerTensor basic" {
    // 4 uint8 values with scale=0.5, zero_point=128
    // Formula: (val - zp) * scale
    const src = [_]u8{ 130, 128, 126, 0 };
    var dst: [4]f32 = undefined;
    dequantINT8PerTensor(&dst, &src, 4, 0.5, 128);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[0], 0.001);   // (130-128)*0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[1], 0.001);   // (128-128)*0.5
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[2], 0.001);  // (126-128)*0.5
    try std.testing.expectApproxEqAbs(@as(f32, -64.0), dst[3], 0.001); // (0-128)*0.5
}

test "dequantINT8PerChannel 2x3 matrix" {
    // 2 rows, 3 cols. Row 0: scale=0.1, zp=100. Row 1: scale=0.2, zp=50.
    const src = [_]u8{ 100, 110, 90, 50, 55, 45 };
    const scales = [_]f32{ 0.1, 0.2 };
    const zps = [_]u8{ 100, 50 };
    var dst: [6]f32 = undefined;
    dequantINT8PerChannel(&dst, &src, 2, 3, &scales, &zps);
    // Row 0: (100-100)*0.1=0, (110-100)*0.1=1.0, (90-100)*0.1=-1.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[2], 0.001);
    // Row 1: (50-50)*0.2=0, (55-50)*0.2=1.0, (45-50)*0.2=-1.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dst[4], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[5], 0.001);
}

test "dequantINT8Symmetric basic" {
    // Symmetric: zp=0, so formula is just val * scale (int8 signed)
    const src = [_]u8{ 0x02, 0xFE, 0x00, 0x7F }; // 2, -2, 0, 127 as i8
    var dst: [4]f32 = undefined;
    dequantINT8Symmetric(&dst, &src, 4, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dst[0], 0.001);   // 2*0.25
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), dst[1], 0.001);  // -2*0.25
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[2], 0.001);   // 0*0.25
    try std.testing.expectApproxEqAbs(@as(f32, 31.75), dst[3], 0.001); // 127*0.25
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | head -20`
Expected: Compile error — `dequantINT8PerTensor` is not declared.

**Step 3: Commit failing tests**

```
git add zig/deps/llama/llama.zig
git commit -m "test: add INT8 dequantization kernel tests (red)"
```

---

### Task 2: INT8 Dequantization Kernels — Implementation

**Files:**
- Modify: `zig/deps/llama/llama.zig` (insert after `dequantBF16` at ~line 1186, before `loadFromSafeTensors`)

**Step 1: Implement the three dequant functions**

Insert after line 1186 (after `dequantBF16`):

```zig
// ============================================================================
// INT8 Dequantization — ONNX quantized weight support
// ============================================================================

/// Dequantize uint8 → f32 with per-tensor scale and zero point.
/// Formula: dst[i] = (cast(f32, src[i]) - cast(f32, zero_point)) * scale
fn dequantINT8PerTensor(dst: []f32, src: [*]const u8, n_elements: usize, scale: f32, zero_point: u8) void {
    const zp_f: f32 = @floatFromInt(zero_point);
    const n = @min(n_elements, dst.len);
    for (0..n) |i| {
        dst[i] = (@as(f32, @floatFromInt(src[i])) - zp_f) * scale;
    }
}

/// Dequantize uint8 → f32 with per-channel (per-row) scales and zero points.
/// Weight matrix is [rows × cols] stored row-major. Each row gets its own scale/zp.
fn dequantINT8PerChannel(dst: []f32, src: [*]const u8, rows: usize, cols: usize, scales: []const f32, zero_points: []const u8) void {
    const n = @min(rows * cols, dst.len);
    for (0..n) |i| {
        const row = i / cols;
        if (row >= scales.len) break;
        const zp_f: f32 = @floatFromInt(zero_points[row]);
        dst[i] = (@as(f32, @floatFromInt(src[i])) - zp_f) * scales[row];
    }
}

/// Dequantize int8 (signed) → f32 with per-tensor scale, zero_point = 0.
/// Fast path for dynamic quantization where weights are symmetric.
/// Formula: dst[i] = cast(f32, reinterpret_i8(src[i])) * scale
fn dequantINT8Symmetric(dst: []f32, src: [*]const u8, n_elements: usize, scale: f32) void {
    const n = @min(n_elements, dst.len);
    for (0..n) |i| {
        const signed_val: i8 = @bitCast(src[i]);
        dst[i] = @as(f32, @floatFromInt(signed_val)) * scale;
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | tail -5`
Expected: All 3 new tests pass, no regressions.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "feat: add INT8 dequantization kernels (per-tensor, per-channel, symmetric)"
```

---

### Task 3: Tensor Name Mapping Registry — Tests

**Files:**
- Modify: `zig/deps/llama/llama.zig` (append tests after Task 1 tests)

**Step 1: Write failing tests for the name mapper**

Append at end of file:

```zig
test "ONNXTensorTarget mapONNXTensorName HuggingFace patterns" {
    // HF Optimum naming convention
    const embed = mapONNXTensorName("model.embed_tokens.weight");
    try std.testing.expect(embed != null);
    try std.testing.expectEqual(ONNXWeightTarget.token_embedding, embed.?.target);
    try std.testing.expectEqual(@as(?usize, null), embed.?.layer);

    const wq = mapONNXTensorName("model.layers.5.self_attn.q_proj.weight");
    try std.testing.expect(wq != null);
    try std.testing.expectEqual(ONNXWeightTarget.wq, wq.?.target);
    try std.testing.expectEqual(@as(?usize, 5), wq.?.layer);

    const gate = mapONNXTensorName("model.layers.31.mlp.gate_proj.weight");
    try std.testing.expect(gate != null);
    try std.testing.expectEqual(ONNXWeightTarget.w_gate, gate.?.target);
    try std.testing.expectEqual(@as(?usize, 31), gate.?.layer);

    const norm = mapONNXTensorName("model.norm.weight");
    try std.testing.expect(norm != null);
    try std.testing.expectEqual(ONNXWeightTarget.final_norm, norm.?.target);

    const lm = mapONNXTensorName("lm_head.weight");
    try std.testing.expect(lm != null);
    try std.testing.expectEqual(ONNXWeightTarget.lm_head, lm.?.target);
}

test "ONNXTensorTarget mapONNXTensorName PyTorch/GPT2 patterns" {
    const embed = mapONNXTensorName("transformer.wte.weight");
    try std.testing.expect(embed != null);
    try std.testing.expectEqual(ONNXWeightTarget.token_embedding, embed.?.target);

    const wo = mapONNXTensorName("h.3.attn.c_proj.weight");
    try std.testing.expect(wo != null);
    try std.testing.expectEqual(ONNXWeightTarget.wo, wo.?.target);
    try std.testing.expectEqual(@as(?usize, 3), wo.?.layer);

    const ln = mapONNXTensorName("ln_f.weight");
    try std.testing.expect(ln != null);
    try std.testing.expectEqual(ONNXWeightTarget.final_norm, ln.?.target);
}

test "ONNXTensorTarget mapONNXTensorName unknown returns null" {
    try std.testing.expectEqual(@as(?ONNXMappingResult, null), mapONNXTensorName("random_bias_thing"));
    try std.testing.expectEqual(@as(?ONNXMappingResult, null), mapONNXTensorName(""));
}

test "ONNXTensorTarget mapONNXTensorName fused QKV detected" {
    const fused = mapONNXTensorName("h.0.attn.c_attn.weight");
    try std.testing.expect(fused != null);
    try std.testing.expectEqual(ONNXWeightTarget.fused_qkv, fused.?.target);
    try std.testing.expectEqual(@as(?usize, 0), fused.?.layer);
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | head -10`
Expected: Compile error — `mapONNXTensorName` not declared.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "test: add tensor name mapping registry tests (red)"
```

---

### Task 4: Tensor Name Mapping Registry — Implementation

**Files:**
- Modify: `zig/deps/llama/llama.zig` (insert before `loadONNXTensorToWeights` at ~line 2082, replacing nothing — the old function will be rewritten in Task 6)

**Step 1: Implement the mapping types and function**

Insert after the `ONNXTensorInfo` struct definition (~line 1757), before `parseVarint`:

```zig
/// Target weight buffer for an ONNX tensor
const ONNXWeightTarget = enum {
    token_embedding,
    lm_head,
    final_norm,
    attn_norm,
    ffn_norm,
    wq,
    wk,
    wv,
    wo,
    w_gate,
    w_up,
    w_down,
    fused_qkv, // GPT-2 style c_attn: Q, K, V concatenated
};

/// Result of mapping an ONNX tensor name to a weight target
const ONNXMappingResult = struct {
    target: ONNXWeightTarget,
    layer: ?usize, // null for global weights (embedding, final_norm, lm_head)
};

/// A single mapping rule: a list of substring patterns, and the target weight
const TensorMappingRule = struct {
    /// Substrings that must ALL appear in the tensor name (AND logic)
    patterns: []const []const u8,
    /// Substrings that must NOT appear (exclusions)
    exclude: []const []const u8 = &.{},
    target: ONNXWeightTarget,
    is_layer_tensor: bool, // true = extract layer index from name
};

/// Data-driven mapping table — checked in order, first match wins.
/// Covers HuggingFace Optimum, PyTorch, and common LLM naming conventions.
const onnx_tensor_mappings = [_]TensorMappingRule{
    // ---- Fused QKV (must come before individual Q/K/V to match first) ----
    .{ .patterns = &.{"c_attn"}, .exclude = &.{}, .target = .fused_qkv, .is_layer_tensor = true },

    // ---- Global tensors (embedding, final norm, lm_head) ----
    .{ .patterns = &.{"embed_tokens"}, .exclude = &.{}, .target = .token_embedding, .is_layer_tensor = false },
    .{ .patterns = &.{"wte"}, .exclude = &.{}, .target = .token_embedding, .is_layer_tensor = false },
    .{ .patterns = &.{"word_embedding"}, .exclude = &.{}, .target = .token_embedding, .is_layer_tensor = false },

    .{ .patterns = &.{"lm_head"}, .exclude = &.{}, .target = .lm_head, .is_layer_tensor = false },

    // Final norm — must NOT contain layer indicators
    .{ .patterns = &.{ "model.norm" }, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },
    .{ .patterns = &.{"ln_f"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },
    .{ .patterns = &.{"final_norm"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },
    .{ .patterns = &.{"final_layer_norm"}, .exclude = &.{}, .target = .final_norm, .is_layer_tensor = false },

    // ---- Per-layer attention ----
    .{ .patterns = &.{"q_proj"}, .exclude = &.{}, .target = .wq, .is_layer_tensor = true },
    .{ .patterns = &.{ "attn", "query" }, .exclude = &.{"c_attn"}, .target = .wq, .is_layer_tensor = true },
    .{ .patterns = &.{".wq."}, .exclude = &.{}, .target = .wq, .is_layer_tensor = true },

    .{ .patterns = &.{"k_proj"}, .exclude = &.{}, .target = .wk, .is_layer_tensor = true },
    .{ .patterns = &.{ "attn", "key" }, .exclude = &.{"c_attn"}, .target = .wk, .is_layer_tensor = true },
    .{ .patterns = &.{".wk."}, .exclude = &.{}, .target = .wk, .is_layer_tensor = true },

    .{ .patterns = &.{"v_proj"}, .exclude = &.{}, .target = .wv, .is_layer_tensor = true },
    .{ .patterns = &.{ "attn", "value" }, .exclude = &.{"c_attn"}, .target = .wv, .is_layer_tensor = true },
    .{ .patterns = &.{".wv."}, .exclude = &.{}, .target = .wv, .is_layer_tensor = true },

    .{ .patterns = &.{"o_proj"}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },
    .{ .patterns = &.{"out_proj"}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },
    .{ .patterns = &.{"c_proj"}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },
    .{ .patterns = &.{".wo."}, .exclude = &.{}, .target = .wo, .is_layer_tensor = true },

    // ---- Per-layer norms ----
    .{ .patterns = &.{"input_layernorm"}, .exclude = &.{}, .target = .attn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"ln_1"}, .exclude = &.{}, .target = .attn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"attn_norm"}, .exclude = &.{}, .target = .attn_norm, .is_layer_tensor = true },

    .{ .patterns = &.{"post_attention_layernorm"}, .exclude = &.{}, .target = .ffn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"ln_2"}, .exclude = &.{}, .target = .ffn_norm, .is_layer_tensor = true },
    .{ .patterns = &.{"ffn_norm"}, .exclude = &.{}, .target = .ffn_norm, .is_layer_tensor = true },

    // ---- Per-layer FFN ----
    .{ .patterns = &.{"gate_proj"}, .exclude = &.{}, .target = .w_gate, .is_layer_tensor = true },
    .{ .patterns = &.{"fc_gate"}, .exclude = &.{}, .target = .w_gate, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "w1" }, .exclude = &.{}, .target = .w_gate, .is_layer_tensor = true },

    .{ .patterns = &.{"up_proj"}, .exclude = &.{}, .target = .w_up, .is_layer_tensor = true },
    .{ .patterns = &.{"fc_up"}, .exclude = &.{}, .target = .w_up, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "w3" }, .exclude = &.{}, .target = .w_up, .is_layer_tensor = true },

    .{ .patterns = &.{"down_proj"}, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
    .{ .patterns = &.{"fc_out"}, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "fc2" }, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
    .{ .patterns = &.{ "mlp", "w2" }, .exclude = &.{}, .target = .w_down, .is_layer_tensor = true },
};

/// Map an ONNX tensor name to a weight target using the mapping table.
/// Returns null if no mapping matched (tensor will be skipped).
fn mapONNXTensorName(name: []const u8) ?ONNXMappingResult {
    if (name.len == 0) return null;

    for (onnx_tensor_mappings) |rule| {
        // Check all required patterns are present
        var all_match = true;
        for (rule.patterns) |pat| {
            if (std.mem.indexOf(u8, name, pat) == null) {
                all_match = false;
                break;
            }
        }
        if (!all_match) continue;

        // Check no exclusions match
        var excluded = false;
        for (rule.exclude) |ex| {
            if (std.mem.indexOf(u8, name, ex) != null) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        // Extract layer index if this is a per-layer tensor
        const layer: ?usize = if (rule.is_layer_tensor) extractLayerIndex(name) else null;
        if (rule.is_layer_tensor and layer == null) continue; // Layer tensor but no layer found

        return .{ .target = rule.target, .layer = layer };
    }

    return null;
}
```

**Step 2: Run tests to verify they pass**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | tail -5`
Expected: All 4 name mapping tests pass, no regressions.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "feat: add data-driven ONNX tensor name mapping registry"
```

---

### Task 5: Architecture Detection & Quant Metadata — Tests

**Files:**
- Modify: `zig/deps/llama/llama.zig` (append tests)

**Step 1: Write failing tests**

Append at end of file:

```zig
test "parseONNXModelMetadata extracts producer_name" {
    // Build a minimal ONNX ModelProto protobuf with producer_name = "optimum"
    // Field 2, wire type 2 (length-delimited), value "optimum"
    const proto = [_]u8{
        0x12, 0x07, // tag=2, wire=2, len=7
        'o', 'p', 't', 'i', 'm', 'u', 'm',
    };
    var meta = ONNXModelMeta{};
    parseONNXModelMeta(&proto, &meta);
    try std.testing.expectEqualStrings("optimum", meta.producer_name);
}

test "buildONNXTensorIndex creates lookup map" {
    const allocator = std.testing.allocator;

    var tensors = [_]ONNXTensorInfo{
        .{ .name = "weight", .dtype = .uint8, .dims = .{ 4, 4, 0, 0, 0, 0, 0, 0 }, .n_dims = 2, .n_elements = 16, .raw_data = null, .float_data = null },
        .{ .name = "weight_scale", .dtype = .float32, .dims = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 4, .raw_data = null, .float_data = null },
        .{ .name = "weight_zero_point", .dtype = .uint8, .dims = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 4, .raw_data = null, .float_data = null },
    };

    var index = try buildONNXTensorIndex(allocator, &tensors);
    defer index.deinit();

    try std.testing.expect(index.get("weight") != null);
    try std.testing.expect(index.get("weight_scale") != null);
    try std.testing.expect(index.get("weight_zero_point") != null);
    try std.testing.expect(index.get("nonexistent") == null);
}

test "lookupQuantParams finds scale and zero_point" {
    const allocator = std.testing.allocator;
    const scale_bytes = [_]u8{ 0x00, 0x00, 0x80, 0x3F }; // f32 = 1.0
    const zp_bytes = [_]u8{128};

    var tensors = [_]ONNXTensorInfo{
        .{ .name = "layer.weight", .dtype = .uint8, .dims = .{ 4, 4, 0, 0, 0, 0, 0, 0 }, .n_dims = 2, .n_elements = 16, .raw_data = null, .float_data = null },
        .{ .name = "layer.weight_scale", .dtype = .float32, .dims = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 1, .raw_data = &scale_bytes, .float_data = null },
        .{ .name = "layer.weight_zero_point", .dtype = .uint8, .dims = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .n_dims = 1, .n_elements = 1, .raw_data = &zp_bytes, .float_data = null },
    };

    var index = try buildONNXTensorIndex(allocator, &tensors);
    defer index.deinit();

    const qp = lookupQuantParams("layer.weight", &index);
    try std.testing.expect(qp != null);
    try std.testing.expect(qp.?.scale_tensor.raw_data != null);
    try std.testing.expect(qp.?.zp_tensor != null);
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | head -10`
Expected: Compile error — `ONNXModelMeta` not declared.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "test: add architecture detection and quant metadata tests (red)"
```

---

### Task 6: Architecture Detection & Quant Metadata — Implementation

**Files:**
- Modify: `zig/deps/llama/llama.zig` (insert after ONNXMappingResult/mapONNXTensorName from Task 4, before parseVarint)

**Step 1: Implement metadata types and functions**

Insert after the `mapONNXTensorName` function:

```zig
/// Metadata extracted from ONNX ModelProto envelope (not the graph)
const ONNXModelMeta = struct {
    producer_name: []const u8 = "",
    ir_version: u64 = 0,
    opset_version: u64 = 0,
};

/// Parse top-level ONNX ModelProto fields for metadata (producer_name, ir_version).
/// This is a lightweight parse — it only reads fields 1 (ir_version), 2 (producer_name),
/// and the opset_import nested message.
fn parseONNXModelMeta(data: []const u8, meta: *ONNXModelMeta) void {
    var pos: usize = 0;
    while (pos < data.len) {
        const tag = parseTag(data, &pos) catch break;
        switch (tag.field) {
            1 => { // ir_version (int64)
                if (tag.wire == .varint) {
                    meta.ir_version = parseVarint(data, &pos) catch break;
                } else {
                    skipField(data, &pos, tag.wire) catch break;
                }
            },
            2 => { // producer_name (string)
                if (tag.wire == .length_delimited) {
                    const len: usize = @intCast(parseVarint(data, &pos) catch break);
                    const end = pos + len;
                    if (end <= data.len) {
                        meta.producer_name = data[pos..end];
                    }
                    pos = end;
                } else {
                    skipField(data, &pos, tag.wire) catch break;
                }
            },
            8 => { // opset_import (repeated OperatorSetIdProto)
                if (tag.wire == .length_delimited) {
                    const len: usize = @intCast(parseVarint(data, &pos) catch break);
                    const end = pos + len;
                    // Parse nested message for version field (field 2)
                    var inner_pos = pos;
                    while (inner_pos < end) {
                        const inner_tag = parseTag(data, &inner_pos) catch break;
                        if (inner_tag.field == 2 and inner_tag.wire == .varint) {
                            meta.opset_version = parseVarint(data, &inner_pos) catch break;
                        } else {
                            skipField(data, &inner_pos, inner_tag.wire) catch break;
                        }
                    }
                    pos = end;
                } else {
                    skipField(data, &pos, tag.wire) catch break;
                }
            },
            else => skipField(data, &pos, tag.wire) catch break,
        }
    }
}

/// Quantization parameters for an ONNX INT8 weight tensor
const ONNXQuantParams = struct {
    scale_tensor: ONNXTensorInfo, // float32 scales
    zp_tensor: ?ONNXTensorInfo, // uint8/int8 zero points (null = symmetric)
};

/// Build a name → tensor lookup index from a slice of tensors.
fn buildONNXTensorIndex(allocator: Allocator, tensors: []ONNXTensorInfo) !std.StringHashMap(ONNXTensorInfo) {
    var map = std.StringHashMap(ONNXTensorInfo).init(allocator);
    for (tensors) |t| {
        if (t.name.len > 0) {
            try map.put(t.name, t);
        }
    }
    return map;
}

/// Look up quantization parameters (scale, zero_point) for a given weight tensor name.
/// Follows the ONNX Runtime convention: weight_name + "_scale" and + "_zero_point".
fn lookupQuantParams(weight_name: []const u8, index: *const std.StringHashMap(ONNXTensorInfo)) ?ONNXQuantParams {
    // Build scale key: name + "_scale"
    var scale_buf: [512]u8 = undefined;
    const scale_key = std.fmt.bufPrint(&scale_buf, "{s}_scale", .{weight_name}) catch return null;

    const scale_tensor = index.get(scale_key) orelse return null;

    // Build zero_point key: name + "_zero_point"
    var zp_buf: [512]u8 = undefined;
    const zp_key = std.fmt.bufPrint(&zp_buf, "{s}_zero_point", .{weight_name}) catch return null;

    return .{
        .scale_tensor = scale_tensor,
        .zp_tensor = index.get(zp_key),
    };
}
```

**Step 2: Run tests to verify they pass**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | tail -5`
Expected: All 3 new tests pass, no regressions.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "feat: add ONNX model metadata parsing and quantization parameter lookup"
```

---

### Task 7: Rewrite loadFromONNX with Full Bridge — Tests

**Files:**
- Modify: `zig/deps/llama/llama.zig` (append integration test)

**Step 1: Write failing integration test — synthetic ONNX roundtrip**

This test builds a minimal ONNX protobuf in memory with known weight values (HF Optimum naming, float32), loads it via `loadFromONNX`, and verifies weight buffers.

Append at end of file:

```zig
test "ONNX weight bridge roundtrip with HF naming" {
    const allocator = std.testing.allocator;

    // Build a minimal ONNX ModelProto protobuf in memory
    // Config: 1 layer, dim=4, ff=8, vocab=8, heads=2, kv_heads=2
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Helper to write protobuf fields
    const PB = struct {
        fn writeVarint(b: *std.ArrayList(u8), val: u64) !void {
            var v = val;
            while (v > 0x7F) {
                try b.append(@truncate((v & 0x7F) | 0x80));
                v >>= 7;
            }
            try b.append(@truncate(v));
        }
        fn writeTag(b: *std.ArrayList(u8), field: u32, wire: u3) !void {
            try writeVarint(b, (@as(u64, field) << 3) | wire);
        }
        fn writeString(b: *std.ArrayList(u8), field: u32, s: []const u8) !void {
            try writeTag(b, field, 2);
            try writeVarint(b, s.len);
            try b.appendSlice(s);
        }
        fn writeF32Repeated(b: *std.ArrayList(u8), field: u32, vals: []const f32) !void {
            try writeTag(b, field, 2);
            try writeVarint(b, vals.len * 4);
            for (vals) |v| {
                const bytes: [4]u8 = @bitCast(v);
                try b.appendSlice(&bytes);
            }
        }
        fn writeTensor(b: *std.ArrayList(u8), name: []const u8, dtype: i32, dims: []const i64, float_data: []const f32) !void {
            // Build TensorProto into a temp buffer
            var tmp = std.ArrayList(u8).init(b.allocator);
            defer tmp.deinit();
            // dims (field 1, varint repeated)
            for (dims) |d| {
                try writeTag(&tmp, 1, 0);
                try writeVarint(&tmp, @bitCast(d));
            }
            // data_type (field 2, varint)
            try writeTag(&tmp, 2, 0);
            try writeVarint(&tmp, @intCast(dtype));
            // float_data (field 4, packed floats)
            try writeF32Repeated(&tmp, 4, float_data);
            // name (field 8, string) — note: ONNX uses field 8 not 1 for name
            try writeString(&tmp, 8, name);

            // Write as field 5 (initializer) in GraphProto
            try writeTag(b, 5, 2);
            try writeVarint(b, tmp.items.len);
            try b.appendSlice(tmp.items);
        }
    };

    // Build GraphProto
    var graph = std.ArrayList(u8).init(allocator);
    defer graph.deinit();

    const dim: usize = 4;
    const ff: usize = 8;
    const vocab: usize = 8;

    // Make deterministic weight values: each buffer gets a unique base
    var embed_data: [vocab * dim]f32 = undefined;
    for (&embed_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.01 + 0.1;

    var norm_data: [dim]f32 = undefined;
    for (&norm_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.1 + 1.0;

    var lm_data: [dim * vocab]f32 = undefined;
    for (&lm_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.001 + 0.5;

    var wq_data: [dim * dim]f32 = undefined;
    for (&wq_data, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.01 + 0.2;

    // Write tensors with HF Optimum naming
    try PB.writeTensor(&graph, "model.embed_tokens.weight", 1, &.{ vocab, dim }, &embed_data);
    try PB.writeTensor(&graph, "model.norm.weight", 1, &.{dim}, &norm_data);
    try PB.writeTensor(&graph, "lm_head.weight", 1, &.{ dim, vocab }, &lm_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.q_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.k_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.v_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.self_attn.o_proj.weight", 1, &.{ dim, dim }, &wq_data);
    try PB.writeTensor(&graph, "model.layers.0.input_layernorm.weight", 1, &.{dim}, &norm_data);
    try PB.writeTensor(&graph, "model.layers.0.post_attention_layernorm.weight", 1, &.{dim}, &norm_data);
    try PB.writeTensor(&graph, "model.layers.0.mlp.gate_proj.weight", 1, &.{ dim, ff }, &lm_data);
    try PB.writeTensor(&graph, "model.layers.0.mlp.up_proj.weight", 1, &.{ dim, ff }, &lm_data);
    try PB.writeTensor(&graph, "model.layers.0.mlp.down_proj.weight", 1, &.{ ff, dim }, &lm_data);

    // Wrap in ModelProto: field 2 = producer_name, field 7 = graph
    try PB.writeString(&buf, 2, "optimum");
    try PB.writeTag(&buf, 7, 2);
    try PB.writeVarint(&buf, graph.items.len);
    try buf.appendSlice(graph.items);

    // Write to temp file
    const tmp_path = "/tmp/test_onnx_bridge.onnx";
    const out_file = try std.fs.cwd().createFile(tmp_path, .{});
    try out_file.writeAll(buf.items);
    out_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Load via ONNX bridge
    const model = try loadFromONNX(allocator, tmp_path);
    defer model.deinit();

    // Verify config
    try std.testing.expectEqual(@as(u32, 1), model.config.n_layers);
    try std.testing.expectEqual(@as(u32, 8), model.config.vocab_size);
    try std.testing.expectEqual(@as(u32, 4), model.config.n_embd);
    try std.testing.expect(model.loaded);
    try std.testing.expect(model.weights != null);

    // Verify embedding weights loaded correctly (first few values)
    const w = model.weights.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), w.token_embedding[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.11), w.token_embedding[1], 0.01);

    // Verify wq for layer 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), w.layers[0].wq[0], 0.01);

    // Verify forward pass produces valid output
    var cache = try KVCache.init(allocator, model.config);
    defer cache.deinit(allocator);
    const logits = model.forward(1, 0, &cache);
    try std.testing.expectEqual(@as(usize, 8), logits.len);
    for (logits) |v| {
        try std.testing.expect(!math.isNan(v));
        try std.testing.expect(!math.isInf(v));
    }
}
```

**Step 2: Run test to verify it fails (or passes if loadFromONNX already loads float32 correctly)**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | tail -10`

The existing `loadFromONNX` may partially work for float32 tensors since the old mapper handles some patterns. This test will validate whether the new mapper works end-to-end after Task 8 rewires it.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "test: add ONNX weight bridge integration test with synthetic protobuf"
```

---

### Task 8: Rewrite loadFromONNX with Full Bridge — Implementation

**Files:**
- Modify: `zig/deps/llama/llama.zig` — replace `loadFromONNX` (lines 1994-2079) and `loadONNXTensorToWeights` (lines 2082-2175) and `loadONNXDataToBuffer` (lines 2208-2219)

**Step 1: Replace the three functions with the new bridge**

Replace the existing `loadFromONNX` function (lines 1994-2079) with:

```zig
/// Load model from ONNX format with full weight bridge.
/// Supports HuggingFace Optimum, PyTorch, and custom naming conventions.
/// Handles float32, float16, bfloat16, and INT8 quantized weights.
pub fn loadFromONNX(allocator: Allocator, path: []const u8) !*Model {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size: usize = @intCast(stat.size);
    if (file_size < 8) return error.InvalidONNX;

    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    var offset: usize = 0;
    while (offset < file_size) {
        const bytes = try file.read(data[offset..]);
        if (bytes == 0) return error.UnexpectedEOF;
        offset += bytes;
    }

    var config = ModelConfig{};
    var initializers = std.ArrayList(ONNXTensorInfo).init(allocator);
    defer initializers.deinit();

    // Parse metadata from ModelProto envelope
    var meta = ONNXModelMeta{};
    parseONNXModelMeta(data, &meta);

    std.log.info("ONNX model: producer={s}, ir_version={}, opset={}", .{
        if (meta.producer_name.len > 0) meta.producer_name else "unknown",
        meta.ir_version,
        meta.opset_version,
    });

    // Parse ONNX ModelProto — extract graph initializers
    var pos: usize = 0;
    while (pos < data.len) {
        const tag = parseTag(data, &pos) catch break;
        switch (tag.field) {
            7 => { // graph (GraphProto)
                if (tag.wire == .length_delimited) {
                    const len = try parseVarint(data, &pos);
                    const graph_end = pos + @as(usize, @intCast(len));
                    if (graph_end <= data.len) {
                        try parseGraphProto(allocator, data[pos..graph_end], &config, &initializers);
                    }
                    pos = graph_end;
                } else {
                    try skipField(data, &pos, tag.wire);
                }
            },
            else => try skipField(data, &pos, tag.wire),
        }
    }

    std.log.info("ONNX parsed: {} initializers found", .{initializers.items.len});

    // Enhanced architecture detection: count layers from tensor names
    var max_layer: u32 = 0;
    var has_gate_proj = false;
    for (initializers.items) |tensor| {
        if (mapONNXTensorName(tensor.name)) |result| {
            if (result.layer) |l| {
                const layer_u32: u32 = @intCast(l);
                if (layer_u32 + 1 > max_layer) max_layer = layer_u32 + 1;
            }
            if (result.target == .w_gate) has_gate_proj = true;
        }
    }
    if (max_layer > 0) config.n_layers = max_layer;

    // Set defaults for missing config values
    if (config.n_layers == 0) config.n_layers = 32;
    if (config.n_heads == 0) config.n_heads = 32;
    if (config.n_kv_heads == 0) config.n_kv_heads = config.n_heads;
    if (config.n_embd == 0) config.n_embd = 4096;
    if (config.n_ff == 0) config.n_ff = if (has_gate_proj) config.n_embd * 4 else config.n_embd * 4;
    if (config.vocab_size == 0) config.vocab_size = 32000;
    if (config.context_length == 0) config.context_length = 4096;
    config.dim = config.n_embd;
    config.ff_dim = config.n_ff;
    config.hidden_dim = config.n_embd;

    std.log.info("ONNX config: vocab={}, n_embd={}, n_layers={}, n_heads={}, n_ff={}", .{
        config.vocab_size, config.n_embd, config.n_layers, config.n_heads, config.n_ff,
    });

    // Build tensor index for quantization parameter lookup
    var tensor_index = try buildONNXTensorIndex(allocator, initializers.items);
    defer tensor_index.deinit();

    // Allocate weights
    var weights = try TransformerWeights.allocateRaw(allocator, config);
    errdefer weights.deinit(allocator);

    // Map and load each initializer into the correct weight buffer
    var loaded_count: usize = 0;
    var skipped_count: usize = 0;
    for (initializers.items) |tensor| {
        const mapping = mapONNXTensorName(tensor.name) orelse {
            skipped_count += 1;
            continue;
        };

        // Determine destination buffer
        const dst: ?[]f32 = switch (mapping.target) {
            .token_embedding => weights.token_embedding,
            .lm_head => weights.lm_head,
            .final_norm => weights.final_norm,
            .attn_norm => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].attn_norm else null else null,
            .ffn_norm => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].ffn_norm else null else null,
            .wq => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].wq else null else null,
            .wk => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].wk else null else null,
            .wv => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].wv else null else null,
            .wo => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].wo else null else null,
            .w_gate => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].w_gate else null else null,
            .w_up => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].w_up else null else null,
            .w_down => if (mapping.layer) |l| if (l < config.n_layers) weights.layers[l].w_down else null else null,
            .fused_qkv => null, // Handled separately below
        };

        if (mapping.target == .fused_qkv) {
            if (mapping.layer) |l| {
                if (l < config.n_layers) {
                    splitFusedQKV(&weights, l, tensor, config);
                    loaded_count += 1;
                }
            }
            continue;
        }

        if (dst) |dest| {
            loadONNXDataToBuffer(dest, tensor, &tensor_index);
            loaded_count += 1;
        }
    }

    std.log.info("ONNX weights: {} loaded, {} skipped", .{ loaded_count, skipped_count });

    return try createModelWithWeights(allocator, config, weights);
}

/// Split a fused QKV tensor (GPT-2 c_attn) into separate Q, K, V weight buffers.
/// The fused tensor is [3 * hidden_dim, hidden_dim] with Q, K, V stacked along dim 0.
fn splitFusedQKV(weights: *TransformerWeights, layer: usize, tensor: ONNXTensorInfo, config: ModelConfig) void {
    const src: ?[*]const u8 = if (tensor.raw_data) |rd| rd.ptr else if (tensor.float_data) |fd| @ptrCast(fd.ptr) else null;
    if (src == null) return;
    const src_ptr = src.?;

    const dim: usize = config.n_embd;
    const n_heads: usize = config.n_heads;
    const n_kv_heads: usize = config.n_kv_heads;
    const head_dim = dim / n_heads;
    const q_size = n_heads * head_dim * dim;
    const k_size = n_kv_heads * head_dim * dim;
    const v_size = k_size;

    const bytes_per_elem = tensor.dtype.bytesPerElement();

    // Q: rows [0, q_size)
    loadONNXDataToBufferRaw(weights.layers[layer].wq, src_ptr, q_size, tensor.dtype);
    // K: rows [q_size, q_size + k_size)
    const k_offset = q_size * bytes_per_elem;
    loadONNXDataToBufferRaw(weights.layers[layer].wk, src_ptr + k_offset, k_size, tensor.dtype);
    // V: rows [q_size + k_size, q_size + k_size + v_size)
    const v_offset = (q_size + k_size) * bytes_per_elem;
    loadONNXDataToBufferRaw(weights.layers[layer].wv, src_ptr + v_offset, v_size, tensor.dtype);
}
```

Replace the existing `loadONNXTensorToWeights` (lines 2082-2175) and `loadONNXDataToBuffer` (lines 2208-2219) with:

```zig
/// Load ONNX tensor data into a weight buffer, handling float and INT8 quantized types.
/// For INT8 tensors, looks up scale/zero_point from the tensor index.
fn loadONNXDataToBuffer(dst: []f32, tensor: ONNXTensorInfo, tensor_index: *const std.StringHashMap(ONNXTensorInfo)) void {
    const src: ?[*]const u8 = if (tensor.raw_data) |rd| rd.ptr else if (tensor.float_data) |fd| @ptrCast(fd.ptr) else null;
    if (src == null) return;
    const src_ptr = src.?;
    const n_elem = tensor.n_elements;

    switch (tensor.dtype) {
        .float32 => dequantF32(dst, src_ptr, @min(n_elem, dst.len)),
        .float16 => dequantF16(dst, src_ptr, @min(n_elem, dst.len)),
        .bfloat16 => dequantBF16(dst, src_ptr, @min(n_elem, dst.len)),
        .uint8 => {
            // INT8 asymmetric quantization — look up scale and zero_point
            if (lookupQuantParams(tensor.name, tensor_index)) |qp| {
                const scales = extractF32Slice(qp.scale_tensor);
                if (scales.len == 0) {
                    fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
                    return;
                }
                if (scales.len == 1) {
                    // Per-tensor quantization
                    const zp: u8 = if (qp.zp_tensor) |zpt| if (zpt.raw_data) |rd| rd[0] else 0 else 0;
                    dequantINT8PerTensor(dst, src_ptr, @min(n_elem, dst.len), scales[0], zp);
                } else {
                    // Per-channel quantization
                    const zp_data: ?[]const u8 = if (qp.zp_tensor) |zpt| zpt.raw_data else null;
                    const zps = zp_data orelse &[_]u8{0} ** 1;
                    const rows = scales.len;
                    const cols = if (rows > 0) n_elem / rows else n_elem;
                    dequantINT8PerChannel(dst, src_ptr, rows, cols, scales, zps);
                }
            } else {
                std.log.warn("ONNX: INT8 tensor '{s}' has no quantization params, skipping", .{tensor.name});
                fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
            }
        },
        .int8 => {
            // INT8 symmetric quantization — look up scale
            if (lookupQuantParams(tensor.name, tensor_index)) |qp| {
                const scales = extractF32Slice(qp.scale_tensor);
                if (scales.len >= 1) {
                    dequantINT8Symmetric(dst, src_ptr, @min(n_elem, dst.len), scales[0]);
                } else {
                    fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
                }
            } else {
                std.log.warn("ONNX: int8 tensor '{s}' has no quantization params, skipping", .{tensor.name});
                fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
            }
        },
        else => {
            std.log.warn("ONNX: unsupported dtype for tensor '{s}', filling with random", .{tensor.name});
            fillDeterministic(dst[0..@min(n_elem, dst.len)], 0.02);
        },
    }
}

/// Raw version for split QKV — takes src pointer directly without tensor index lookup.
fn loadONNXDataToBufferRaw(dst: []f32, src: [*]const u8, n_elements: usize, dtype: ONNXDataType) void {
    const n = @min(n_elements, dst.len);
    switch (dtype) {
        .float32 => dequantF32(dst, src, n),
        .float16 => dequantF16(dst, src, n),
        .bfloat16 => dequantBF16(dst, src, n),
        else => fillDeterministic(dst[0..n], 0.02),
    }
}

/// Extract a f32 slice from an ONNXTensorInfo (from raw_data or float_data).
fn extractF32Slice(tensor: ONNXTensorInfo) []const f32 {
    if (tensor.float_data) |fd| return fd;
    if (tensor.raw_data) |rd| {
        if (rd.len >= 4) {
            const n = rd.len / 4;
            return @as([*]const f32, @ptrCast(@alignCast(rd.ptr)))[0..n];
        }
    }
    return &.{};
}
```

**Step 2: Run all tests to verify they pass**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | tail -10`
Expected: All tests pass — dequant unit tests, name mapping tests, metadata tests, ONNX roundtrip integration test, and all existing GGUF/model tests.

**Step 3: Commit**

```
git add zig/deps/llama/llama.zig
git commit -m "feat: complete ONNX weight bridge with INT8 dequant, name mapping, and quant metadata"
```

---

### Task 9: Final Verification — Run Full Test Suite

**Files:** None (test-only)

**Step 1: Run the complete test suite**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm && make test-zig`
Expected: All tests pass.

**Step 2: Verify no regressions in existing tests**

Run: `cd /Users/user/Documents/sap-ai-suite/src/intelligence/ai-core-privatellm/zig && zig build test 2>&1 | grep -E "(PASS|FAIL|error)" | tail -20`
Expected: Only PASS lines, no FAIL or error.

**Step 3: Final commit (if any fixups were needed)**

If all clean, no commit needed. If fixups were required, commit them:

```
git add zig/deps/llama/llama.zig
git commit -m "fix: address test failures in ONNX weight bridge"
```
