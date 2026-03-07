"""
Lazy model loading system for efficient memory management.

Provides:
- On-demand model weight loading
- Memory-mapped file access
- Model caching with LRU eviction
- Background loading and warm-up
- Model state management
"""

from memory import memset_zero, memcpy
from sys.info import simdwidthof
from algorithm import parallelize
from time import now
from sys import external_call
from sys.ffi import c_int, c_size_t, c_ssize_t


alias FloatType = DType.float32
alias MAX_MODELS = 16
alias MAX_PATH_LEN = 512


# =============================================================================
# Model Load State
# =============================================================================

@value
struct ModelLoadState:
    """Enumeration of model loading states."""
    alias UNLOADED = 0
    alias LOADING = 1
    alias LOADED = 2
    alias FAILED = 3
    alias UNLOADING = 4


struct ModelMetadata:
    """Metadata about a model without loading weights."""
    var model_id: String
    var path: String
    var vocab_size: Int
    var embed_dim: Int
    var num_layers: Int
    var num_heads: Int
    var ffn_dim: Int
    var max_seq_len: Int
    var file_size_bytes: Int
    var parameter_count: Int
    var quantization: String  # "none", "int8", "int4"
    
    fn __init__(inout self, model_id: String, path: String):
        self.model_id = model_id
        self.path = path
        self.vocab_size = 0
        self.embed_dim = 0
        self.num_layers = 0
        self.num_heads = 0
        self.ffn_dim = 0
        self.max_seq_len = 0
        self.file_size_bytes = 0
        self.parameter_count = 0
        self.quantization = "none"
    
    fn estimated_memory_gb(self) -> Float32:
        """Estimate memory required to load this model."""
        # Rough estimate: 4 bytes per float32 parameter
        var bytes_per_param = 4
        if self.quantization == "int8":
            bytes_per_param = 1
        elif self.quantization == "int4":
            bytes_per_param = 1  # Packed, but simplify
        
        return Float32(self.parameter_count * bytes_per_param) / (1024 * 1024 * 1024)


# =============================================================================
# Lazy Weight Buffer
# =============================================================================

struct LazyWeightBuffer:
    """
    A weight buffer that loads on first access.
    Supports memory-mapped and chunked loading.
    """
    var data: UnsafePointer[Scalar[FloatType]]
    var size: Int
    var is_loaded: Bool
    var is_mmap: Bool
    var file_path: String
    var file_offset: Int
    
    fn __init__(inout self, size: Int, file_path: String = "", file_offset: Int = 0):
        self.data = UnsafePointer[Scalar[FloatType]]()
        self.size = size
        self.is_loaded = False
        self.is_mmap = False
        self.file_path = file_path
        self.file_offset = file_offset
    
    fn ensure_loaded(inout self) -> Bool:
        """
        Ensure the weight buffer is loaded. Returns True on success.
        Opens the file at file_path, seeks to file_offset, and reads
        self.size float32 values (self.size * 4 bytes) into the buffer.
        """
        if self.is_loaded:
            return True

        if self.file_path == "":
            return False

        # Allocate memory for the weight data.
        self.data = UnsafePointer[Scalar[FloatType]].alloc(self.size)
        if not self.data:
            return False

        var byte_count = self.size * 4  # float32 = 4 bytes

        # Open the file (POSIX open: flags=O_RDONLY=0, mode=0).
        var fd = external_call["open", c_int](
            self.file_path.unsafe_ptr(), c_int(0)
        )
        if fd < 0:
            self.data.free()
            self.data = UnsafePointer[Scalar[FloatType]]()
            return False

        # Seek to the weight data offset (lseek: SEEK_SET=0).
        var seeked = external_call["lseek", c_ssize_t](
            fd, c_ssize_t(self.file_offset), c_int(0)
        )
        if seeked < 0:
            _ = external_call["close", c_int](fd)
            self.data.free()
            self.data = UnsafePointer[Scalar[FloatType]]()
            return False

        # Read all bytes, retrying on short reads.
        var dest = self.data.bitcast[UInt8]()
        var remaining = byte_count
        var read_offset = 0
        while remaining > 0:
            var n = external_call["read", c_ssize_t](
                fd, dest + read_offset, c_size_t(remaining)
            )
            if n <= 0:
                _ = external_call["close", c_int](fd)
                self.data.free()
                self.data = UnsafePointer[Scalar[FloatType]]()
                return False
            read_offset += Int(n)
            remaining -= Int(n)

        _ = external_call["close", c_int](fd)
        self.is_loaded = True
        return True
    
    fn unload(inout self):
        """Release the weight buffer memory."""
        if self.is_loaded and self.data:
            if not self.is_mmap:
                self.data.free()
            self.data = UnsafePointer[Scalar[FloatType]]()
            self.is_loaded = False
    
    fn get(inout self) -> UnsafePointer[Scalar[FloatType]]:
        """Get the weight data, loading if necessary."""
        _ = self.ensure_loaded()
        return self.data
    
    fn __del__(owned self):
        self.unload()


