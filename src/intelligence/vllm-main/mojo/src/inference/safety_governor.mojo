"""
Safety Governor for LLM Inference.
Implements resource limits, sequence length enforcement, and safety invariants.

Reference: safety-nlocalmodels-mojo.pdf Section XI-XII
"""

from memory import UnsafePointer
from memory.unsafe_pointer import alloc
from time import now

# =============================================================================
# SAFETY CONFIGURATION CONSTANTS
# =============================================================================

# G4 FIX: Maximum sequence length (tokens)
# This prevents unbounded KV cache growth which could exhaust memory
comptime MAX_SEQUENCE_LENGTH: Int = 131072  # 128K tokens (LLaMA 3.3 max)

# G8 FIX: Resource quotas
comptime MAX_BATCH_SIZE: Int = 32
comptime MAX_TOKENS_PER_REQUEST: Int = 16384
comptime MAX_CONCURRENT_REQUESTS: Int = 64
comptime MAX_MEMORY_GB: Int = 48

# Rate limiting
comptime MAX_REQUESTS_PER_MINUTE: Int = 1000
comptime MAX_TOKENS_PER_MINUTE: Int = 500000


# =============================================================================
# SEQUENCE LENGTH GOVERNOR (G4 Fix)
# =============================================================================

struct SequenceLengthGuard:
    """
    Enforces maximum sequence length to prevent unbounded KV cache growth.
    
    Per the paper (Section XI): KV cache memory = O(2·N·n_kv·d_k·L)
    where L is sequence length. Without a bound, L can grow until OOM.
    """
    var max_length: Int
    var current_length: Int
    var exceeded: Bool
    
    fn __init__(out self, max_length: Int = MAX_SEQUENCE_LENGTH):
        self.max_length = max_length
        self.current_length = 0
        self.exceeded = False
    
    fn can_append(self, num_tokens: Int) -> Bool:
        """Check if we can append num_tokens without exceeding limit."""
        return (self.current_length + num_tokens) <= self.max_length
    
    fn append(mut self, num_tokens: Int) raises:
        """
        Attempt to append tokens to the sequence.
        Raises if this would exceed the maximum sequence length.
        """
        if not self.can_append(num_tokens):
            self.exceeded = True
            raise Error(
                "Sequence length limit exceeded: " + 
                String(self.current_length + num_tokens) + 
                " > " + String(self.max_length)
            )
        self.current_length += num_tokens
    
    fn remaining_capacity(self) -> Int:
        """Return how many more tokens can be appended."""
        if self.current_length >= self.max_length:
            return 0
        return self.max_length - self.current_length
    
    fn reset(mut self):
        """Reset the guard for a new sequence."""
        self.current_length = 0
        self.exceeded = False


# =============================================================================
# RESOURCE GOVERNOR (G8 Fix)
# =============================================================================

