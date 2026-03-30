const std = @import("std");
const Allocator = std.mem.Allocator;
const GGMLType = @import("../gpu/cuda_weights.zig").GGMLType;

pub const NativeMtpTensorView = struct {
    name: []const u8,
    dtype: GGMLType,
    host_data: []const u8,
    n_dims: u32 = 0,
    dims: [4]u64 = .{ 0, 0, 0, 0 },
    rows: usize,
    cols: usize,
};

const ProjectionSpec = struct {
    tensor_name: []const u8,
    dtype: GGMLType,
    host_data: []const u8,
    rows: usize,
    cols: usize,
    row_start: usize = 0,
};

const TensorSpec = struct {
    tensor_name: []const u8,
    dtype: GGMLType,
    host_data: []const u8,
    rows: usize,
    cols: usize,
};

const QwenNextNSpec = struct {
    prefix: []const u8,
    token_embedding: TensorSpec,
    lm_head: TensorSpec,
    pre_fc_norm_embedding: TensorSpec,
    pre_fc_norm_hidden: TensorSpec,
    fc: TensorSpec,
    shared_head_norm: TensorSpec,
    input_layernorm: TensorSpec,
    post_attention_layernorm: TensorSpec,
    q_proj: TensorSpec,
    q_norm: TensorSpec,
    k_proj: TensorSpec,
    k_norm: TensorSpec,
    v_proj: TensorSpec,
    o_proj: TensorSpec,
    mlp_gate: TensorSpec,
    mlp_up: TensorSpec,
    mlp_down: TensorSpec,
    num_heads: usize,
    num_kv_heads: usize,
    head_dim: usize,
    rope_dim: usize,
    rope_freq_base: f32,
    eps: f32,
};

