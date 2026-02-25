# LoRA (Low-Rank Adaptation) Support
#
# Implements efficient LoRA adapter support for fine-tuned models.
# Enables serving multiple fine-tuned models from a single base model.
#
# Features:
# - Low-rank adaptation matrices (A, B)
# - Dynamic adapter loading/unloading
# - Multiple adapters per request
# - Efficient batched inference
# - Adapter merging

from tensor import Tensor, TensorShape
from memory import memcpy
from math import sqrt

# ==============================================
# LoRA Configuration
# ==============================================

struct LoRAConfig:
    """Configuration for LoRA adapter."""
    var rank: Int                    # LoRA rank (r)
    var alpha: Float32               # LoRA alpha (scaling)
    var dropout: Float32             # Dropout probability
    var target_modules: List[String] # Which modules to apply LoRA
    var fan_in_fan_out: Bool         # For some models like GPT-2
    var bias: String                 # "none", "all", or "lora_only"
    var use_rslora: Bool             # Rank-stabilized LoRA
    var use_dora: Bool               # Weight-decomposed LoRA
    
    fn __init__(inout self,
                rank: Int = 8,
                alpha: Float32 = 16.0,
                dropout: Float32 = 0.0,
                fan_in_fan_out: Bool = False,
                bias: String = "none",
                use_rslora: Bool = False,
                use_dora: Bool = False):
        self.rank = rank
        self.alpha = alpha
        self.dropout = dropout
        self.fan_in_fan_out = fan_in_fan_out
        self.bias = bias
        self.use_rslora = use_rslora
        self.use_dora = use_dora
        
        # Default target modules for LLMs
        self.target_modules = List[String]()
        self.target_modules.append("q_proj")
        self.target_modules.append("k_proj")
        self.target_modules.append("v_proj")
        self.target_modules.append("o_proj")
        self.target_modules.append("gate_proj")
        self.target_modules.append("up_proj")
        self.target_modules.append("down_proj")
    
    fn scaling(self) -> Float32:
        """Get LoRA scaling factor."""
        if self.use_rslora:
            # Rank-stabilized: alpha / sqrt(r)
            return self.alpha / sqrt(Float32(self.rank))
        else:
            # Standard: alpha / r
            return self.alpha / Float32(self.rank)

# ==============================================
# LoRA Layer
# ==============================================

struct LoRALayer:
    """A single LoRA adapter layer."""
    var name: String
    var in_features: Int
    var out_features: Int
    var rank: Int
    var scaling: Float32
    
    # LoRA matrices: W = W_0 + BA (where B: [out, r], A: [r, in])
    var lora_A: Tensor[DType.float32]  # [rank, in_features]
    var lora_B: Tensor[DType.float32]  # [out_features, rank]
    
    # Optional: bias
    var lora_bias: Optional[Tensor[DType.float32]]
    
    # For DoRA: magnitude vector
    var magnitude: Optional[Tensor[DType.float32]]
    
    fn __init__(inout self,
                name: String,
                in_features: Int,
                out_features: Int,
                config: LoRAConfig):
        self.name = name
        self.in_features = in_features
        self.out_features = out_features
        self.rank = config.rank
        self.scaling = config.scaling()
        
        # Initialize A with Kaiming uniform, B with zeros
        self.lora_A = Tensor[DType.float32](
            TensorShape(config.rank, in_features)
        )
        self.lora_B = Tensor[DType.float32](
            TensorShape(out_features, config.rank)
        )
        
        # Kaiming initialization for A
        let bound = sqrt(3.0 / Float32(in_features))
        # Would initialize with uniform(-bound, bound)
        
        # B initialized to zeros (so initial delta is 0)
        # Would call zeros initialization
        
        self.lora_bias = None
        self.magnitude = None
        
        if config.use_dora:
            self.magnitude = Tensor[DType.float32](TensorShape(out_features))
    
    fn forward(self,
               x: Tensor[DType.float32],
               base_result: Tensor[DType.float32]) -> Tensor[DType.float32]:
        """Apply LoRA adaptation.
        
        Args:
            x: Input tensor [batch, seq_len, in_features]
            base_result: Output from base layer [batch, seq_len, out_features]
            
        Returns:
            Adapted output: base_result + scaling * (x @ A^T @ B^T)
        """
        let batch_size = x.shape()[0]
        let seq_len = x.shape()[1]
        
        # LoRA forward: x @ A^T @ B^T * scaling
        # 1. x @ A^T: [B, S, in] @ [in, r] -> [B, S, r]
        var lora_hidden = Tensor[DType.float32](
            TensorShape(batch_size, seq_len, self.rank)
        )
        # matmul(x, self.lora_A.T, lora_hidden)
        
        # 2. lora_hidden @ B^T: [B, S, r] @ [r, out] -> [B, S, out]
        var lora_output = Tensor[DType.float32](
            TensorShape(batch_size, seq_len, self.out_features)
        )
        # matmul(lora_hidden, self.lora_B.T, lora_output)
        
        # 3. Scale and add to base
        # result = base_result + scaling * lora_output
        var result = Tensor[DType.float32](base_result.shape())
        for i in range(result.num_elements()):
            let base_val = base_result.load[1](i)
            let lora_val = lora_output.load[1](i) * self.scaling
            result.store[1](i, base_val + lora_val)
        
        return result