# =============================================================================
# Lazy Model Weights
# =============================================================================

struct LazyModelWeights:
    """
    Model weights with lazy loading support.
    Only loads weight tensors when they are first accessed.
    """
    var metadata: ModelMetadata
    var load_state: Int
    var load_error: String
    
    # Token embedding - always loaded first for tokenization
    var token_embed: LazyWeightBuffer
    var token_embed_loaded: Bool
    
    # Layer weights - loaded on-demand per layer
    var layer_weights_loaded: UnsafePointer[Bool]
    var wq: UnsafePointer[LazyWeightBuffer]
    var wk: UnsafePointer[LazyWeightBuffer]
    var wv: UnsafePointer[LazyWeightBuffer]
    var wo: UnsafePointer[LazyWeightBuffer]
    var w1: UnsafePointer[LazyWeightBuffer]
    var w2: UnsafePointer[LazyWeightBuffer]
    var w3: UnsafePointer[LazyWeightBuffer]
    var ln1: UnsafePointer[LazyWeightBuffer]
    var ln2: UnsafePointer[LazyWeightBuffer]
    
    # Final layer norm and LM head
    var ln_final: LazyWeightBuffer
    var lm_head: LazyWeightBuffer
    var ln_final_loaded: Bool
    var lm_head_loaded: Bool
    
    # Per-layer access timestamps for fine-grained LRU eviction.
    var layer_last_used: UnsafePointer[Int]

    # Statistics
    var total_layers_loaded: Int
    var memory_used_bytes: Int
    var last_access_time: Int
    
    fn __init__(inout self, metadata: ModelMetadata):
        self.metadata = metadata
        self.load_state = ModelLoadState.UNLOADED
        self.load_error = ""
        
        var embed_size = metadata.vocab_size * metadata.embed_dim
        var attn_size = metadata.embed_dim * metadata.embed_dim
        var ffn_up_size = metadata.embed_dim * metadata.ffn_dim
        var ffn_down_size = metadata.ffn_dim * metadata.embed_dim
        var lm_head_size = metadata.embed_dim * metadata.vocab_size
        
        # Initialize embedding buffers
        self.token_embed = LazyWeightBuffer(embed_size, metadata.path, 0)
        self.token_embed_loaded = False
        
        # Initialize layer weight buffers
        var num_layers = metadata.num_layers
        self.layer_weights_loaded = UnsafePointer[Bool].alloc(num_layers)
        self.layer_last_used = UnsafePointer[Int].alloc(num_layers)
        self.wq = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.wk = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.wv = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.wo = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.w1 = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.w2 = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.w3 = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.ln1 = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        self.ln2 = UnsafePointer[LazyWeightBuffer].alloc(num_layers)
        
        var base_offset = embed_size * 4  # After token embeddings (bytes)

        # Byte size of each weight matrix in this layout (float32 = 4 bytes).
        var attn_bytes    = attn_size    * 4
        var ffn_up_bytes  = ffn_up_size  * 4
        var ffn_down_bytes = ffn_down_size * 4
        var ln_bytes      = metadata.embed_dim * 4

        # Total bytes per layer:
        #   wq + wk + wv + wo  (4 × attn_bytes)
        #   w1 + w3            (2 × ffn_up_bytes)
        #   w2                 (1 × ffn_down_bytes)
        #   ln1 + ln2          (2 × ln_bytes)
        var layer_stride = 4 * attn_bytes + 2 * ffn_up_bytes + ffn_down_bytes + 2 * ln_bytes

        for i in range(num_layers):
            self.layer_weights_loaded[i] = False
            self.layer_last_used[i] = 0
            var layer_offset = base_offset + i * layer_stride

            # Attention projections (contiguous in file order: Q, K, V, O).
            self.wq[i] = LazyWeightBuffer(attn_size,    metadata.path, layer_offset)
            self.wk[i] = LazyWeightBuffer(attn_size,    metadata.path, layer_offset + attn_bytes)
            self.wv[i] = LazyWeightBuffer(attn_size,    metadata.path, layer_offset + 2 * attn_bytes)
            self.wo[i] = LazyWeightBuffer(attn_size,    metadata.path, layer_offset + 3 * attn_bytes)

            # FFN projections (gate, up, down).
            var ffn_base = layer_offset + 4 * attn_bytes
            self.w1[i] = LazyWeightBuffer(ffn_up_size,  metadata.path, ffn_base)
            self.w3[i] = LazyWeightBuffer(ffn_up_size,  metadata.path, ffn_base + ffn_up_bytes)
            self.w2[i] = LazyWeightBuffer(ffn_down_size, metadata.path, ffn_base + 2 * ffn_up_bytes)

            # Layer norms (ln1 before attention, ln2 before FFN).
            var ln_base = ffn_base + 2 * ffn_up_bytes + ffn_down_bytes
            self.ln1[i] = LazyWeightBuffer(metadata.embed_dim, metadata.path, ln_base)
            self.ln2[i] = LazyWeightBuffer(metadata.embed_dim, metadata.path, ln_base + ln_bytes)
        
        # Final buffers — placed immediately after all layer data.
        var final_base = base_offset + num_layers * layer_stride
        self.ln_final = LazyWeightBuffer(metadata.embed_dim, metadata.path, final_base)
        self.lm_head  = LazyWeightBuffer(lm_head_size, metadata.path, final_base + ln_bytes)
        self.ln_final_loaded = False
        self.lm_head_loaded = False
        
        self.total_layers_loaded = 0
        self.memory_used_bytes = 0
        self.last_access_time = 0
    
    fn load_embeddings(inout self) -> Bool:
        """Load token embeddings (required for all operations)."""
        if self.token_embed_loaded:
            return True
        
        self.load_state = ModelLoadState.LOADING
        if self.token_embed.ensure_loaded():
            self.token_embed_loaded = True
            self.memory_used_bytes += self.token_embed.size * 4
            return True
        
        self.load_state = ModelLoadState.FAILED
        self.load_error = "Failed to load token embeddings"
        return False
    
    fn load_layer(inout self, layer_idx: Int) -> Bool:
        """Load weights for a specific transformer layer."""
        if layer_idx < 0 or layer_idx >= self.metadata.num_layers:
            return False
        
        if self.layer_weights_loaded[layer_idx]:
            return True
        
        # Load all weights for this layer
        var success = True
        success = success and self.wq[layer_idx].ensure_loaded()
        success = success and self.wk[layer_idx].ensure_loaded()
        success = success and self.wv[layer_idx].ensure_loaded()
        success = success and self.wo[layer_idx].ensure_loaded()
        success = success and self.w1[layer_idx].ensure_loaded()
        success = success and self.w2[layer_idx].ensure_loaded()
        success = success and self.w3[layer_idx].ensure_loaded()
        success = success and self.ln1[layer_idx].ensure_loaded()
        success = success and self.ln2[layer_idx].ensure_loaded()
        
        if success:
            self.layer_weights_loaded[layer_idx] = True
            self.layer_last_used[layer_idx] = int(now())
            self.total_layers_loaded += 1
            # Update memory tracking
            var layer_mem = (
                self.wq[layer_idx].size + self.wk[layer_idx].size + 
                self.wv[layer_idx].size + self.wo[layer_idx].size +
                self.w1[layer_idx].size + self.w2[layer_idx].size +
                self.w3[layer_idx].size + self.ln1[layer_idx].size +
                self.ln2[layer_idx].size
            ) * 4
            self.memory_used_bytes += layer_mem
        
        return success
    
    fn load_output_layers(inout self) -> Bool:
        """Load final layer norm and LM head."""
        if self.ln_final_loaded and self.lm_head_loaded:
            return True
        
        if not self.ln_final_loaded:
            if self.ln_final.ensure_loaded():
                self.ln_final_loaded = True
                self.memory_used_bytes += self.ln_final.size * 4
            else:
                return False
        
        if not self.lm_head_loaded:
            if self.lm_head.ensure_loaded():
                self.lm_head_loaded = True
                self.memory_used_bytes += self.lm_head.size * 4
            else:
                return False
        
        return True
    
    fn load_all(inout self) -> Bool:
        """Load all model weights."""
        if not self.load_embeddings():
            return False
        
        for i in range(self.metadata.num_layers):
            if not self.load_layer(i):
                return False
        
        if not self.load_output_layers():
            return False
        
        self.load_state = ModelLoadState.LOADED
        return True
    
    fn unload_layer(inout self, layer_idx: Int):
        """Unload a specific layer to free memory."""
        if layer_idx < 0 or layer_idx >= self.metadata.num_layers:
            return
        
        if not self.layer_weights_loaded[layer_idx]:
            return
        
        var layer_mem = (
            self.wq[layer_idx].size + self.wk[layer_idx].size + 
            self.wv[layer_idx].size + self.wo[layer_idx].size +
            self.w1[layer_idx].size + self.w2[layer_idx].size +
            self.w3[layer_idx].size + self.ln1[layer_idx].size +
            self.ln2[layer_idx].size
        ) * 4
        
        self.wq[layer_idx].unload()
        self.wk[layer_idx].unload()
        self.wv[layer_idx].unload()
        self.wo[layer_idx].unload()
        self.w1[layer_idx].unload()
        self.w2[layer_idx].unload()
        self.w3[layer_idx].unload()
        self.ln1[layer_idx].unload()
        self.ln2[layer_idx].unload()
        
        self.layer_weights_loaded[layer_idx] = False
        self.total_layers_loaded -= 1
        self.memory_used_bytes -= layer_mem
    
    fn unload_all(inout self):
        """Unload all model weights."""
        self.token_embed.unload()
        self.token_embed_loaded = False
        
        for i in range(self.metadata.num_layers):
            self.unload_layer(i)
        
        self.ln_final.unload()
        self.lm_head.unload()
        self.ln_final_loaded = False
        self.lm_head_loaded = False
        
        self.memory_used_bytes = 0
        self.load_state = ModelLoadState.UNLOADED
    
    fn is_fully_loaded(self) -> Bool:
        """Check if all weights are loaded."""
        return self.load_state == ModelLoadState.LOADED
    
    fn get_load_progress(self) -> Float32:
        """Get loading progress as a percentage (0.0 - 1.0)."""
        var total_parts = self.metadata.num_layers + 3  # layers + embed + ln_final + lm_head
        var loaded_parts = self.total_layers_loaded
        if self.token_embed_loaded:
            loaded_parts += 1
        if self.ln_final_loaded:
            loaded_parts += 1
        if self.lm_head_loaded:
            loaded_parts += 1
        return Float32(loaded_parts) / Float32(total_parts)