pub const NativeMtpDrafter = struct {
    allocator: Allocator,
    hidden_size: usize,
    vocab_size: usize,
    max_positions: usize,
    projections: []?ProjectionSpec,
    qwen_nextn: ?QwenNextNSpec = null,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        hidden_size: usize,
        vocab_size: usize,
        max_positions: usize,
        n_heads: usize,
        n_kv_heads: usize,
        head_dim: usize,
        rope_dim: usize,
        rope_freq_base: f32,
        eps: f32,
        tensors: []const NativeMtpTensorView,
    ) !Self {
        const positions = @max(max_positions, 1);
        var self = Self{
            .allocator = allocator,
            .hidden_size = hidden_size,
            .vocab_size = vocab_size,
            .max_positions = positions,
            .projections = try allocator.alloc(?ProjectionSpec, positions),
            .qwen_nextn = null,
        };
        @memset(self.projections, null);
        try self.discoverProjections(tensors);
        self.qwen_nextn = self.discoverQwenNextN(
            tensors,
            n_heads,
            n_kv_heads,
            head_dim,
            rope_dim,
            rope_freq_base,
            eps,
        );
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.projections);
        self.* = undefined;
    }

    pub fn hasAny(self: *const Self) bool {
        if (self.qwen_nextn != null) return true;
        var pos: usize = 1;
        while (pos < self.projections.len) : (pos += 1) {
            if (self.projections[pos] != null) return true;
        }
        return false;
    }

    pub fn supportedPositions(self: *const Self) usize {
        if (self.qwen_nextn != null) return if (self.max_positions > 0) self.max_positions - 1 else 0;
        var total: usize = 0;
        var pos: usize = 1;
        while (pos < self.projections.len) : (pos += 1) {
            if (self.projections[pos] != null) total += 1;
        }
        return total;
    }

    pub fn maxPositions(self: *const Self) usize {
        return self.max_positions;
    }

    pub fn fillCandidates(
        self: *Self,
        hidden: []const f32,
        target_logits: []const f32,
        current_position: usize,
        out_ids: [][]u32,
        out_scores: [][]f32,
    ) !bool {
        if (out_ids.len == 0 or out_scores.len == 0) return false;
        if (out_ids.len != out_scores.len) return error.InvalidCandidateBuffers;
        if (hidden.len < self.hidden_size) return error.HiddenStateTooSmall;
        if (target_logits.len < self.vocab_size) return error.LogitsTooSmall;

        fillTopKFromLogits(target_logits[0..self.vocab_size], out_ids[0], out_scores[0]);

        const requested = @min(out_ids.len, out_scores.len);
        if (requested <= 1) return true;

        if (self.qwen_nextn) |qwen| {
            return try self.fillQwenNextNCandidates(qwen, hidden[0..self.hidden_size], current_position, out_ids, out_scores);
        }

        var pos: usize = 1;
        while (pos < requested) : (pos += 1) {
            const projection = self.projections[pos] orelse return false;
            try self.fillTopKProjection(projection, hidden[0..self.hidden_size], out_ids[pos], out_scores[pos]);
        }
        return true;
    }

    pub fn fillContinuation(
        self: *Self,
        hidden: []const f32,
        previous_token: u32,
        current_position: usize,
        out_ids: [][]u32,
        out_scores: [][]f32,
    ) !bool {
        if (out_ids.len == 0 or out_scores.len == 0) return false;
        if (out_ids.len != out_scores.len) return error.InvalidCandidateBuffers;
        if (hidden.len < self.hidden_size) return error.HiddenStateTooSmall;

        if (self.qwen_nextn) |qwen| {
            return try self.fillQwenNextNContinuation(qwen, hidden[0..self.hidden_size], previous_token, current_position, out_ids, out_scores);
        }

        const requested = @min(out_ids.len, out_scores.len);
        var idx: usize = 0;
        while (idx < requested) : (idx += 1) {
            const projection = self.projections[idx + 1] orelse return false;
            try self.fillTopKProjection(projection, hidden[0..self.hidden_size], out_ids[idx], out_scores[idx]);
        }
        return true;
    }

    fn discoverProjections(self: *Self, tensors: []const NativeMtpTensorView) !void {
        if (self.max_positions <= 1 or tensors.len == 0) return;

        const sorted = try self.allocator.alloc(NativeMtpTensorView, tensors.len);
        defer self.allocator.free(sorted);
        @memcpy(sorted, tensors);
        std.mem.sort(NativeMtpTensorView, sorted, {}, struct {
            fn lessThan(_: void, a: NativeMtpTensorView, b: NativeMtpTensorView) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        var next_free_position: usize = 1;
        for (sorted) |tensor| {
            if (std.mem.indexOf(u8, tensor.name, "mtp") == null and
                std.mem.indexOf(u8, tensor.name, "nextn") == null and
                std.mem.indexOf(u8, tensor.name, "draft") == null)
            {
                continue;
            }
            if (tensor.cols != self.hidden_size or tensor.rows < self.vocab_size) continue;

            if (tensor.rows == self.vocab_size) {
                const inferred_position = inferPositionFromName(tensor.name, self.max_positions) orelse blk: {
                    while (next_free_position < self.max_positions and self.projections[next_free_position] != null) {
                        next_free_position += 1;
                    }
                    if (next_free_position >= self.max_positions) break :blk null;
                    const chosen = next_free_position;
                    next_free_position += 1;
                    break :blk chosen;
                };

                if (inferred_position) |position| {
                    if (position < self.max_positions and self.projections[position] == null) {
                        self.projections[position] = .{
                            .tensor_name = tensor.name,
                            .dtype = tensor.dtype,
                            .host_data = tensor.host_data,
                            .rows = tensor.rows,
                            .cols = tensor.cols,
                            .row_start = 0,
                        };
                    }
                }
                continue;
            }

            if (tensor.rows % self.vocab_size != 0) continue;

            const stacked_positions = @min(tensor.rows / self.vocab_size, self.max_positions - 1);
            for (0..stacked_positions) |idx| {
                const position = idx + 1;
                if (self.projections[position] != null) continue;
                self.projections[position] = .{
                    .tensor_name = tensor.name,
                    .dtype = tensor.dtype,
                    .host_data = tensor.host_data,
                    .rows = tensor.rows,
                    .cols = tensor.cols,
                    .row_start = idx * self.vocab_size,
                };
            }
        }
    }

    fn discoverQwenNextN(
        self: *const Self,
        tensors: []const NativeMtpTensorView,
        explicit_n_heads: usize,
        explicit_n_kv_heads: usize,
        explicit_head_dim: usize,
        explicit_rope_dim: usize,
        rope_freq_base: f32,
        eps: f32,
    ) ?QwenNextNSpec {
        if (self.max_positions <= 1) return null;

        const prefix = blk: {
            for (tensors) |tensor| {
                const suffix = ".nextn.eh_proj.weight";
                if (std.mem.endsWith(u8, tensor.name, suffix)) {
                    break :blk tensor.name[0 .. tensor.name.len - suffix.len];
                }
            }
            break :blk null;
        } orelse return null;

        const token_embedding = findTensorByName(tensors, "token_embd.weight") orelse return null;
        const fc = findTensorFmt(tensors, "{s}.nextn.eh_proj.weight", .{prefix}) orelse return null;
        const pre_fc_norm_embedding = findTensorFmt(tensors, "{s}.nextn.enorm.weight", .{prefix}) orelse return null;
        const pre_fc_norm_hidden = findTensorFmt(tensors, "{s}.nextn.hnorm.weight", .{prefix}) orelse return null;
        const shared_head_norm = findTensorFmt(tensors, "{s}.nextn.shared_head_norm.weight", .{prefix}) orelse return null;
        const input_layernorm = findTensorFmt(tensors, "{s}.attn_norm.weight", .{prefix}) orelse return null;
        const post_attention_layernorm = findTensorFmt(tensors, "{s}.ffn_norm.weight", .{prefix}) orelse return null;
        const q_proj = findTensorFmt(tensors, "{s}.attn_q.weight", .{prefix}) orelse return null;
        const q_norm = findTensorFmt(tensors, "{s}.attn_q_norm.weight", .{prefix}) orelse return null;
        const k_proj = findTensorFmt(tensors, "{s}.attn_k.weight", .{prefix}) orelse return null;
        const k_norm = findTensorFmt(tensors, "{s}.attn_k_norm.weight", .{prefix}) orelse return null;
        const v_proj = findTensorFmt(tensors, "{s}.attn_v.weight", .{prefix}) orelse return null;
        const o_proj = findTensorFmt(tensors, "{s}.attn_output.weight", .{prefix}) orelse return null;
        const mlp_gate = findTensorFmt(tensors, "{s}.ffn_gate.weight", .{prefix}) orelse return null;
        const mlp_up = findTensorFmt(tensors, "{s}.ffn_up.weight", .{prefix}) orelse return null;
        const mlp_down = findTensorFmt(tensors, "{s}.ffn_down.weight", .{prefix}) orelse return null;

        const head_dim = if (explicit_head_dim > 0) explicit_head_dim else q_norm.cols;
        if (head_dim == 0) return null;

        const q_total = q_proj.rows / 2;
        const inferred_n_heads = if (explicit_n_heads > 0) explicit_n_heads else q_total / head_dim;
        const inferred_n_kv_heads = if (explicit_n_kv_heads > 0) explicit_n_kv_heads else k_proj.rows / head_dim;
        const inferred_rope_dim = if (explicit_rope_dim > 0) explicit_rope_dim else head_dim;

        if (fc.cols != self.hidden_size * 2) return null;
        if (fc.rows != self.hidden_size) return null;
        if (pre_fc_norm_embedding.cols != self.hidden_size or pre_fc_norm_hidden.cols != self.hidden_size) return null;
        if (q_total != inferred_n_heads * head_dim) return null;
        if (k_proj.rows != inferred_n_kv_heads * head_dim) return null;
        if (v_proj.rows != inferred_n_kv_heads * head_dim) return null;
        if (o_proj.cols != inferred_n_heads * head_dim) return null;
        if (o_proj.rows != self.hidden_size) return null;
        if (shared_head_norm.cols != self.hidden_size) return null;

        const lm_head = findTensorByName(tensors, "output.weight") orelse token_embedding;

        return .{
            .prefix = prefix,
            .token_embedding = asTensorSpec(token_embedding),
            .lm_head = asTensorSpec(lm_head),
            .pre_fc_norm_embedding = asTensorSpec(pre_fc_norm_embedding),
            .pre_fc_norm_hidden = asTensorSpec(pre_fc_norm_hidden),
            .fc = asTensorSpec(fc),
            .shared_head_norm = asTensorSpec(shared_head_norm),
            .input_layernorm = asTensorSpec(input_layernorm),
            .post_attention_layernorm = asTensorSpec(post_attention_layernorm),
            .q_proj = asTensorSpec(q_proj),
            .q_norm = asTensorSpec(q_norm),
            .k_proj = asTensorSpec(k_proj),
            .k_norm = asTensorSpec(k_norm),
            .v_proj = asTensorSpec(v_proj),
            .o_proj = asTensorSpec(o_proj),
            .mlp_gate = asTensorSpec(mlp_gate),
            .mlp_up = asTensorSpec(mlp_up),
            .mlp_down = asTensorSpec(mlp_down),
            .num_heads = inferred_n_heads,
            .num_kv_heads = inferred_n_kv_heads,
            .head_dim = head_dim,
            .rope_dim = @min(inferred_rope_dim, head_dim),
            .rope_freq_base = rope_freq_base,
            .eps = eps,
        };
    }

    fn fillQwenNextNCandidates(
        self: *Self,
        spec: QwenNextNSpec,
        hidden: []const f32,
        current_position: usize,
        out_ids: [][]u32,
        out_scores: [][]f32,
    ) !bool {
        const requested = @min(out_ids.len, out_scores.len);
        if (requested <= 1) return true;
        if (out_ids[0].len == 0) return false;
        return self.fillQwenNextNSequence(spec, hidden, out_ids[0][0], current_position, out_ids[1..requested], out_scores[1..requested], 1);
    }

    fn fillQwenNextNContinuation(
        self: *Self,
        spec: QwenNextNSpec,
        hidden: []const f32,
        previous_token: u32,
        current_position: usize,
        out_ids: [][]u32,
        out_scores: [][]f32,
    ) !bool {
        const requested = @min(out_ids.len, out_scores.len);
        if (requested == 0) return false;
        return self.fillQwenNextNSequence(spec, hidden, previous_token, current_position, out_ids[0..requested], out_scores[0..requested], 0);
    }

    fn fillQwenNextNSequence(
        self: *Self,
        spec: QwenNextNSpec,
        hidden: []const f32,
        seed_token: u32,
        current_position: usize,
        out_ids: [][]u32,
        out_scores: [][]f32,
        position_offset: usize,
    ) !bool {
        const requested = @min(out_ids.len, out_scores.len);
        if (requested == 0) return true;
        if (out_ids[0].len == 0) return false;

        const prev_hidden = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(prev_hidden);
        @memcpy(prev_hidden, hidden[0..self.hidden_size]);

        const embed = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(embed);
        const embed_norm = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(embed_norm);
        const hidden_norm = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(hidden_norm);
        const combined = try self.allocator.alloc(f32, self.hidden_size * 2);
        defer self.allocator.free(combined);
        const draft_in = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(draft_in);
        const xnorm = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(xnorm);
        const q_proj = try self.allocator.alloc(f32, spec.q_proj.rows);
        defer self.allocator.free(q_proj);
        const k_proj = try self.allocator.alloc(f32, spec.k_proj.rows);
        defer self.allocator.free(k_proj);
        const v_proj = try self.allocator.alloc(f32, spec.v_proj.rows);
        defer self.allocator.free(v_proj);
        const attn_flat = try self.allocator.alloc(f32, spec.num_heads * spec.head_dim);
        defer self.allocator.free(attn_flat);
        const attn_mixed = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(attn_mixed);
        const mlp_norm = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(mlp_norm);
        const mlp_gate = try self.allocator.alloc(f32, spec.mlp_gate.rows);
        defer self.allocator.free(mlp_gate);
        const mlp_up = try self.allocator.alloc(f32, spec.mlp_up.rows);
        defer self.allocator.free(mlp_up);
        const mlp_out = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(mlp_out);
        const final_hidden = try self.allocator.alloc(f32, self.hidden_size);
        defer self.allocator.free(final_hidden);
        const key_cache = try self.allocator.alloc(f32, requested * spec.num_kv_heads * spec.head_dim);
        defer self.allocator.free(key_cache);
        const value_cache = try self.allocator.alloc(f32, requested * spec.num_kv_heads * spec.head_dim);
        defer self.allocator.free(value_cache);
        @memset(key_cache, 0.0);
        @memset(value_cache, 0.0);

        var prev_token = seed_token;
        var out_idx: usize = 0;
        while (out_idx < requested) : (out_idx += 1) {
            try readRow(spec.token_embedding.dtype, spec.token_embedding.host_data, prev_token, spec.token_embedding.cols, embed);
            rmsNormInto(embed_norm, embed, spec.pre_fc_norm_embedding, spec.eps);
            rmsNormInto(hidden_norm, prev_hidden, spec.pre_fc_norm_hidden, spec.eps);
            @memcpy(combined[0..self.hidden_size], embed_norm);
            @memcpy(combined[self.hidden_size..], hidden_norm);
            try applyLinear(spec.fc, combined, draft_in);

            try self.runQwenNextNLayer(
                spec,
                draft_in,
                current_position + position_offset + out_idx + 1,
                out_idx,
                key_cache,
                value_cache,
                xnorm,
                q_proj,
                k_proj,
                v_proj,
                attn_flat,
                attn_mixed,
                mlp_norm,
                mlp_gate,
                mlp_up,
                mlp_out,
                prev_hidden,
            );

            rmsNormInto(final_hidden, prev_hidden, spec.shared_head_norm, spec.eps);
            fillTopKFromWeight(spec.lm_head, final_hidden, out_ids[out_idx], out_scores[out_idx]);
            prev_token = out_ids[out_idx][0];
        }

        return true;
    }

    fn runQwenNextNLayer(
        self: *Self,
        spec: QwenNextNSpec,
        input_hidden: []const f32,
        position: usize,
        step_index: usize,
        key_cache: []f32,
        value_cache: []f32,
        xnorm: []f32,
        q_proj_buf: []f32,
        k_proj_buf: []f32,
        v_proj_buf: []f32,
        attn_flat: []f32,
        attn_mixed: []f32,
        mlp_norm: []f32,
        mlp_gate: []f32,
        mlp_up: []f32,
        mlp_out: []f32,
        out_hidden: []f32,
    ) !void {
        rmsNormInto(xnorm, input_hidden, spec.input_layernorm, spec.eps);
        try applyLinear(spec.q_proj, xnorm, q_proj_buf);
        try applyLinear(spec.k_proj, xnorm, k_proj_buf);
        try applyLinear(spec.v_proj, xnorm, v_proj_buf);

        const q_elems = spec.num_heads * spec.head_dim;
        const gate = q_proj_buf[q_elems .. q_elems * 2];
        var head: usize = 0;
        while (head < spec.num_heads) : (head += 1) {
            const q_slice = q_proj_buf[head * spec.head_dim .. (head + 1) * spec.head_dim];
            rmsNormInto(q_slice, q_slice, spec.q_norm, spec.eps);
            applyRoPE(q_slice, position, spec.rope_dim, spec.rope_freq_base);
        }
        var kv_head: usize = 0;
        while (kv_head < spec.num_kv_heads) : (kv_head += 1) {
            const k_slice = k_proj_buf[kv_head * spec.head_dim .. (kv_head + 1) * spec.head_dim];
            rmsNormInto(k_slice, k_slice, spec.k_norm, spec.eps);
            applyRoPE(k_slice, position, spec.rope_dim, spec.rope_freq_base);

            const cache_off = (step_index * spec.num_kv_heads + kv_head) * spec.head_dim;
            @memcpy(key_cache[cache_off .. cache_off + spec.head_dim], k_slice);
            @memcpy(value_cache[cache_off .. cache_off + spec.head_dim], v_proj_buf[kv_head * spec.head_dim .. (kv_head + 1) * spec.head_dim]);
        }

        try self.computeAttention(spec, q_proj_buf[0..q_elems], gate, step_index, key_cache, value_cache, attn_flat);
        try applyLinear(spec.o_proj, attn_flat, attn_mixed);
        for (out_hidden, 0..) |*dst, i| dst.* = input_hidden[i] + attn_mixed[i];

        rmsNormInto(mlp_norm, out_hidden, spec.post_attention_layernorm, spec.eps);
        try applyLinear(spec.mlp_gate, mlp_norm, mlp_gate);
        try applyLinear(spec.mlp_up, mlp_norm, mlp_up);
        for (mlp_gate, 0..) |*value, i| value.* = silu(value.*) * mlp_up[i];
        try applyLinear(spec.mlp_down, mlp_gate, mlp_out);
        for (out_hidden, 0..) |*dst, i| dst.* += mlp_out[i];
    }

    fn computeAttention(
        self: *Self,
        spec: QwenNextNSpec,
        q: []const f32,
        gate: []const f32,
        step_index: usize,
        key_cache: []const f32,
        value_cache: []const f32,
        out: []f32,
    ) !void {
        @memset(out, 0.0);
        const groups = spec.num_heads / spec.num_kv_heads;
        const scores = try self.allocator.alloc(f32, step_index + 1);
        defer self.allocator.free(scores);

        var head: usize = 0;
        while (head < spec.num_heads) : (head += 1) {
            const kv_head = head / groups;
            const q_head = q[head * spec.head_dim .. (head + 1) * spec.head_dim];
            var max_score = -std.math.inf(f32);
            var t: usize = 0;
            while (t <= step_index) : (t += 1) {
                const k_off = (t * spec.num_kv_heads + kv_head) * spec.head_dim;
                const score = dot(q_head, key_cache[k_off .. k_off + spec.head_dim]) / @sqrt(@as(f32, @floatFromInt(spec.head_dim)));
                scores[t] = score;
                if (score > max_score) max_score = score;
            }

            var sum_exp: f32 = 0.0;
            t = 0;
            while (t <= step_index) : (t += 1) {
                scores[t] = @exp(scores[t] - max_score);
                sum_exp += scores[t];
            }
            if (sum_exp == 0) continue;

            const out_head = out[head * spec.head_dim .. (head + 1) * spec.head_dim];
            @memset(out_head, 0.0);
            t = 0;
            while (t <= step_index) : (t += 1) {
                const weight = scores[t] / sum_exp;
                const v_off = (t * spec.num_kv_heads + kv_head) * spec.head_dim;
                const v_head = value_cache[v_off .. v_off + spec.head_dim];
                for (out_head, 0..) |*dst, i| dst.* += weight * v_head[i];
            }

            const gate_head = gate[head * spec.head_dim .. (head + 1) * spec.head_dim];
            for (out_head, 0..) |*dst, i| dst.* *= sigmoid(gate_head[i]);
        }
    }

    fn fillTopKProjection(
        self: *Self,
        projection: ProjectionSpec,
        hidden: []const f32,
        out_ids: []u32,
        out_scores: []f32,
    ) !void {
        if (out_ids.len != out_scores.len) return error.InvalidCandidateBuffers;
        if (projection.cols != self.hidden_size) return error.InvalidNativeMtpShape;
        if (projection.row_start + self.vocab_size > projection.rows) return error.InvalidNativeMtpShape;

        @memset(out_ids, 0);
        @memset(out_scores, -std.math.inf(f32));

        var token: usize = 0;
        while (token < self.vocab_size) : (token += 1) {
            const row_index = projection.row_start + token;
            const score = try scoreRow(projection.dtype, projection.host_data, row_index, projection.cols, hidden);
            insertTopK(out_ids, out_scores, @intCast(token), score);
        }
    }
};

fn asTensorSpec(view: NativeMtpTensorView) TensorSpec {
    return .{
        .tensor_name = view.name,
        .dtype = view.dtype,
        .host_data = view.host_data,
        .rows = view.rows,
        .cols = view.cols,
    };
}

fn findTensorByName(tensors: []const NativeMtpTensorView, name: []const u8) ?NativeMtpTensorView {
    for (tensors) |tensor| {
        if (std.mem.eql(u8, tensor.name, name)) return tensor;
    }
    return null;
}

fn findTensorFmt(tensors: []const NativeMtpTensorView, comptime fmt: []const u8, args: anytype) ?NativeMtpTensorView {
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, fmt, args) catch return null;
    return findTensorByName(tensors, name);
}

