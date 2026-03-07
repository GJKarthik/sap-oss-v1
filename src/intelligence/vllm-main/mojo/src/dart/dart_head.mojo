"""
DART Head Core Module

Lightweight reference implementation for draft logits and top-k extraction.
"""

from memory import LegacyUnsafePointer, memset_zero
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from math import exp, log


struct DARTHead:
    var hidden_size: Int
    var vocab_size: Int
    var num_draft_positions: Int
    var head_hidden_size: Int
    var num_heads: Int

    fn __init__(
        out self,
        hidden_size: Int = 4096,
        vocab_size: Int = 32000,
        num_draft_positions: Int = 4,
        head_hidden_size: Int = 512,
        num_heads: Int = 8,
    ):
        self.hidden_size = hidden_size
        self.vocab_size = vocab_size
        self.num_draft_positions = num_draft_positions
        self.head_hidden_size = head_hidden_size
        self.num_heads = num_heads

    fn forward(
        self,
        hidden_states: UnsafePointer[Float16],
        batch_size: Int,
        prefix_len: Int,
        output_logits: UnsafePointer[Float16],
    ):
        var total = batch_size * self.num_draft_positions * self.vocab_size
        memset_zero(output_logits.bitcast[UInt8](), total * 2)

        for b in range(batch_size):
            var base = b * prefix_len * self.hidden_size + (prefix_len - 1) * self.hidden_size
            for k in range(self.num_draft_positions):
                var out_base = b * self.num_draft_positions * self.vocab_size + k * self.vocab_size
                var seed = Int(Float32(hidden_states[base + (k % self.hidden_size)]) * 1000.0)

                var n = 8
                if n > self.vocab_size:
                    n = self.vocab_size

                for r in range(n):
                    var idx = seed + k * 131 + r * 97
                    if idx < 0:
                        idx = -idx
                    idx = idx % self.vocab_size
                    output_logits[out_base + idx] = Float16(10.0 - Float32(r))

    fn top_k(
        self,
        logits: UnsafePointer[Float16],
        batch_size: Int,
        K: Int,
        n_candidates: Int,
        out_ids: UnsafePointer[UInt32],
        out_log_probs: UnsafePointer[Float32],
    ):
        for b in range(batch_size):
            for k in range(K):
                var logit_offset = b * K * self.vocab_size + k * self.vocab_size
                var out_offset = b * K * n_candidates + k * n_candidates

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
                        var skip = False
                        for j in range(i):
                            if selected[j] == v:
                                skip = True
                                break
                        if skip:
                            continue

                        var val = Float32(logits[logit_offset + v])
                        if val > best_val:
                            best_val = val
                            best_idx = v

                    selected[i] = best_idx
                    out_ids[out_offset + i] = UInt32(best_idx)
                    out_log_probs[out_offset + i] = best_val - log_sum_exp

                selected.free()

    fn memory_usage_mb(self) -> Float32:
        var hidden = Int64(self.hidden_size)
        var head_hidden = Int64(self.head_hidden_size)
        var vocab = Int64(self.vocab_size)
        var K = Int64(self.num_draft_positions)

        var params = hidden * head_hidden + 4 * head_hidden * head_hidden + head_hidden * vocab + K * head_hidden
        return Float32(params) / (1024.0 * 1024.0)


fn main():
    print("Testing DART Head...")

    var head = DARTHead(hidden_size=32, vocab_size=128, num_draft_positions=4)

    var batch_size = 1
    var prefix_len = 4
    var K = head.num_draft_positions
    var vocab = head.vocab_size

    var hs = alloc[Float16](batch_size * prefix_len * head.hidden_size)
    for i in range(batch_size * prefix_len * head.hidden_size):
        hs[i] = Float16(Float32(i % 11) * 0.1)

    var logits = alloc[Float16](batch_size * K * vocab)
    head.forward(hs, batch_size, prefix_len, logits)

    var ids = alloc[UInt32](batch_size * K * 5)
    var probs = alloc[Float32](batch_size * K * 5)
    head.top_k(logits, batch_size, K, 5, ids, probs)

    print("Memory MB:", head.memory_usage_mb())
    print("Top-1 token at k=0:", ids[0])

    hs.free()
    logits.free()
    ids.free()
    probs.free()
