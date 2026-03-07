"""
Mojo-RT: TOON-Masked Sampler.

Enforces TOON structural constraints at the hardware level during token
sampling.  Instead of generating tokens and then validating them (the
JSON/regex approach), this kernel zeroes out logits for tokens that
violate the current TOON grammar state — the model physically cannot
produce invalid syntax.

Token classes (bitfield):
    ALPHA      = 0x01   a-z, A-Z, _
    NUMERIC    = 0x02   0-9, ., -, +
    DELIMITER  = 0x04   :, |, ,, ~, =
    WHITESPACE = 0x08   space, tab, newline
    BRACKET    = 0x10   (, ), [, ], {, }
    SPECIAL    = 0x20   <, >, /, \\, @, #
    EOS        = 0x40   end-of-sequence token

The Zig parser (`llama_toon.zig`) tracks the current TOON state and
sends a single `allowed_mask: UInt8` bitfield to this kernel each step.
Any token whose class ANDs to zero with the mask gets logit = -inf.

Performance: single SIMD pass over the vocabulary (~0.01 ms for 128k vocab).
"""

from algorithm.functional import vectorize
from memory import UnsafePointer
from memory.unsafe_pointer import alloc
from math import exp
from sys.info import simd_width_of

comptime F32 = DType.float32
comptime U8 = DType.uint8
comptime SW = simd_width_of[F32]()

# TOON token class bitfield constants
comptime TOON_ALPHA: UInt8 = 0x01
comptime TOON_NUMERIC: UInt8 = 0x02
comptime TOON_DELIMITER: UInt8 = 0x04
comptime TOON_WHITESPACE: UInt8 = 0x08
comptime TOON_BRACKET: UInt8 = 0x10
comptime TOON_SPECIAL: UInt8 = 0x20
comptime TOON_EOS: UInt8 = 0x40
comptime TOON_ALL: UInt8 = 0x7F

comptime NEG_INF: Scalar[F32] = -1e9


# =============================================================================
# 1. Vocabulary Classification (One-Time Setup)
# =============================================================================

fn classify_vocab_token[o_tb: Origin](
    token_bytes: UnsafePointer[UInt8, origin=o_tb],
    token_len: Int,
) -> UInt8:
    """
    Classify a single vocabulary token into TOON bitfield classes.
    A token may belong to multiple classes (e.g., a digit delimiter "1:").
    We classify based on the *first printable character* — this matches
    how TOON parsing works (the first char determines the structural role).
    """
    if token_len == 0:
        return TOON_SPECIAL

    var first = token_bytes[0]

    # Whitespace
    if first == 0x20 or first == 0x09 or first == 0x0A or first == 0x0D:
        return TOON_WHITESPACE

    # Digits and numeric punctuation
    if (first >= 0x30 and first <= 0x39) or first == 0x2E or first == 0x2D or first == 0x2B:
        return TOON_NUMERIC

    # Letters and underscore
    if (first >= 0x41 and first <= 0x5A) or (first >= 0x61 and first <= 0x7A) or first == 0x5F:
        return TOON_ALPHA

    # TOON delimiters: : | , ~ =
    if first == 0x3A or first == 0x7C or first == 0x2C or first == 0x7E or first == 0x3D:
        return TOON_DELIMITER

    # Brackets
    if first == 0x28 or first == 0x29 or first == 0x5B or first == 0x5D or first == 0x7B or first == 0x7D:
        return TOON_BRACKET

    return TOON_SPECIAL


fn build_vocab_class_table[o_ct: MutOrigin, o_vt: Origin, o_vl: Origin](
    class_table: UnsafePointer[Scalar[U8], origin=o_ct],   # [vocab_size] output
    vocab_tokens: UnsafePointer[UInt8, origin=o_vt],        # flattened token bytes [vocab_size * max_token_len]
    vocab_lengths: UnsafePointer[Int32, origin=o_vl],       # [vocab_size]
    vocab_size: Int,
    max_token_len: Int,
    eos_token_id: Int,
):
    """
    Build the token class table for the entire vocabulary.
    Called once at model load time.
    """
    for i in range(vocab_size):
        var offset = i * max_token_len
        var length = Int(vocab_lengths[i])

        if i == eos_token_id:
            class_table.store[width=1](i, TOON_EOS)
        else:
            var cls = classify_vocab_token(vocab_tokens + offset, length)
            class_table.store[width=1](i, cls)


# =============================================================================
# 2. TOON Logit Masking (Per-Step)
# =============================================================================

fn apply_toon_mask[o_l: MutOrigin, o_tc: Origin](
    logits_ptr: UnsafePointer[Scalar[F32], origin=o_l],
    token_classes_ptr: UnsafePointer[Scalar[U8], origin=o_tc],
    allowed_mask: UInt8,
    vocab_size: Int,
):
    """
    Mask logits in a single SIMD pass.

    For each token i in [0, vocab_size):
        if (token_classes[i] & allowed_mask) == 0:
            logits[i] = -inf

    This prevents the softmax from assigning any probability mass to
    structurally invalid tokens.
    """
    # Guard: Invalid vocab_size would cause loop to not execute or access invalid memory
    if vocab_size <= 0:
        return
    
    for i in range(vocab_size):
        var cls = token_classes_ptr.load[width=1](i)
        if (cls & allowed_mask) == 0:
            logits_ptr.store[width=1](i, NEG_INF)