fn fillTopKFromLogits(logits: []const f32, out_ids: []u32, out_scores: []f32) void {
    if (out_ids.len != out_scores.len) return;
    @memset(out_ids, 0);
    @memset(out_scores, -std.math.inf(f32));
    for (logits, 0..) |score, idx| insertTopK(out_ids, out_scores, @intCast(idx), score);
}

fn fillTopKFromWeight(weight: TensorSpec, hidden: []const f32, out_ids: []u32, out_scores: []f32) void {
    if (out_ids.len != out_scores.len) return;
    @memset(out_ids, 0);
    @memset(out_scores, -std.math.inf(f32));
    var token: usize = 0;
    while (token < weight.rows) : (token += 1) {
        const score = scoreRow(weight.dtype, weight.host_data, token, weight.cols, hidden) catch continue;
        insertTopK(out_ids, out_scores, @intCast(token), score);
    }
}

fn insertTopK(out_ids: []u32, out_scores: []f32, token_id: u32, score: f32) void {
    if (out_ids.len == 0) return;

    var min_slot: usize = 0;
    var min_value = out_scores[0];
    var i: usize = 1;
    while (i < out_scores.len) : (i += 1) {
        if (out_scores[i] < min_value) {
            min_value = out_scores[i];
            min_slot = i;
        }
    }

    if (score <= min_value) return;
    out_scores[min_slot] = score;
    out_ids[min_slot] = token_id;

    i = 0;
    while (i < out_scores.len) : (i += 1) {
        var j = i + 1;
        while (j < out_scores.len) : (j += 1) {
            if (out_scores[j] > out_scores[i]) {
                std.mem.swap(f32, &out_scores[i], &out_scores[j]);
                std.mem.swap(u32, &out_ids[i], &out_ids[j]);
            }
        }
    }
}