struct ResourceGovernor:
    """
    Enforces resource quotas to prevent resource exhaustion attacks.
    
    Tracks:
    - Memory usage
    - Concurrent requests
    - Tokens generated per time window
    - Request rate per time window
    """
    var max_memory_bytes: Int
    var current_memory_bytes: Int
    var max_concurrent_requests: Int
    var current_concurrent_requests: Int
    var tokens_this_minute: Int
    var requests_this_minute: Int
    var minute_start_time: Int
    
    fn __init__(
        out self,
        max_memory_gb: Int = MAX_MEMORY_GB,
        max_concurrent: Int = MAX_CONCURRENT_REQUESTS
    ):
        self.max_memory_bytes = max_memory_gb * 1024 * 1024 * 1024
        self.current_memory_bytes = 0
        self.max_concurrent_requests = max_concurrent
        self.current_concurrent_requests = 0
        self.tokens_this_minute = 0
        self.requests_this_minute = 0
        self.minute_start_time = now()
    
    fn check_rate_limits(mut self) raises:
        """Check and update rate limits. Raises if exceeded."""
        var current_time = now()
        var elapsed = current_time - self.minute_start_time
        
        # Reset counters every minute
        if elapsed >= 60_000_000_000:  # 60 seconds in nanoseconds
            self.tokens_this_minute = 0
            self.requests_this_minute = 0
            self.minute_start_time = current_time
        
        # Check limits
        if self.requests_this_minute >= MAX_REQUESTS_PER_MINUTE:
            raise Error("Rate limit exceeded: too many requests per minute")
        if self.tokens_this_minute >= MAX_TOKENS_PER_MINUTE:
            raise Error("Rate limit exceeded: too many tokens per minute")
    
    fn acquire_request(mut self) raises:
        """Acquire a slot for a new request."""
        self.check_rate_limits()
        
        if self.current_concurrent_requests >= self.max_concurrent_requests:
            raise Error("Concurrent request limit exceeded")
        
        self.current_concurrent_requests += 1
        self.requests_this_minute += 1
    
    fn release_request(mut self):
        """Release a request slot."""
        if self.current_concurrent_requests > 0:
            self.current_concurrent_requests -= 1
    
    fn record_tokens(mut self, count: Int):
        """Record tokens generated for rate limiting."""
        self.tokens_this_minute += count
    
    fn allocate_memory(mut self, bytes: Int) raises:
        """Request memory allocation."""
        if self.current_memory_bytes + bytes > self.max_memory_bytes:
            raise Error(
                "Memory limit exceeded: would use " +
                String((self.current_memory_bytes + bytes) // (1024 * 1024)) +
                "MB of " + String(self.max_memory_bytes // (1024 * 1024)) + "MB"
            )
        self.current_memory_bytes += bytes
    
    fn free_memory(mut self, bytes: Int):
        """Record memory freed."""
        self.current_memory_bytes -= bytes
        if self.current_memory_bytes < 0:
            self.current_memory_bytes = 0


# =============================================================================
# KV CACHE WITH SAFETY BOUNDS
# =============================================================================

struct SafeKVCache[T: DType]:
    """
    KV Cache with built-in sequence length limits (G4 fix).
    
    Memory layout: [num_layers, 2, max_seq_len, num_heads, head_dim]
    Where 2 = {Key, Value}
    """
    var data: UnsafePointer[Scalar[T]]
    var num_layers: Int
    var max_seq_len: Int
    var num_heads: Int
    var head_dim: Int
    var current_seq_len: Int
    var seq_guard: SequenceLengthGuard
    
    fn __init__(
        out self,
        num_layers: Int,
        max_seq_len: Int,
        num_heads: Int,
        head_dim: Int
    ):
        self.num_layers = num_layers
        self.max_seq_len = min(max_seq_len, MAX_SEQUENCE_LENGTH)
        self.num_heads = num_heads
        self.head_dim = head_dim
        self.current_seq_len = 0
        self.seq_guard = SequenceLengthGuard(self.max_seq_len)
        
        # Allocate memory
        var total_elements = num_layers * 2 * self.max_seq_len * num_heads * head_dim
        self.data = alloc[Scalar[T]](total_elements)
    
    fn append_kv(
        mut self,
        layer: Int,
        key: UnsafePointer[Scalar[T]],
        value: UnsafePointer[Scalar[T]],
        num_tokens: Int
    ) raises:
        """
        Append key-value pairs to the cache for a specific layer.
        Raises if this would exceed the sequence length limit.
        """
        # G4 SAFETY CHECK: Enforce sequence length limit
        self.seq_guard.append(num_tokens)
        
        var head_size = self.num_heads * self.head_dim
        var layer_stride = 2 * self.max_seq_len * head_size
        var kv_stride = self.max_seq_len * head_size
        var seq_stride = head_size
        
        # Copy keys
        var k_base = self.data + layer * layer_stride + self.current_seq_len * seq_stride
        for i in range(num_tokens * head_size):
            k_base[i] = key[i]
        
        # Copy values
        var v_base = self.data + layer * layer_stride + kv_stride + self.current_seq_len * seq_stride
        for i in range(num_tokens * head_size):
            v_base[i] = value[i]
        
        self.current_seq_len += num_tokens
    
    fn get_keys(self, layer: Int) -> UnsafePointer[Scalar[T]]:
        """Get pointer to keys for a layer."""
        var head_size = self.num_heads * self.head_dim
        var layer_stride = 2 * self.max_seq_len * head_size
        return self.data + layer * layer_stride
    
    fn get_values(self, layer: Int) -> UnsafePointer[Scalar[T]]:
        """Get pointer to values for a layer."""
        var head_size = self.num_heads * self.head_dim
        var layer_stride = 2 * self.max_seq_len * head_size
        var kv_stride = self.max_seq_len * head_size
        return self.data + layer * layer_stride + kv_stride
    
    fn remaining_capacity(self) -> Int:
        """Return how many more tokens can be cached."""
        return self.seq_guard.remaining_capacity()
    
    fn reset(mut self):
        """Reset the cache for a new sequence."""
        self.current_seq_len = 0
        self.seq_guard.reset()
    
    fn memory_bytes(self) -> Int:
        """Return memory used by this cache."""
        var total_elements = self.num_layers * 2 * self.max_seq_len * self.num_heads * self.head_dim
        return total_elements * sizeof[T]()
    
    fn __del__(owned self):
        self.data.free()


# =============================================================================
# INFERENCE REQUEST WITH SAFETY VALIDATION
# =============================================================================

struct SafeInferenceRequest:
    """
    Inference request with built-in safety validation.
    Ensures all requests comply with resource limits.
    """
    var request_id: String
    var model_id: String
    var input_tokens: Int
    var max_output_tokens: Int
    var temperature: Float32
    var top_k: Int
    var top_p: Float32
    var validated: Bool
    
    fn __init__(
        out self,
        request_id: String,
        model_id: String,
        input_tokens: Int,
        max_output_tokens: Int,
        temperature: Float32 = 1.0,
        top_k: Int = 40,
        top_p: Float32 = 0.95
    ):
        self.request_id = request_id
        self.model_id = model_id
        self.input_tokens = input_tokens
        self.max_output_tokens = max_output_tokens
        self.temperature = temperature
        self.top_k = top_k
        self.top_p = top_p
        self.validated = False
    
    fn validate(mut self) raises:
        """
        Validate request parameters against safety limits.
        Must be called before processing the request.
        """
        # Validate input tokens
        if self.input_tokens <= 0:
            raise Error("Invalid input token count: " + String(self.input_tokens))
        
        if self.input_tokens > MAX_TOKENS_PER_REQUEST:
            raise Error(
                "Input tokens exceed limit: " + String(self.input_tokens) +
                " > " + String(MAX_TOKENS_PER_REQUEST)
            )
        
        # Validate output tokens
        if self.max_output_tokens <= 0:
            raise Error("Invalid max output tokens: " + String(self.max_output_tokens))
        
        if self.max_output_tokens > MAX_TOKENS_PER_REQUEST:
            raise Error(
                "Max output tokens exceed limit: " + String(self.max_output_tokens) +
                " > " + String(MAX_TOKENS_PER_REQUEST)
            )
        
        # Validate total sequence length
        var total = self.input_tokens + self.max_output_tokens
        if total > MAX_SEQUENCE_LENGTH:
            raise Error(
                "Total sequence length exceeds limit: " + String(total) +
                " > " + String(MAX_SEQUENCE_LENGTH)
            )
        
        # Validate temperature (G2 related)
        if self.temperature < 0:
            raise Error("Temperature cannot be negative: " + String(self.temperature))
        
        # Validate top_k
        if self.top_k <= 0:
            raise Error("top_k must be positive: " + String(self.top_k))
        
        # Validate top_p
        if self.top_p <= 0 or self.top_p > 1:
            raise Error("top_p must be in (0, 1]: " + String(self.top_p))
        
        self.validated = True
    
    fn is_validated(self) -> Bool:
        return self.validated


# =============================================================================
# SAFETY AUDIT EVENTS
# =============================================================================

struct SafetyAuditEvent:
    """
    Audit event for safety-relevant operations.
    These can be emitted as Mangle facts for governance tracking.
    """
    var event_type: String  # "request_start", "request_end", "safety_violation", etc.
    var request_id: String
    var model_id: String
    var timestamp: Int
    var input_tokens: Int
    var output_tokens: Int
    var latency_ms: Int
    var status: String  # "success", "error", "rate_limited", etc.
    var error_message: String
    
    fn __init__(out self, event_type: String, request_id: String, model_id: String):
        self.event_type = event_type
        self.request_id = request_id
        self.model_id = model_id
        self.timestamp = now()
        self.input_tokens = 0
        self.output_tokens = 0
        self.latency_ms = 0
        self.status = "pending"
        self.error_message = ""
    
    fn to_mangle_fact(self) -> String:
        """Convert to Mangle fact string for governance integration."""
        if self.event_type == "request_start":
            return (
                "inference_request(\"" + self.request_id + "\", \"" + 
                self.model_id + "\", " + String(self.input_tokens) + 
                ", " + String(self.timestamp) + ")."
            )
        elif self.event_type == "request_end":
            return (
                "inference_result(\"" + self.request_id + "\", " +
                String(self.output_tokens) + ", " + String(self.latency_ms) +
                ", \"" + self.status + "\")."
            )
        elif self.event_type == "safety_violation":
            return (
                "safety_violation(\"" + self.request_id + "\", \"" +
                self.error_message + "\", " + String(self.timestamp) + ")."
            )
        else:
            return "audit_event(\"" + self.event_type + "\", \"" + self.request_id + "\")."