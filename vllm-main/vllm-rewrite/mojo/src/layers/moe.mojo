"""
Mixture of Experts (MoE) Layer

Implements sparse MoE for efficient large model inference.
Key features:
- Top-k expert routing
- Load balancing loss
- Expert parallelism support
- Token dropping for capacity limits

Used in: Mixtral, DeepSeek-V2, Qwen-MoE, Grok
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize
from math import exp, log, max, min


# ==============================================
# MoE Configuration
# ==============================================

struct MoEConfig:
    """Configuration for Mixture of Experts layer."""
    
    var num_experts: Int
    var num_experts_per_tok: Int  # top-k
    var hidden_size: Int
    var intermediate_size: Int  # Per-expert FFN size
    var router_jitter: Float32  # Training noise
    var expert_capacity_factor: Float32  # Capacity = factor * tokens / experts
    var router_aux_loss_coef: Float32  # Load balancing coefficient
    var normalize_router_probs: Bool
    
    fn __init__(
        inout self,
        num_experts: Int = 8,
        num_experts_per_tok: Int = 2,
        hidden_size: Int = 4096,
        intermediate_size: Int = 14336,
        router_jitter: Float32 = 0.0,
        expert_capacity_factor: Float32 = 1.25,
        router_aux_loss_coef: Float32 = 0.01,
        normalize_router_probs: Bool = True,
    ):
        self.num_experts = num_experts
        self.num_experts_per_tok = num_experts_per_tok
        self.hidden_size = hidden_size
        self.intermediate_size = intermediate_size
        self.router_jitter = router_jitter
        self.expert_capacity_factor = expert_capacity_factor
        self.router_aux_loss_coef = router_aux_loss_coef
        self.normalize_router_probs = normalize_router_probs
    
    @staticmethod
    fn mixtral_8x7b() -> MoEConfig:
        """Mixtral 8x7B configuration."""
        return MoEConfig(
            num_experts=8,
            num_experts_per_tok=2,
            hidden_size=4096,
            intermediate_size=14336,
        )
    
    @staticmethod
    fn mixtral_8x22b() -> MoEConfig:
        """Mixtral 8x22B configuration."""
        return MoEConfig(
            num_experts=8,
            num_experts_per_tok=2,
            hidden_size=6144,
            intermediate_size=16384,
        )
    
    @staticmethod
    fn deepseek_v2() -> MoEConfig:
        """DeepSeek-V2 configuration."""
        return MoEConfig(
            num_experts=64,
            num_experts_per_tok=6,
            hidden_size=5120,
            intermediate_size=12288,
        )
    
    @staticmethod
    fn qwen_moe() -> MoEConfig:
        """Qwen-MoE configuration."""
        return MoEConfig(
            num_experts=60,
            num_experts_per_tok=4,
            hidden_size=2048,
            intermediate_size=2560,
        )


# ==============================================
# Expert Router
# ==============================================

struct Router:
    """
    Routes tokens to experts using learned gating.
    
    Computes: router_logits = hidden @ gate_weight
    Then selects top-k experts per token.
    """
    
    var gate: Tensor[DType.float16]  # [hidden_size, num_experts]
    var num_experts: Int
    var top_k: Int
    var jitter: Float32
    
    fn __init__(
        inout self,
        gate: Tensor[DType.float16],
        num_experts: Int,
        top_k: Int,
        jitter: Float32 = 0.0,
    ):
        self.gate = gate
        self.num_experts = num_experts
        self.top_k = top_k
        self.jitter = jitter
    
    fn route(
        self,
        hidden_states: Tensor[DType.float16],
    ) -> Tuple[Tensor[DType.int32], Tensor[DType.float16]]:
        """
        Route tokens to experts.
        
        Returns:
            - expert_indices: [batch * seq, top_k] - which experts
            - routing_weights: [batch * seq, top_k] - softmax weights
        """
        # Compute router logits: [batch * seq, num_experts]
        var router_logits = hidden_states @ self.gate
        
        # Apply softmax
        let router_probs = softmax(router_logits, axis=-1)
        
        # Get top-k experts
        let (top_indices, top_probs) = topk(router_probs, self.top_k)
        
        # Normalize routing weights
        var routing_weights = top_probs
        let weight_sum = routing_weights.sum(axis=-1, keepdims=True)
        routing_weights = routing_weights / weight_sum
        
        return (top_indices.cast[DType.int32](), routing_weights)


# ==============================================
# Expert FFN
# ==============================================

struct ExpertFFN:
    """
    Single expert feed-forward network.
    
    Architecture: SwiGLU (same as LLaMA)
    - gate = Swish(x @ w_gate)
    - up = x @ w_up
    - down = (gate * up) @ w_down
    """
    
    var w_gate: Tensor[DType.float16]  # [hidden, intermediate]
    var w_up: Tensor[DType.float16]    # [hidden, intermediate]
    var w_down: Tensor[DType.float16]  # [intermediate, hidden]
    
    fn __init__(
        inout self,
        w_gate: Tensor[DType.float16],
        w_up: Tensor[DType.float16],
        w_down: Tensor[DType.float16],
    ):
        self.w_gate = w_gate
        self.w_up = w_up
        self.w_down = w_down
    
    fn forward(self, x: Tensor[DType.float16]) -> Tensor[DType.float16]:
        """Apply expert FFN."""
        let gate = swish(x @ self.w_gate)
        let up = x @ self.w_up
        return (gate * up) @ self.w_down


# ==============================================
# MoE Layer
# ==============================================

struct MoELayer:
    """
    Mixture of Experts layer.
    
    Replaces dense FFN with sparse expert routing:
    1. Router computes expert assignments
    2. Tokens dispatched to selected experts
    3. Expert outputs combined with routing weights
    """
    
    var config: MoEConfig
    var router: Router
    var experts: List[ExpertFFN]
    var shared_expert: ExpertFFN  # Optional shared expert (DeepSeek)
    var has_shared_expert: Bool
    
    fn __init__(
        inout self,
        config: MoEConfig,
        router: Router,
        experts: List[ExpertFFN],
        shared_expert: ExpertFFN = ExpertFFN.__init__(),
        has_shared_expert: Bool = False,
    ):
        self.config = config
        self.router = router
        self.experts = experts
        self.shared_expert = shared_expert
        self.has_shared_expert = has_shared_expert
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
    ) -> Tensor[DType.float16]:
        """
        Forward pass through MoE layer.
        
        Algorithm:
        1. Flatten input to [batch * seq, hidden]
        2. Route tokens to experts
        3. For each expert, process assigned tokens
        4. Combine outputs with routing weights
        5. Reshape back to [batch, seq, hidden]
        """
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        let hidden_size = hidden_states.shape()[2]
        let num_tokens = batch_size * seq_len
        
        # Flatten: [batch, seq, hidden] -> [batch * seq, hidden]
        var flat_hidden = hidden_states.reshape(num_tokens, hidden_size)
        
        # Get routing decisions
        let (expert_indices, routing_weights) = self.router.route(flat_hidden)
        
        # Initialize output
        var output = Tensor[DType.float16](num_tokens, hidden_size)
        
        # Process each expert
        for expert_idx in range(self.config.num_experts):
            # Find tokens routed to this expert
            let mask = (expert_indices == expert_idx).any(axis=-1)
            let token_indices = mask.nonzero()
            
            if token_indices.shape()[0] == 0:
                continue  # No tokens for this expert
            
            # Get tokens for this expert
            let expert_tokens = flat_hidden.gather(0, token_indices)
            
            # Get routing weights for this expert
            var expert_weights = Tensor[DType.float16](token_indices.shape()[0])
            for i in range(token_indices.shape()[0]):
                let tok_idx = token_indices[i]
                for k in range(self.config.num_experts_per_tok):
                    if expert_indices[tok_idx, k] == expert_idx:
                        expert_weights.store(i, routing_weights[tok_idx, k])
                        break
            
            # Apply expert
            let expert_output = self.experts[expert_idx].forward(expert_tokens)
            
            # Scale by routing weight and accumulate
            for i in range(token_indices.shape()[0]):
                let tok_idx = token_indices[i]
                let weight = expert_weights[i]
                for h in range(hidden_size):
                    let val = output[tok_idx, h] + expert_output[i, h] * weight
                    output.store(tok_idx, h, val)
        
        # Add shared expert if present (DeepSeek style)
        if self.has_shared_expert:
            let shared_output = self.shared_expert.forward(flat_hidden)
            output = output + shared_output
        
        # Reshape back: [batch * seq, hidden] -> [batch, seq, hidden]
        return output.reshape(batch_size, seq_len, hidden_size)


# ==============================================
# Optimized MoE with Token Permutation
# ==============================================

struct OptimizedMoE:
    """
    Optimized MoE using token permutation.
    
    Instead of scattering tokens to experts:
    1. Sort tokens by expert assignment
    2. Process contiguous chunks per expert
    3. Un-permute results
    
    Much more efficient for GPU execution.
    """
    
    var config: MoEConfig
    var router: Router
    var experts: List[ExpertFFN]
    
    fn __init__(
        inout self,
        config: MoEConfig,
        router: Router,
        experts: List[ExpertFFN],
    ):
        self.config = config
        self.router = router
        self.experts = experts
    
    fn forward(
        self,
        hidden_states: Tensor[DType.float16],
    ) -> Tensor[DType.float16]:
        """
        Optimized forward with token permutation.
        """
        let batch_size = hidden_states.shape()[0]
        let seq_len = hidden_states.shape()[1]
        let hidden_size = hidden_states.shape()[2]
        let num_tokens = batch_size * seq_len
        let top_k = self.config.num_experts_per_tok
        
        # Flatten
        var flat_hidden = hidden_states.reshape(num_tokens, hidden_size)
        
        # Get routing
        let (expert_indices, routing_weights) = self.router.route(flat_hidden)
        
        # Expand tokens for top-k: [num_tokens, hidden] -> [num_tokens * top_k, hidden]
        var expanded_hidden = Tensor[DType.float16](num_tokens * top_k, hidden_size)
        for i in range(num_tokens):
            for k in range(top_k):
                let idx = i * top_k + k
                for h in range(hidden_size):
                    expanded_hidden.store(idx, h, flat_hidden[i, h])
        
        # Flatten expert indices: [num_tokens, top_k] -> [num_tokens * top_k]
        var flat_expert_idx = Tensor[DType.int32](num_tokens * top_k)
        var flat_weights = Tensor[DType.float16](num_tokens * top_k)
        for i in range(num_tokens):
            for k in range(top_k):
                let idx = i * top_k + k
                flat_expert_idx.store(idx, expert_indices[i, k])
                flat_weights.store(idx, routing_weights[i, k])
        
        # Sort by expert (get permutation indices)
        let sorted_indices = argsort(flat_expert_idx)
        
        # Permute tokens
        var permuted_hidden = expanded_hidden.gather(0, sorted_indices)
        var permuted_experts = flat_expert_idx.gather(0, sorted_indices)
        var permuted_weights = flat_weights.gather(0, sorted_indices)
        
        # Process each expert's contiguous chunk
        var expert_outputs = Tensor[DType.float16](num_tokens * top_k, hidden_size)
        
        var start_idx = 0
        for expert_idx in range(self.config.num_experts):
            # Find end of this expert's tokens
            var end_idx = start_idx
            while end_idx < num_tokens * top_k and permuted_experts[end_idx] == expert_idx:
                end_idx += 1
            
            if start_idx == end_idx:
                continue  # No tokens
            
            # Get contiguous chunk
            let expert_tokens = permuted_hidden[start_idx:end_idx, :]
            
            # Apply expert
            let output = self.experts[expert_idx].forward(expert_tokens)
            
            # Store output
            for i in range(start_idx, end_idx):
                for h in range(hidden_size):
                    expert_outputs.store(i, h, output[i - start_idx, h])
            
            start_idx = end_idx
        
        # Un-permute
        var unpermuted_outputs = Tensor[DType.float16](num_tokens * top_k, hidden_size)
        for i in range(num_tokens * top_k):
            let orig_idx = sorted_indices[i]
            for h in range(hidden_size):
                unpermuted_outputs.store(orig_idx, h, expert_outputs[i, h])
        
        # Combine top-k outputs with weights
        var final_output = Tensor[DType.float16](num_tokens, hidden_size)
        for i in range(num_tokens):
            for h in range(hidden_size):
                var val: Float16 = 0.0
                for k in range(top_k):
                    let idx = i * top_k + k
                    val += unpermuted_outputs[idx, h] * flat_weights[idx]
                final_output.store(i, h, val)
        
        return final_output.reshape(batch_size, seq_len, hidden_size)


# ==============================================
# Load Balancing Loss
# ==============================================

fn compute_load_balancing_loss(
    router_probs: Tensor[DType.float16],  # [num_tokens, num_experts]
    expert_indices: Tensor[DType.int32],   # [num_tokens, top_k]
    num_experts: Int,
) -> Float32:
    """
    Compute auxiliary load balancing loss.
    
    Encourages equal distribution of tokens across experts.
    
    Loss = num_experts * sum(fraction_tokens * fraction_router_prob)
    
    Where:
    - fraction_tokens = (tokens routed to expert) / total_tokens
    - fraction_router_prob = mean(router_prob for expert)
    """
    let num_tokens = router_probs.shape()[0]
    
    # Count tokens per expert
    var tokens_per_expert = Tensor[DType.float32](num_experts)
    for i in range(num_tokens):
        for k in range(expert_indices.shape()[1]):
            let expert = expert_indices[i, k]
            tokens_per_expert.store(expert, tokens_per_expert[expert] + 1.0)
    
    # Compute fractions
    var fraction_tokens = tokens_per_expert / Float32(num_tokens)
    
    # Mean router probability per expert
    var mean_router_prob = Tensor[DType.float32](num_experts)
    for e in range(num_experts):
        var sum_prob: Float32 = 0.0
        for i in range(num_tokens):
            sum_prob += router_probs[i, e].cast[DType.float32]()
        mean_router_prob.store(e, sum_prob / Float32(num_tokens))
    
    # Compute loss
    var loss: Float32 = 0.0
    for e in range(num_experts):
        loss += fraction_tokens[e] * mean_router_prob[e]
    
    return loss * Float32(num_experts)


# ==============================================
# Helper Functions
# ==============================================

fn softmax(x: Tensor[DType.float16], axis: Int = -1) -> Tensor[DType.float16]:
    """Compute softmax along axis."""
    # Find max for numerical stability
    var max_val = x.max(axis=axis, keepdims=True)
    var exp_x = exp(x - max_val)
    var sum_exp = exp_x.sum(axis=axis, keepdims=True)
    return exp_x / sum_exp


fn swish(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """SiLU/Swish activation: x * sigmoid(x)."""
    return x * sigmoid(x)


fn sigmoid(x: Tensor[DType.float16]) -> Tensor[DType.float16]:
    """Sigmoid activation."""
    return Float16(1.0) / (Float16(1.0) + exp(-x))


fn topk(
    x: Tensor[DType.float16],
    k: Int,
) -> Tuple[Tensor[DType.int32], Tensor[DType.float16]]:
    """
    Get top-k values and indices.
    
    Returns (indices, values) for top-k along last dimension.
    """
    let batch = x.shape()[0]
    let n = x.shape()[1]
    
    var indices = Tensor[DType.int32](batch, k)
    var values = Tensor[DType.float16](batch, k)
    
    for b in range(batch):
        # Simple selection sort for top-k
        var used = List[Bool]()
        for i in range(n):
            used.append(False)
        
        for i in range(k):
            var best_idx = -1
            var best_val: Float16 = Float16.min
            
            for j in range(n):
                if not used[j] and x[b, j] > best_val:
                    best_idx = j
                    best_val = x[b, j]
            
            indices.store(b, i, best_idx)
            values.store(b, i, best_val)
            used[best_idx] = True
    
    return (indices, values)


fn argsort(x: Tensor[DType.int32]) -> Tensor[DType.int32]:
    """Return indices that would sort the array."""
    let n = x.shape()[0]
    var indices = Tensor[DType.int32](n)
    
    # Initialize
    for i in range(n):
        indices.store(i, i)
    
    # Simple bubble sort (replace with quicksort for production)
    for i in range(n):
        for j in range(i + 1, n):
            if x[indices[j]] < x[indices[i]]:
                let tmp = indices[i]
                indices.store(i, indices[j])
                indices.store(j, tmp)
    
    return indices