fn inferPositionFromName(name: []const u8, max_positions: usize) ?usize {
    if (std.mem.indexOf(u8, name, "mtp") == null and
        std.mem.indexOf(u8, name, "nextn") == null and
        std.mem.indexOf(u8, name, "draft") == null)
    {
        return null;
    }

    var i: usize = 0;
    var last_match: ?usize = null;
    while (i < name.len) {
        if (!std.ascii.isDigit(name[i])) {
            i += 1;
            continue;
        }

        var j = i;
        while (j < name.len and std.ascii.isDigit(name[j])) : (j += 1) {}
        const value = std.fmt.parseInt(usize, name[i..j], 10) catch {
            i = j;
            continue;
        };
        if (value > 0 and value < max_positions) last_match = value;
        i = j;
    }
    return last_match;
}

fn rmsNormInto(dst: []f32, src: []const f32, weight: TensorSpec, eps: f32) void {
    var mean_sq: f32 = 0.0;
    for (src) |value| mean_sq += value * value;
    mean_sq /= @as(f32, @floatFromInt(src.len));
    const inv = 1.0 / @sqrt(mean_sq + eps);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const w = readScalar(weight.dtype, weight.host_data, i) catch 0.0;
        dst[i] = (src[i] * inv) * w;
    }
}

fn applyLinear(weight: TensorSpec, input: []const f32, output: []f32) !void {
    if (output.len < weight.rows) return error.InvalidNativeMtpShape;
    if (input.len < weight.cols) return error.InvalidNativeMtpShape;
    var row: usize = 0;
    while (row < weight.rows) : (row += 1) {
        output[row] = try scoreRow(weight.dtype, weight.host_data, row, weight.cols, input);
    }
}

