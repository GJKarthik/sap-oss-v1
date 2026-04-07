"""
DART Training Utilities

Minimal compile-safe training helpers for loss computation and scheduling.
"""

from memory import LegacyUnsafePointer
comptime UnsafePointer = LegacyUnsafePointer[mut=True, ...]
from memory.unsafe_pointer import alloc
from math import exp, log


struct DARTTrainingConfig:
    var target_model_name: String
    var hidden_size: Int
    var vocab_size: Int
    var num_draft_positions: Int
    var batch_size: Int
    var learning_rate: Float32
    var distillation_alpha: Float32

    fn __init__(out self):
        self.target_model_name = "meta-llama/Llama-3.1-8B-Instruct"
        self.hidden_size = 4096
        self.vocab_size = 128256
        self.num_draft_positions = 4
        self.batch_size = 4
        self.learning_rate = 5e-4
        self.distillation_alpha = 0.5


struct DARTLoss:
    var distillation_alpha: Float32

    fn __init__(out self, distillation_alpha: Float32 = 0.5):
        self.distillation_alpha = distillation_alpha

    fn cross_entropy_row(
        self,
        logits: UnsafePointer[Float32],
        vocab_size: Int,
        target_id: Int,
    ) -> Float32:
        _ = self
        if target_id < 0 or target_id >= vocab_size:
            return 0.0

        var max_val: Float32 = -1e9
        for v in range(vocab_size):
            if logits[v] > max_val:
                max_val = logits[v]

        var sum_exp: Float32 = 0.0
        for v in range(vocab_size):
            sum_exp += exp(logits[v] - max_val)
        if sum_exp <= 0.0:
            sum_exp = 1.0

        var log_prob = logits[target_id] - (log(sum_exp) + max_val)
        return -log_prob

    fn batch_ce_loss(
        self,
        logits: UnsafePointer[Float32],
        target_ids: UnsafePointer[UInt32],
        batch_size: Int,
        K: Int,
        vocab_size: Int,
    ) -> Float32:
        var total: Float32 = 0.0
        var rows = batch_size * K
        if rows <= 0:
            return 0.0

        for r in range(rows):
            var row_ptr = logits + r * vocab_size
            total += self.cross_entropy_row(row_ptr, vocab_size, Int(target_ids[r]))

        return total / Float32(rows)


fn estimate_training_steps(num_examples: Int, batch_size: Int, epochs: Int) -> Int:
    if num_examples <= 0 or batch_size <= 0 or epochs <= 0:
        return 0
    return ((num_examples + batch_size - 1) // batch_size) * epochs


fn main():
    print("DART training utilities ready")

    var cfg = DARTTrainingConfig()
    print("Model:", cfg.target_model_name)

    var vocab = 16
    var logits = alloc[Float32](vocab)
    for i in range(vocab):
        logits[i] = Float32(i) * 0.1

    var target = alloc[UInt32](1)
    target[0] = 7

    var loss = DARTLoss(distillation_alpha=cfg.distillation_alpha)
    var ce = loss.batch_ce_loss(logits, target, 1, 1, vocab)
    print("Example CE:", ce)

    logits.free()
    target.free()