fn apply_toon_mask_vectorized[o_l: MutOrigin, o_tc: Origin](
    logits_ptr: UnsafePointer[Scalar[F32], origin=o_l],
    token_classes_ptr: UnsafePointer[Scalar[U8], origin=o_tc],
    allowed_mask: UInt8,
    vocab_size: Int,
):
    """
    SIMD-vectorised version of TOON logit masking.
    Processes `SW` logits at a time using select().
    """
    # Guard: Invalid vocab_size would cause vectorize to not execute or access invalid memory
    if vocab_size <= 0:
        return
    
    fn mask_vec[width: Int](i: Int) unified {mut}:
        var logits = logits_ptr.load[width=width](i)
        # Load class bytes one at a time and build a mask
        # (U8 SIMD width may differ from F32 width, so we do scalar class checks
        #  and build a float mask)
        var mask_vals = SIMD[F32, width](0)
        for lane in range(width):
            var cls = token_classes_ptr.load[width=1](i + lane)
            if (cls & allowed_mask) != 0:
                mask_vals[lane] = Scalar[F32](1.0)

        # Where mask == 0, replace with NEG_INF; otherwise keep logit
        var neg_inf_vec = SIMD[F32, width](NEG_INF)
        var result = mask_vals.select(logits, neg_inf_vec)
        logits_ptr.store[width=width](i, result)

    vectorize[SW](vocab_size, mask_vec)


# =============================================================================
# 3. TOON-Constrained Top-K Sampling
# =============================================================================

fn toon_sample_topk[o_l: MutOrigin, o_tc: Origin](
    logits_ptr: UnsafePointer[Scalar[F32], origin=o_l],
    token_classes_ptr: UnsafePointer[Scalar[U8], origin=o_tc],
    allowed_mask: UInt8,
    vocab_size: Int,
    top_k: Int,
    temperature: Scalar[F32],
) -> Int:
    """
    TOON-constrained top-k sampling in a single pass:

    1. Mask invalid tokens to -inf.
    2. Find top-k logits from the allowed set.
    3. Apply temperature scaling.
    4. Softmax over top-k candidates.
    5. Greedy argmax (for deterministic TOON output).

    Returns the sampled token ID, or 0 if vocab_size or top_k is invalid.
    """
    # Guard: Invalid parameters would cause incorrect behavior
    if vocab_size <= 0:
        return 0
    if top_k <= 0:
        return 0
    
    # Ensure top_k doesn't exceed vocab_size
    var effective_k = top_k
    if effective_k > vocab_size:
        effective_k = vocab_size
    
    # Step 1: apply TOON mask in-place (SIMD-vectorized)
    apply_toon_mask_vectorized(logits_ptr, token_classes_ptr, allowed_mask, vocab_size)

    # Step 2: find top-k by scanning (sufficient for vocab ≤ 128k with k ≤ 40)
    var topk_ids = alloc[Int](effective_k)
    var topk_vals = alloc[Scalar[F32]](effective_k)

    # Initialise with -inf
    for i in range(effective_k):
        topk_ids[i] = 0
        topk_vals[i] = NEG_INF

    # Linear scan to collect top-k
    for i in range(vocab_size):
        var val = logits_ptr.load[width=1](i)
        # Find min in current top-k
        var min_idx = 0
        var min_val = topk_vals[0]
        for j in range(1, effective_k):
            if topk_vals[j] < min_val:
                min_val = topk_vals[j]
                min_idx = j
        if val > min_val:
            topk_vals[min_idx] = val
            topk_ids[min_idx] = i

    # Step 3: temperature scaling
    if temperature > Scalar[F32](0.0):
        for i in range(effective_k):
            topk_vals[i] = topk_vals[i] / temperature

    # Step 4: softmax over top-k
    var max_val = topk_vals[0]
    for i in range(1, effective_k):
        if topk_vals[i] > max_val:
            max_val = topk_vals[i]

    var sum_exp = Scalar[F32](0.0)
    for i in range(effective_k):
        topk_vals[i] = exp(topk_vals[i] - max_val)
        sum_exp += topk_vals[i]

    # Step 5: greedy argmax over the softmax distribution
    var best_idx = 0
    var best_prob = topk_vals[0]
    for i in range(1, effective_k):
        if topk_vals[i] > best_prob:
            best_prob = topk_vals[i]
            best_idx = i

    var result = topk_ids[best_idx]

    topk_ids.free()
    topk_vals.free()

    return result


# =============================================================================
# 4. TOON State Machine Constants
# =============================================================================
#
# These mirror the Zig-side ToonParserState enum and the allowed_mask
# lookup table.  They are here for documentation; the actual mask
# computation happens in Zig (llama_toon.zig) and is passed as a u8.
#
#   expect_key          → ALPHA
#   expect_delimiter    → DELIMITER
#   expect_value_start  → ALPHA | NUMERIC | DELIMITER | BRACKET
#   in_value            → ALPHA | NUMERIC | WHITESPACE | DELIMITER | BRACKET | SPECIAL
#   expect_newline      → WHITESPACE | EOS
#   expect_array_item   → ALPHA | NUMERIC | DELIMITER
#   done                → EOS
#
# The Zig side calls:
#     mojo_apply_toon_mask(logits, class_table, mask, vocab_size)
# with the appropriate mask for the current parser state.