fn readRow(dtype: GGMLType, host_data: []const u8, row_index: usize, cols: usize, dst: []f32) !void {
    if (dst.len < cols) return error.InvalidNativeMtpShape;
    return switch (dtype) {
        .f32 => readRowF32(host_data, row_index, cols, dst),
        .f16 => readRowF16(host_data, row_index, cols, dst),
        .q4_0 => readRowQ4_0(host_data, row_index, cols, dst),
        .q8_0 => readRowQ8_0(host_data, row_index, cols, dst),
        else => error.UnsupportedNativeMtpDType,
    };
}

fn readLeIntAt(comptime T: type, bytes: []const u8, offset: usize) T {
    var raw: [@sizeOf(T)]u8 = undefined;
    @memcpy(raw[0..], bytes[offset .. offset + raw.len]);
    return std.mem.readInt(T, &raw, .little);
}

fn readRowF32(host_data: []const u8, row_index: usize, cols: usize, dst: []f32) !void {
    const row_bytes = cols * @sizeOf(f32);
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const offset = start + col * @sizeOf(f32);
        const bits = readLeIntAt(u32, host_data, offset);
        dst[col] = @bitCast(bits);
    }
}

fn readRowF16(host_data: []const u8, row_index: usize, cols: usize, dst: []f32) !void {
    const row_bytes = cols * @sizeOf(f16);
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const offset = start + col * @sizeOf(f16);
        const bits = readLeIntAt(u16, host_data, offset);
        dst[col] = @floatCast(@as(f16, @bitCast(bits)));
    }
}