# ==============================================
# LoRA Adapter
# ==============================================

struct LoRAAdapter:
    """A complete LoRA adapter with multiple layers."""
    var adapter_id: String
    var adapter_name: String
    var config: LoRAConfig
    var layers: Dict[String, LoRALayer]
    var loaded: Bool
    var memory_bytes: Int
    
    fn __init__(inout self,
                adapter_id: String,
                adapter_name: String,
                config: LoRAConfig):
        self.adapter_id = adapter_id
        self.adapter_name = adapter_name
        self.config = config
        self.layers = Dict[String, LoRALayer]()
        self.loaded = False
        self.memory_bytes = 0
    
    fn add_layer(inout self,
                 module_name: String,
                 in_features: Int,
                 out_features: Int):
        """Add a LoRA layer for a module."""
        let layer = LoRALayer(
            module_name,
            in_features,
            out_features,
            self.config
        )
        self.layers[module_name] = layer
        
        # Track memory
        let a_size = self.config.rank * in_features * 4  # float32
        let b_size = out_features * self.config.rank * 4
        self.memory_bytes += a_size + b_size
    
    fn get_layer(self, module_name: String) -> Optional[LoRALayer]:
        """Get LoRA layer for a module."""
        if module_name in self.layers:
            return self.layers[module_name]
        return None
    
    fn apply(self,
             module_name: String,
             x: Tensor[DType.float32],
             base_result: Tensor[DType.float32]) -> Tensor[DType.float32]:
        """Apply LoRA to a module's output."""
        if not self.loaded:
            return base_result
        
        if module_name in self.layers:
            return self.layers[module_name].forward(x, base_result)
        
        return base_result

# ==============================================
# LoRA Manager
# ==============================================

struct LoRAManager:
    """Manages multiple LoRA adapters."""
    var adapters: Dict[String, LoRAAdapter]
    var active_adapters: List[String]
    var max_adapters: Int
    var total_memory: Int
    var memory_budget: Int
    
    fn __init__(inout self, 
                max_adapters: Int = 16,
                memory_budget_gb: Float32 = 4.0):
        self.adapters = Dict[String, LoRAAdapter]()
        self.active_adapters = List[String]()
        self.max_adapters = max_adapters
        self.total_memory = 0
        self.memory_budget = Int(memory_budget_gb * 1024 * 1024 * 1024)
    
    fn register_adapter(inout self, adapter: LoRAAdapter) -> Bool:
        """Register a new adapter."""
        if len(self.adapters) >= self.max_adapters:
            return False
        
        if self.total_memory + adapter.memory_bytes > self.memory_budget:
            return False
        
        self.adapters[adapter.adapter_id] = adapter
        self.total_memory += adapter.memory_bytes
        return True
    
    fn load_adapter(inout self, adapter_id: String) -> Bool:
        """Load adapter into memory (GPU)."""
        if adapter_id not in self.adapters:
            return False
        
        # Would transfer weights to GPU here
        self.adapters[adapter_id].loaded = True
        
        if adapter_id not in self.active_adapters:
            self.active_adapters.append(adapter_id)
        
        return True
    
    fn unload_adapter(inout self, adapter_id: String) -> Bool:
        """Unload adapter from memory."""
        if adapter_id not in self.adapters:
            return False
        
        self.adapters[adapter_id].loaded = False
        
        # Remove from active list
        for i in range(len(self.active_adapters)):
            if self.active_adapters[i] == adapter_id:
                _ = self.active_adapters.pop(i)
                break
        
        return True
    
    fn get_adapter(self, adapter_id: String) -> Optional[LoRAAdapter]:
        """Get adapter by ID."""
        if adapter_id in self.adapters:
            return self.adapters[adapter_id]
        return None
    
    fn list_adapters(self) -> List[String]:
        """List all registered adapter IDs."""
        var ids = List[String]()
        for id in self.adapters.keys():
            ids.append(id)
        return ids