# =============================================================================
# Model Manager with LRU Cache
# =============================================================================

struct CachedModel:
    """A model entry in the cache."""
    var weights: LazyModelWeights
    var last_used: Int  # Timestamp for LRU
    var use_count: Int
    var is_pinned: Bool  # Pinned models are not evicted
    
    fn __init__(inout self, weights: owned LazyModelWeights):
        self.weights = weights^
        self.last_used = 0
        self.use_count = 0
        self.is_pinned = False


struct ModelManager:
    """
    Manages multiple models with lazy loading and LRU eviction.
    """
    var models: UnsafePointer[CachedModel]
    var model_count: Int
    var max_models: Int
    var max_memory_bytes: Int
    var current_memory_bytes: Int
    var eviction_enabled: Bool
    
    fn __init__(inout self, max_models: Int = MAX_MODELS, max_memory_gb: Float32 = 8.0):
        self.models = UnsafePointer[CachedModel].alloc(max_models)
        self.model_count = 0
        self.max_models = max_models
        self.max_memory_bytes = int(max_memory_gb * 1024 * 1024 * 1024)
        self.current_memory_bytes = 0
        self.eviction_enabled = True
    
    fn register_model(inout self, metadata: ModelMetadata) -> Int:
        """
        Register a model (doesn't load it).
        Returns model index or -1 on failure.
        """
        if self.model_count >= self.max_models:
            if self.eviction_enabled:
                self.evict_lru()
            else:
                return -1
        
        var weights = LazyModelWeights(metadata)
        var cached = CachedModel(weights^)
        
        var idx = self.model_count
        self.models[idx] = cached^
        self.model_count += 1
        return idx
    
    fn get_model(inout self, model_idx: Int) -> UnsafePointer[LazyModelWeights]:
        """
        Get a model by index, triggering lazy load if needed.
        Updates LRU tracking.
        """
        if model_idx < 0 or model_idx >= self.model_count:
            return UnsafePointer[LazyModelWeights]()
        
        # Update LRU
        self.models[model_idx].last_used = int(now())
        self.models[model_idx].use_count += 1
        
        return UnsafePointer.address_of(self.models[model_idx].weights)
    
    fn load_model(inout self, model_idx: Int, preload_layers: Int = 0) -> Bool:
        """
        Load a model's weights. Optionally preload some layers.
        
        Args:
            model_idx: Model index
            preload_layers: Number of layers to preload (0 = embeddings only)
        """
        if model_idx < 0 or model_idx >= self.model_count:
            return False
        
        var weights = UnsafePointer.address_of(self.models[model_idx].weights)
        
        # Check memory before loading
        var estimated_mem = self.models[model_idx].weights.metadata.estimated_memory_gb()
        var estimated_bytes = int(estimated_mem * 1024 * 1024 * 1024)
        
        while self.current_memory_bytes + estimated_bytes > self.max_memory_bytes:
            if self.eviction_enabled:
                if not self.evict_lru():
                    return False  # Can't evict anything
            else:
                return False
        
        # Load embeddings
        if not weights[].load_embeddings():
            return False
        
        # Load output layers
        if not weights[].load_output_layers():
            return False
        
        # Preload specified layers
        for i in range(min(preload_layers, weights[].metadata.num_layers)):
            if not weights[].load_layer(i):
                return False
        
        self.current_memory_bytes = self.calculate_total_memory()
        return True
    
    fn ensure_layer_loaded(inout self, model_idx: Int, layer_idx: Int) -> Bool:
        """
        Ensure a specific layer is loaded for a model.
        Called during inference to lazy-load layers as needed.
        """
        if model_idx < 0 or model_idx >= self.model_count:
            return False
        
        var weights = UnsafePointer.address_of(self.models[model_idx].weights)
        
        if weights[].layer_weights_loaded[layer_idx]:
            return True
        
        # Check memory
        var layer_size = self.estimate_layer_size(weights[])
        
        while self.current_memory_bytes + layer_size > self.max_memory_bytes:
            if self.eviction_enabled:
                if not self.evict_lru_layer(model_idx):
                    return False
            else:
                return False
        
        var success = weights[].load_layer(layer_idx)
        if success:
            self.current_memory_bytes = self.calculate_total_memory()
        return success
    
    fn unload_model(inout self, model_idx: Int):
        """Fully unload a model's weights."""
        if model_idx < 0 or model_idx >= self.model_count:
            return
        
        self.models[model_idx].weights.unload_all()
        self.current_memory_bytes = self.calculate_total_memory()
    
    fn pin_model(inout self, model_idx: Int):
        """Pin a model to prevent eviction."""
        if model_idx >= 0 and model_idx < self.model_count:
            self.models[model_idx].is_pinned = True
    
    fn unpin_model(inout self, model_idx: Int):
        """Unpin a model to allow eviction."""
        if model_idx >= 0 and model_idx < self.model_count:
            self.models[model_idx].is_pinned = False
    
    fn evict_lru(inout self) -> Bool:
        """Evict the least recently used unpinned model."""
        var oldest_time = 9223372036854775807  # Max Int
        var oldest_idx = -1
        
        for i in range(self.model_count):
            if not self.models[i].is_pinned and self.models[i].weights.memory_used_bytes > 0:
                if self.models[i].last_used < oldest_time:
                    oldest_time = self.models[i].last_used
                    oldest_idx = i
        
        if oldest_idx >= 0:
            self.unload_model(oldest_idx)
            return True
        return False
    
    fn evict_lru_layer(inout self, exclude_model: Int) -> Bool:
        """
        Evict the single coldest loaded layer across all unpinned models,
        using per-layer last_used timestamps for accurate LRU selection.
        """
        var oldest_time = 9223372036854775807  # Max Int
        var oldest_model = -1
        var oldest_layer = -1

        for m in range(self.model_count):
            if m == exclude_model or self.models[m].is_pinned:
                continue

            var num_layers = self.models[m].weights.metadata.num_layers
            for l in range(num_layers):
                if self.models[m].weights.layer_weights_loaded[l]:
                    # Use per-layer timestamp for accurate LRU selection.
                    var layer_ts = self.models[m].weights.layer_last_used[l]
                    if layer_ts < oldest_time:
                        oldest_time = layer_ts
                        oldest_model = m
                        oldest_layer = l

        if oldest_model >= 0 and oldest_layer >= 0:
            self.models[oldest_model].weights.unload_layer(oldest_layer)
            self.current_memory_bytes = self.calculate_total_memory()
            return True
        return False
    
    fn estimate_layer_size(self, weights: LazyModelWeights) -> Int:
        """Estimate memory for one transformer layer."""
        var embed_dim = weights.metadata.embed_dim
        var ffn_dim = weights.metadata.ffn_dim
        
        var attn = embed_dim * embed_dim * 4  # Q, K, V, O
        var ffn = embed_dim * ffn_dim * 2 + ffn_dim * embed_dim  # w1, w2, w3
        var ln = embed_dim * 2  # ln1, ln2
        
        return (attn + ffn + ln) * 4  # Float32 = 4 bytes
    
    fn calculate_total_memory(self) -> Int:
        """Calculate total memory used by all models."""
        var total = 0
        for i in range(self.model_count):
            total += self.models[i].weights.memory_used_bytes
        return total
    
    fn get_stats(self) -> String:
        """Get memory and model statistics."""
        var total_gb = Float32(self.current_memory_bytes) / (1024 * 1024 * 1024)
        var max_gb = Float32(self.max_memory_bytes) / (1024 * 1024 * 1024)
        return "Models: " + str(self.model_count) + ", Memory: " + str(total_gb) + "/" + str(max_gb) + " GB"
    
    fn __del__(owned self):
        for i in range(self.model_count):
            self.models[i].weights.unload_all()
        self.models.free()