fn readRowQ4_0(host_data: []const u8, row_index: usize, cols: usize, dst: []f32) !void {
    const blocks_per_row = std.math.divCeil(usize, cols, 32) catch unreachable;
    const row_bytes = blocks_per_row * GGMLType.q4_0.bytesPerBlock();
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;
    @memset(dst[0..cols], 0.0);

    var block: usize = 0;
    while (block < blocks_per_row) : (block += 1) {
        const block_offset = start + block * GGMLType.q4_0.bytesPerBlock();
        const scale_bits = readLeIntAt(u16, host_data, block_offset);
        const scale: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
        const block_col = block * 32;
        var packed_idx: usize = 0;
        while (packed_idx < 16) : (packed_idx += 1) {
            const qbyte = host_data[block_offset + 2 + packed_idx];
            const lo = @as(i8, @intCast(qbyte & 0x0F)) - 8;
            const hi = @as(i8, @intCast(qbyte >> 4)) - 8;
            const col0 = block_col + packed_idx;
            const col1 = block_col + packed_idx + 16;
            if (col0 < cols) dst[col0] = @as(f32, @floatFromInt(lo)) * scale;
            if (col1 < cols) dst[col1] = @as(f32, @floatFromInt(hi)) * scale;
        }
    }
}

fn readRowQ8_0(host_data: []const u8, row_index: usize, cols: usize, dst: []f32) !void {
    const blocks_per_row = std.math.divCeil(usize, cols, 32) catch unreachable;
    const row_bytes = blocks_per_row * GGMLType.q8_0.bytesPerBlock();
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;
    @memset(dst[0..cols], 0.0);

    var block: usize = 0;
    while (block < blocks_per_row) : (block += 1) {
        const block_offset = start + block * GGMLType.q8_0.bytesPerBlock();
        const scale_bits = readLeIntAt(u16, host_data, block_offset);
        const scale: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
        const block_col = block * 32;
        var elem: usize = 0;
        while (elem < 32) : (elem += 1) {
            const col = block_col + elem;
            if (col >= cols) break;
            const q: i8 = @bitCast(host_data[block_offset + 2 + elem]);
            dst[col] = @as(f32, @floatFromInt(q)) * scale;
        }
    }
}

fn readScalar(dtype: GGMLType, host_data: []const u8, idx: usize) !f32 {
    return switch (dtype) {
        .f32 => blk: {
            const off = idx * @sizeOf(f32);
            if (off + 4 > host_data.len) break :blk error.InvalidNativeMtpShape;
            const bits = readLeIntAt(u32, host_data, off);
            break :blk @bitCast(bits);
        },
        .f16 => blk: {
            const off = idx * @sizeOf(f16);
            if (off + 2 > host_data.len) break :blk error.InvalidNativeMtpShape;
            const bits = readLeIntAt(u16, host_data, off);
            break :blk @floatCast(@as(f16, @bitCast(bits)));
        },
        else => error.UnsupportedNativeMtpDType,
    };
}

fn dot(a: []const f32, b: []const f32) f32 {
    var acc: f32 = 0.0;
    for (a, 0..) |value, i| acc += value * b[i];
    return acc;
}

fn silu(x: f32) f32 {
    return x / (1.0 + @exp(-x));
}

fn sigmoid(x: f32) f32 {
    return 1.0 / (1.0 + @exp(-x));
}

fn applyRoPE(vec: []f32, position: usize, rope_dim: usize, rope_freq_base: f32) void {
    const dim = @min(rope_dim, vec.len);
    var i: usize = 0;
    while (i + 1 < dim) : (i += 2) {
        const freq_exp = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dim));
        const inv_freq = 1.0 / std.math.pow(f32, rope_freq_base, freq_exp);
        const angle = @as(f32, @floatFromInt(position)) * inv_freq;
        const c = @cos(angle);
        const s = @sin(angle);
        const x0 = vec[i];
        const x1 = vec[i + 1];
        vec[i] = x0 * c - x1 * s;
        vec[i + 1] = x0 * s + x1 * c;
    }
}

fn scoreRow(dtype: GGMLType, host_data: []const u8, row_index: usize, cols: usize, hidden: []const f32) !f32 {
    return switch (dtype) {
        .f32 => scoreRowF32(host_data, row_index, cols, hidden),
        .f16 => scoreRowF16(host_data, row_index, cols, hidden),
        .q4_0 => scoreRowQ4_0(host_data, row_index, cols, hidden),
        .q8_0 => scoreRowQ8_0(host_data, row_index, cols, hidden),
        else => error.UnsupportedNativeMtpDType,
    };
}

fn scoreRowF32(host_data: []const u8, row_index: usize, cols: usize, hidden: []const f32) !f32 {
    const row_bytes = cols * @sizeOf(f32);
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;

    var acc: f32 = 0.0;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const offset = start + col * @sizeOf(f32);
        const bits = readLeIntAt(u32, host_data, offset);
        const value: f32 = @bitCast(bits);
        acc += value * hidden[col];
    }
    return acc;
}