# ==============================================
# Batched LoRA Inference
# ==============================================

struct BatchedLoRAInference:
    """Efficient batched inference with multiple LoRA adapters."""
    var manager: LoRAManager
    
    fn __init__(inout self, manager: LoRAManager):
        self.manager = manager
    
    fn forward(self,
               module_name: String,
               x: Tensor[DType.float32],
               base_result: Tensor[DType.float32],
               adapter_indices: Tensor[DType.int32]) -> Tensor[DType.float32]:
        """Apply different LoRA adapters to different sequences in batch.
        
        Args:
            module_name: Name of the module
            x: Input [batch, seq, in_features]
            base_result: Base output [batch, seq, out_features]
            adapter_indices: Index of adapter per sequence [batch]
            
        Returns:
            Mixed output with per-sequence LoRA
        """
        let batch_size = x.shape()[0]
        var result = Tensor[DType.float32](base_result.shape())
        
        # Group sequences by adapter
        var adapter_batches = Dict[Int, List[Int]]()
        
        for i in range(batch_size):
            let adapter_idx = Int(adapter_indices.load[1](i))
            if adapter_idx not in adapter_batches:
                adapter_batches[adapter_idx] = List[Int]()
            adapter_batches[adapter_idx].append(i)
        
        # Process each adapter group
        for adapter_idx in adapter_batches.keys():
            let seq_indices = adapter_batches[adapter_idx]
            
            if adapter_idx < 0:
                # No adapter, use base result
                for seq_idx in seq_indices:
                    # Copy base result for this sequence
                    pass
            else:
                # Apply specific adapter
                let adapter_id = self.manager.active_adapters[adapter_idx]
                if adapter_id in self.manager.adapters:
                    let adapter = self.manager.adapters[adapter_id]
                    # Apply adapter to grouped sequences
                    # In practice, would extract and batch these sequences
        
        return result

# ==============================================
# LoRA Merging
# ==============================================

struct LoRAMerger:
    """Utilities for merging LoRA adapters."""
    
    @staticmethod
    fn merge_into_base(base_weight: Tensor[DType.float32],
                       lora_A: Tensor[DType.float32],
                       lora_B: Tensor[DType.float32],
                       scaling: Float32) -> Tensor[DType.float32]:
        """Merge LoRA weights into base weight permanently.
        
        W_merged = W_base + scaling * B @ A
        
        Args:
            base_weight: [out_features, in_features]
            lora_A: [rank, in_features]
            lora_B: [out_features, rank]
            scaling: LoRA scaling factor
            
        Returns:
            Merged weight [out_features, in_features]
        """
        let out_features = base_weight.shape()[0]
        let in_features = base_weight.shape()[1]
        
        # Compute B @ A
        var delta = Tensor[DType.float32](TensorShape(out_features, in_features))
        # matmul(lora_B, lora_A, delta)
        
        # Merge: W + scaling * delta
        var merged = Tensor[DType.float32](base_weight.shape())
        for i in range(merged.num_elements()):
            let base_val = base_weight.load[1](i)
            let delta_val = delta.load[1](i) * scaling
            merged.store[1](i, base_val + delta_val)
        
        return merged
    
    @staticmethod
    fn merge_multiple_adapters(adapters: List[LoRAAdapter],
                               weights: List[Float32]) -> LoRAAdapter:
        """Merge multiple LoRA adapters into one.
        
        For each layer: A_merged = sum(w_i * A_i), B_merged = sum(w_i * B_i)
        
        Args:
            adapters: List of adapters to merge
            weights: Mixing weights (should sum to 1)
            
        Returns:
            Merged adapter
        """
        # Create merged adapter with same config as first
        var merged = LoRAAdapter(
            "merged",
            "merged_adapter",
            adapters[0].config
        )
        
        # Merge each layer
        # For each module in first adapter
        for module_name in adapters[0].layers.keys():
            let first_layer = adapters[0].layers[module_name]
            
            var merged_A = Tensor[DType.float32](first_layer.lora_A.shape())
            var merged_B = Tensor[DType.float32](first_layer.lora_B.shape())
            
            # Weighted sum
            for i in range(len(adapters)):
                let layer = adapters[i].layers[module_name]
                let weight = weights[i]
                
                for j in range(merged_A.num_elements()):
                    let current = merged_A.load[1](j)
                    let addition = layer.lora_A.load[1](j) * weight
                    merged_A.store[1](j, current + addition)
                
                for j in range(merged_B.num_elements()):
                    let current = merged_B.load[1](j)
                    let addition = layer.lora_B.load[1](j) * weight
                    merged_B.store[1](j, current + addition)
            
            merged.add_layer(
                module_name,
                first_layer.in_features,
                first_layer.out_features
            )
            # Would copy merged_A and merged_B to the new layer
        
        return merged

