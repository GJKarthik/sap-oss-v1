"""
DART Head FFI Bridge

Compile-safe FFI bridge for Zig integration.
"""

from memory import LegacyUnsafePointer, memset_zero
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from math import exp, log

comptime DART_SUCCESS: Int32 = 0
comptime DART_ERROR: Int32 = -1


struct DARTHeadConfigFFI:
    var hidden_size: Int32
    var vocab_size: Int32
    var num_draft_positions: Int32
    var head_hidden_size: Int32
    var num_heads: Int32
    var ffn_multiplier_x100: Int32
    var use_int8: Int32
    var _padding: Int32

    fn is_valid(self) -> Bool:
        return (
            self.hidden_size > 0 and
            self.vocab_size > 0 and
            self.num_draft_positions > 0 and
            self.head_hidden_size > 0 and
            self.num_heads > 0
        )


struct DARTHeadState:
    var hidden_size: Int
    var vocab_size: Int
    var num_draft_positions: Int
    var head_hidden_size: Int
    var num_heads: Int
    var ffn_multiplier_x100: Int
    var use_int8: Bool
    var weights_loaded: Bool

    fn __init__(out self, config_ptr: UnsafePointer[DARTHeadConfigFFI]):
        self.hidden_size = Int(config_ptr[0].hidden_size)
        self.vocab_size = Int(config_ptr[0].vocab_size)
        self.num_draft_positions = Int(config_ptr[0].num_draft_positions)
        self.head_hidden_size = Int(config_ptr[0].head_hidden_size)
        self.num_heads = Int(config_ptr[0].num_heads)
        self.ffn_multiplier_x100 = Int(config_ptr[0].ffn_multiplier_x100)
        self.use_int8 = config_ptr[0].use_int8 != 0
        self.weights_loaded = False

    fn _candidate_token(self, seed: Int, draft_pos: Int, rank: Int) -> Int:
        var base = seed + draft_pos * 131 + rank * 97
        if base < 0:
            base = -base
        if self.vocab_size <= 0:
            return 0
        return base % self.vocab_size

    fn forward(
        self,
        hidden_states: UnsafePointer[Float16],
        batch_size: Int,
        prefix_len: Int,
        output_logits: UnsafePointer[Float16],
    ) -> Int32:
        if batch_size <= 0 or prefix_len <= 0:
            return DART_ERROR

        if self.num_draft_positions <= 0 or self.vocab_size <= 0 or self.hidden_size <= 0:
            return DART_ERROR

        var total = batch_size * self.num_draft_positions * self.vocab_size
        memset_zero(output_logits.bitcast[UInt8](), total * 2)

        for b in range(batch_size):
            var last_hidden_base = b * prefix_len * self.hidden_size + (prefix_len - 1) * self.hidden_size
            for k in range(self.num_draft_positions):
                var out_base = b * self.num_draft_positions * self.vocab_size + k * self.vocab_size
                var src_idx = last_hidden_base + (k % self.hidden_size)
                var seed = Int(Float32(hidden_states[src_idx]) * 1000.0)

                var rank_count = 8
                if rank_count > self.vocab_size:
                    rank_count = self.vocab_size

                for r in range(rank_count):
                    var tid = self._candidate_token(seed, k, r)
                    output_logits[out_base + tid] = Float16(10.0 - Float32(r))

        return DART_SUCCESS

    fn get_top_k(
        self,
        logits: UnsafePointer[Float16],
        batch_size: Int,
        K: Int,
        n_candidates: Int,
        out_ids: UnsafePointer[UInt32],
        out_log_probs: UnsafePointer[Float32],
    ) -> Int32:
        if batch_size <= 0 or K <= 0 or n_candidates <= 0 or self.vocab_size <= 0:
            return DART_ERROR

        var effective_k = K
        if effective_k > self.num_draft_positions:
            effective_k = self.num_draft_positions

        for b in range(batch_size):
            for k in range(effective_k):
                var logit_offset = b * effective_k * self.vocab_size + k * self.vocab_size
                var out_offset = b * effective_k * n_candidates + k * n_candidates

                var max_val: Float32 = -1e9
                for v in range(self.vocab_size):
                    var val = Float32(logits[logit_offset + v])
                    if val > max_val:
                        max_val = val

                var sum_exp: Float32 = 0.0
                for v in range(self.vocab_size):
                    sum_exp += exp(Float32(logits[logit_offset + v]) - max_val)
                if sum_exp <= 0.0:
                    sum_exp = 1.0
                var log_sum_exp = log(sum_exp) + max_val

                var selected = alloc[Int32](n_candidates)
                for i in range(n_candidates):
                    selected[i] = -1

                for i in range(n_candidates):
                    var best_idx = 0
                    var best_val: Float32 = -1e9

                    for v in range(self.vocab_size):
                        var already_selected = False
                        for j in range(i):
                            if selected[j] == v:
                                already_selected = True
                                break
                        if already_selected:
                            continue

                        var val = Float32(logits[logit_offset + v])
                        if val > best_val:
                            best_val = val
                            best_idx = v

                    selected[i] = best_idx
                    out_ids[out_offset + i] = UInt32(best_idx)
                    out_log_probs[out_offset + i] = best_val - log_sum_exp

                selected.free()

        return DART_SUCCESS

    fn memory_usage_mb(self) -> Float32:
        var hidden = Int64(self.hidden_size)
        var head_hidden = Int64(self.head_hidden_size)
        var vocab = Int64(self.vocab_size)
        var K = Int64(self.num_draft_positions)

        var input_proj = hidden * head_hidden
        var qkvo = 4 * head_hidden * head_hidden
        var ffn = 2 * head_hidden * (2 * head_hidden)
        var lm_head = head_hidden * vocab
        var mask_tokens = K * head_hidden

        var bytes = input_proj + qkvo + ffn + lm_head
        bytes += mask_tokens * 2
        return Float32(bytes) / (1024.0 * 1024.0)

    fn load_weights(
        mut self,
        weight_data: UnsafePointer[UInt8],
        data_size: Int64,
    ) -> Int32:
        if not weight_data or data_size <= 0:
            return DART_ERROR
        self.weights_loaded = True
        return DART_SUCCESS