fn scoreRowF16(host_data: []const u8, row_index: usize, cols: usize, hidden: []const f32) !f32 {
    const row_bytes = cols * @sizeOf(f16);
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;

    var acc: f32 = 0.0;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const offset = start + col * @sizeOf(f16);
        const bits = readLeIntAt(u16, host_data, offset);
        const value: f32 = @floatCast(@as(f16, @bitCast(bits)));
        acc += value * hidden[col];
    }
    return acc;
}

fn scoreRowQ4_0(host_data: []const u8, row_index: usize, cols: usize, hidden: []const f32) !f32 {
    const blocks_per_row = std.math.divCeil(usize, cols, 32) catch unreachable;
    const row_bytes = blocks_per_row * GGMLType.q4_0.bytesPerBlock();
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;

    var acc: f32 = 0.0;
    var block: usize = 0;
    while (block < blocks_per_row) : (block += 1) {
        const block_offset = start + block * GGMLType.q4_0.bytesPerBlock();
        const scale_bits = readLeIntAt(u16, host_data, block_offset);
        const scale: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
        const block_col = block * 32;

        var packed_idx: usize = 0;
        while (packed_idx < 16) : (packed_idx += 1) {
            const qbyte = host_data[block_offset + 2 + packed_idx];
            const lo = @as(i8, @intCast(qbyte & 0x0F)) - 8;
            const hi = @as(i8, @intCast(qbyte >> 4)) - 8;
            const col0 = block_col + packed_idx;
            const col1 = block_col + packed_idx + 16;

            if (col0 < cols) acc += @as(f32, @floatFromInt(lo)) * scale * hidden[col0];
            if (col1 < cols) acc += @as(f32, @floatFromInt(hi)) * scale * hidden[col1];
        }
    }
    return acc;
}

fn scoreRowQ8_0(host_data: []const u8, row_index: usize, cols: usize, hidden: []const f32) !f32 {
    const blocks_per_row = std.math.divCeil(usize, cols, 32) catch unreachable;
    const row_bytes = blocks_per_row * GGMLType.q8_0.bytesPerBlock();
    const start = row_index * row_bytes;
    if (start + row_bytes > host_data.len) return error.InvalidNativeMtpShape;

    var acc: f32 = 0.0;
    var block: usize = 0;
    while (block < blocks_per_row) : (block += 1) {
        const block_offset = start + block * GGMLType.q8_0.bytesPerBlock();
        const scale_bits = readLeIntAt(u16, host_data, block_offset);
        const scale: f32 = @floatCast(@as(f16, @bitCast(scale_bits)));
        const block_col = block * 32;

        var elem: usize = 0;
        while (elem < 32) : (elem += 1) {
            const col = block_col + elem;
            if (col >= cols) break;
            const q: i8 = @bitCast(host_data[block_offset + 2 + elem]);
            acc += @as(f32, @floatFromInt(q)) * scale * hidden[col];
        }
    }
    return acc;
}

fn appendF32Row(bytes: *std.ArrayList(u8), row: []const f32) !void {
    for (row) |value| {
        const bits: u32 = @bitCast(value);
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, bits, .little);
        try bytes.appendSlice(&raw);
    }
}

test "NativeMtpDrafter fills candidates from stacked row-major tensors" {
    const allocator = std.testing.allocator;

    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();

    try appendF32Row(&bytes, &[_]f32{ 1, 0, 0 });
    try appendF32Row(&bytes, &[_]f32{ 0, 2, 0 });
    try appendF32Row(&bytes, &[_]f32{ 0, 0, 1 });
    try appendF32Row(&bytes, &[_]f32{ 1, 1, 1 });
    try appendF32Row(&bytes, &[_]f32{ 0, 0, 1 });
    try appendF32Row(&bytes, &[_]f32{ 2, 0, 0 });
    try appendF32Row(&bytes, &[_]f32{ 0, 1, 0 });
    try appendF32Row(&bytes, &[_]f32{ 1, 1, 0 });

    const tensor = NativeMtpTensorView{
        .name = "mtp.stack.weight",
        .dtype = .f32,
        .host_data = bytes.items,
        .rows = 8,
        .cols = 3,
    };

    var drafter = try NativeMtpDrafter.init(allocator, 3, 4, 3, 0, 0, 0, 0, 10000.0, 1e-6, &[_]NativeMtpTensorView{tensor});
    defer drafter.deinit();

    try std.testing.expect(drafter.hasAny());
    try std.testing.expectEqual(@as(usize, 2), drafter.supportedPositions());

    const hidden = [_]f32{ 1, 1, 2 };
    const target_logits = [_]f32{ 0.2, 4.0, 0.3, 2.0 };

    var ids0 = [_]u32{ 0, 0 };
    var ids1 = [_]u32{ 0, 0 };
    var ids2 = [_]u32{ 0, 0 };
    var scores0 = [_]f32{ 0, 0 };
    var scores1 = [_]f32{ 0, 0 };
    var scores2 = [_]f32{ 0, 0 };

    const ok = try drafter.fillCandidates(
        &hidden,
        &target_logits,
        0,
        &[_][]u32{ ids0[0..], ids1[0..], ids2[0..] },
        &[_][]f32{ scores0[0..], scores1[0..], scores2[0..] },
    );

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u32, 1), ids0[0]);
    try std.testing.expectEqual(@as(u32, 3), ids1[0]);
    try std.testing.expectEqual(@as(u32, 1), ids2[0]);
}