# ==============================================
# LoRA Weight Loader
# ==============================================

struct LoRAWeightLoader:
    """Loads LoRA weights from various formats."""
    
    @staticmethod
    fn from_safetensors(path: String, config: LoRAConfig) -> LoRAAdapter:
        """Load LoRA adapter from safetensors file.
        
        Expected keys:
        - base_model.model.layers.{i}.self_attn.{q,k,v,o}_proj.lora_A.weight
        - base_model.model.layers.{i}.self_attn.{q,k,v,o}_proj.lora_B.weight
        """
        var adapter = LoRAAdapter("loaded", path, config)
        
        # Would parse safetensors file and load weights
        # For each target module found, add layer and load A, B matrices
        
        return adapter
    
    @staticmethod
    fn from_peft(path: String) -> Tuple[LoRAAdapter, LoRAConfig]:
        """Load LoRA from HuggingFace PEFT format.
        
        Expects:
        - adapter_config.json
        - adapter_model.safetensors or .bin
        """
        # Parse adapter_config.json for LoRAConfig
        var config = LoRAConfig()
        
        # Load weights
        var adapter = LoRAAdapter("peft", path, config)
        
        return (adapter, config)

# ==============================================
# QLoRA Support (Quantized LoRA)
# ==============================================

struct QLoRAConfig(LoRAConfig):
    """Configuration for QLoRA (4-bit base + LoRA)."""
    var bits: Int                    # Quantization bits (4)
    var quant_type: String           # "nf4" or "fp4"
    var double_quant: Bool           # Double quantization
    var compute_dtype: String        # Compute dtype for LoRA
    
    fn __init__(inout self,
                rank: Int = 16,
                alpha: Float32 = 32.0,
                bits: Int = 4,
                quant_type: String = "nf4",
                double_quant: Bool = True):
        # Initialize base LoRAConfig
        self.rank = rank
        self.alpha = alpha
        self.dropout = 0.0
        self.fan_in_fan_out = False
        self.bias = "none"
        self.use_rslora = False
        self.use_dora = False
        self.target_modules = List[String]()
        
        # QLoRA specific
        self.bits = bits
        self.quant_type = quant_type
        self.double_quant = double_quant
        self.compute_dtype = "float16"

# ==============================================
# Adapter Request Handler
# ==============================================

struct AdapterRequestHandler:
    """Handles per-request adapter selection."""
    var manager: LoRAManager
    var default_adapter: Optional[String]
    
    fn __init__(inout self, manager: LoRAManager):
        self.manager = manager
        self.default_adapter = None
    
    fn resolve_adapter(self, request_adapter: Optional[String]) -> Optional[String]:
        """Resolve which adapter to use for a request."""
        if request_adapter is not None:
            # Check if requested adapter exists and is loaded
            let adapter_id = request_adapter.value()
            if adapter_id in self.manager.adapters:
                if self.manager.adapters[adapter_id].loaded:
                    return adapter_id
                else:
                    # Auto-load if not loaded
                    _ = self.manager.load_adapter(adapter_id)
                    return adapter_id
        
        return self.default_adapter
    
    fn prepare_batch_adapters(self,
                              requests: List[Optional[String]]) -> Tensor[DType.int32]:
        """Prepare adapter indices for batch inference.
        
        Args:
            requests: Adapter ID per request (None for base model)
            
        Returns:
            Tensor of adapter indices (-1 for base)
        """
        var indices = Tensor[DType.int32](TensorShape(len(requests)))
        
        for i in range(len(requests)):
            let adapter_id = self.resolve_adapter(requests[i])
            
            if adapter_id is None:
                indices.store[1](i, -1)  # No adapter
            else:
                # Find index in active adapters
                let id = adapter_id.value()
                for j in range(len(self.manager.active_adapters)):
                    if self.manager.active_adapters[j] == id:
                        indices.store[1](i, j)
                        break
        
        return indices