@export
fn dart_head_create(config_ptr: UnsafePointer[DARTHeadConfigFFI]) -> UnsafePointer[UInt8]:
    if not config_ptr:
        return UnsafePointer[UInt8]()

    if not config_ptr[0].is_valid():
        return UnsafePointer[UInt8]()

    var state = alloc[DARTHeadState](1)
    state[0] = DARTHeadState(config_ptr)
    return state.bitcast[UInt8]()


@export
fn dart_head_destroy(handle: UnsafePointer[UInt8]):
    if not handle:
        return

    var state = handle.bitcast[DARTHeadState]()
    state.free()


@export
fn dart_head_forward(
    handle: UnsafePointer[UInt8],
    hidden_states: UnsafePointer[Float16],
    batch_size: Int32,
    prefix_len: Int32,
    output_logits: UnsafePointer[Float16],
) -> Int32:
    if not handle or not hidden_states or not output_logits:
        return DART_ERROR

    var state = handle.bitcast[DARTHeadState]()
    return state[0].forward(hidden_states, Int(batch_size), Int(prefix_len), output_logits)


@export
fn dart_head_get_top_k(
    handle: UnsafePointer[UInt8],
    logits: UnsafePointer[Float16],
    batch_size: Int32,
    K: Int32,
    n_candidates: Int32,
    out_ids: UnsafePointer[UInt32],
    out_log_probs: UnsafePointer[Float32],
) -> Int32:
    if not handle or not logits or not out_ids or not out_log_probs:
        return DART_ERROR

    var state = handle.bitcast[DARTHeadState]()
    return state[0].get_top_k(
        logits,
        Int(batch_size),
        Int(K),
        Int(n_candidates),
        out_ids,
        out_log_probs,
    )


@export
fn dart_head_get_config(
    handle: UnsafePointer[UInt8],
    out_config: UnsafePointer[DARTHeadConfigFFI],
) -> Int32:
    if not handle or not out_config:
        return DART_ERROR

    var state = handle.bitcast[DARTHeadState]()
    out_config[0].hidden_size = Int32(state[0].hidden_size)
    out_config[0].vocab_size = Int32(state[0].vocab_size)
    out_config[0].num_draft_positions = Int32(state[0].num_draft_positions)
    out_config[0].head_hidden_size = Int32(state[0].head_hidden_size)
    out_config[0].num_heads = Int32(state[0].num_heads)
    out_config[0].ffn_multiplier_x100 = Int32(state[0].ffn_multiplier_x100)
    out_config[0].use_int8 = Int32(1 if state[0].use_int8 else 0)
    out_config[0]._padding = 0
    return DART_SUCCESS


@export
fn dart_head_memory_usage_mb(handle: UnsafePointer[UInt8]) -> Float32:
    if not handle:
        return -1.0

    var state = handle.bitcast[DARTHeadState]()
    return state[0].memory_usage_mb()


@export
fn dart_head_load_weights(
    handle: UnsafePointer[UInt8],
    weight_data: UnsafePointer[UInt8],
    data_size: Int64,
) -> Int32:
    if not handle:
        return DART_ERROR

    var state = handle.bitcast[DARTHeadState]()
    return state[0].load_weights(weight_data, data_size)