test "NativeMtpDrafter continuation uses provided sampled token" {
    const allocator = std.testing.allocator;

    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();

    try appendF32Row(&bytes, &[_]f32{ 1, 0, 0 });
    try appendF32Row(&bytes, &[_]f32{ 0, 2, 0 });
    try appendF32Row(&bytes, &[_]f32{ 0, 0, 1 });
    try appendF32Row(&bytes, &[_]f32{ 1, 1, 1 });
    try appendF32Row(&bytes, &[_]f32{ 0, 0, 1 });
    try appendF32Row(&bytes, &[_]f32{ 2, 0, 0 });
    try appendF32Row(&bytes, &[_]f32{ 0, 1, 0 });
    try appendF32Row(&bytes, &[_]f32{ 1, 1, 0 });

    const tensor = NativeMtpTensorView{
        .name = "mtp.stack.weight",
        .dtype = .f32,
        .host_data = bytes.items,
        .rows = 8,
        .cols = 3,
    };

    var drafter = try NativeMtpDrafter.init(allocator, 3, 4, 3, 0, 0, 0, 0, 10000.0, 1e-6, &[_]NativeMtpTensorView{tensor});
    defer drafter.deinit();

    const hidden = [_]f32{ 1, 1, 2 };
    var ids1 = [_]u32{0};
    var ids2 = [_]u32{0};
    var scores1 = [_]f32{0};
    var scores2 = [_]f32{0};

    const ok = try drafter.fillContinuation(
        &hidden,
        2,
        0,
        &[_][]u32{ ids1[0..], ids2[0..] },
        &[_][]f32{ scores1[0..], scores2[0..] },
    );

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u32, 3), ids1[0]);
    try std.testing.expectEqual(@as(u32, 1), ids2[0]);
}

test "NativeMtpDrafter supports qwen nextn layout" {
    const allocator = std.testing.allocator;
    var token_embd = std.ArrayList(u8).init(allocator);
    defer token_embd.deinit();
    try appendF32Row(&token_embd, &[_]f32{ 0, 0 });
    try appendF32Row(&token_embd, &[_]f32{ 1, 0 });
    try appendF32Row(&token_embd, &[_]f32{ 0, 1 });

    var fc = std.ArrayList(u8).init(allocator);
    defer fc.deinit();
    try appendF32Row(&fc, &[_]f32{ 1, 0, 0, 0 });
    try appendF32Row(&fc, &[_]f32{ 0, 1, 0, 0 });

    var zero2 = std.ArrayList(u8).init(allocator);
    defer zero2.deinit();
    try appendF32Row(&zero2, &[_]f32{ 0, 0 });
    try appendF32Row(&zero2, &[_]f32{ 0, 0 });

    var qproj = std.ArrayList(u8).init(allocator);
    defer qproj.deinit();
    try appendF32Row(&qproj, &[_]f32{ 0, 0 });
    try appendF32Row(&qproj, &[_]f32{ 0, 0 });
    try appendF32Row(&qproj, &[_]f32{ 0, 0 });
    try appendF32Row(&qproj, &[_]f32{ 0, 0 });

    const scalar_zero = NativeMtpTensorView{ .name = "unused", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0 }, .rows = 1, .cols = 1 };

    const tensors = [_]NativeMtpTensorView{
        .{ .name = "token_embd.weight", .dtype = .f32, .host_data = token_embd.items, .rows = 3, .cols = 2 },
        .{ .name = "blk.4.nextn.enorm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.nextn.hnorm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.nextn.eh_proj.weight", .dtype = .f32, .host_data = fc.items, .rows = 2, .cols = 4 },
        .{ .name = "blk.4.nextn.shared_head_norm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.attn_norm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.ffn_norm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.attn_q.weight", .dtype = .f32, .host_data = qproj.items, .rows = 4, .cols = 2 },
        .{ .name = "blk.4.attn_q_norm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.attn_k.weight", .dtype = .f32, .host_data = zero2.items, .rows = 2, .cols = 2 },
        .{ .name = "blk.4.attn_k_norm.weight", .dtype = .f32, .host_data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .rows = 1, .cols = 2 },
        .{ .name = "blk.4.attn_v.weight", .dtype = .f32, .host_data = zero2.items, .rows = 2, .cols = 2 },
        .{ .name = "blk.4.attn_output.weight", .dtype = .f32, .host_data = zero2.items, .rows = 2, .cols = 2 },
        .{ .name = "blk.4.ffn_gate.weight", .dtype = .f32, .host_data = zero2.items, .rows = 2, .cols = 2 },
        .{ .name = "blk.4.ffn_up.weight", .dtype = .f32, .host_data = zero2.items, .rows = 2, .cols = 2 },
        .{ .name = "blk.4.ffn_down.weight", .dtype = .f32, .host_data = zero2.items, .rows = 2, .cols = 2 },
        scalar_zero,
    };

    var drafter = try NativeMtpDrafter.init(allocator, 2, 3, 3, 1, 1, 2, 2, 10000.0, 1e-6, &tensors);
    defer drafter.deinit();

    try std.testing.expect(drafter.hasAny());

    const hidden = [_]f32{ 1, 0 };
    const target_logits = [_]f32{ 0, 4, 1 };
    var ids0 = [_]u32{ 0, 0 };
    var ids1 = [_]u32{ 0, 0 };
    var ids2 = [_]u32{ 0, 0 };
    var scores0 = [_]f32{ 0, 0 };
    var scores1 = [_]f32{ 0, 0 };
    var scores2 = [_]f32{ 0, 0 };

    const ok = try drafter.fillCandidates(
        &hidden,
        &target_logits,
        0,
        &[_][]u32{ ids0[0..], ids1[0..], ids2[0..] },
        &[_][]f32{ scores0[0..], scores1[0..], scores2[0..] },
    );

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u32, 1), ids0[0]);
    try std.testing.expectEqual(@as(u32, 1), ids1[0]);
    try std.testing.expectEqual(@as(u32, 1), ids2[0]);
}
