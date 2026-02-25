"""
Tensor Parallel Communication Primitives

Implementation of tensor parallelism communication operations for
distributed LLM inference across multiple GPUs.

Supports:
- All-reduce (sum, mean)
- All-gather
- Reduce-scatter
- Broadcast
"""

from tensor import Tensor, TensorShape
from algorithm import vectorize, parallelize
from memory import memcpy


# ==============================================
# Process Group
# ==============================================

struct ProcessGroup:
    """
    Represents a group of processes for collective communication.
    """
    
    var rank: Int
    var world_size: Int
    var local_rank: Int
    var local_world_size: Int
    var device_id: Int
    
    fn __init__(
        inout self,
        rank: Int = 0,
        world_size: Int = 1,
        local_rank: Int = 0,
        local_world_size: Int = 1,
    ):
        self.rank = rank
        self.world_size = world_size
        self.local_rank = local_rank
        self.local_world_size = local_world_size
        self.device_id = local_rank
    
    fn is_first(self) -> Bool:
        """Check if this is the first process."""
        return self.rank == 0
    
    fn is_last(self) -> Bool:
        """Check if this is the last process."""
        return self.rank == self.world_size - 1
    
    fn is_single(self) -> Bool:
        """Check if running single-process."""
        return self.world_size == 1


# ==============================================
# Tensor Parallel Group
# ==============================================

struct TensorParallelGroup:
    """
    Group for tensor parallelism within a node.
    
    Manages communication between GPUs for tensor-parallel operations.
    """
    
    var tp_rank: Int
    var tp_size: Int
    var pp_rank: Int  # Pipeline parallel rank
    var pp_size: Int  # Pipeline parallel size
    
    fn __init__(
        inout self,
        tp_rank: Int = 0,
        tp_size: Int = 1,
        pp_rank: Int = 0,
        pp_size: Int = 1,
    ):
        self.tp_rank = tp_rank
        self.tp_size = tp_size
        self.pp_rank = pp_rank
        self.pp_size = pp_size
    
    fn needs_reduce(self) -> Bool:
        """Check if all-reduce is needed."""
        return self.tp_size > 1
    
    fn shard_size(self, total_size: Int, dim: Int) -> Int:
        """Calculate size after sharding on given dimension."""
        return total_size // self.tp_size
    
    fn shard_offset(self, total_size: Int) -> Int:
        """Calculate offset for this rank's shard."""
        return self.tp_rank * (total_size // self.tp_size)


# ==============================================
# Communication Operations
# ==============================================

fn all_reduce_sum[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
) -> Tensor[dtype]:
    """
    All-reduce with sum across tensor parallel group.
    
    Each process contributes its local tensor, and all processes
    receive the sum of all tensors.
    
    For row-parallel layers: reduces output across GPUs.
    """
    if not group.needs_reduce():
        return tensor
    
    # In actual implementation, this would use NCCL or similar
    # Here we simulate the operation
    var result = Tensor[dtype](tensor.shape())
    
    # Copy input (in real impl, this is where NCCL all-reduce happens)
    memcpy(result.data(), tensor.data(), tensor.num_elements() * sizeof[dtype]())
    
    # Placeholder: In production, call ncclAllReduce
    # ncclAllReduce(tensor.data(), result.data(), tensor.num_elements(),
    #               ncclFloat16, ncclSum, group.comm, stream)
    
    return result


fn all_reduce_mean[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
) -> Tensor[dtype]:
    """
    All-reduce with mean across tensor parallel group.
    """
    if not group.needs_reduce():
        return tensor
    
    var result = all_reduce_sum(tensor, group)
    
    # Divide by world size
    let scale = 1.0 / Float32(group.tp_size)
    
    for i in range(result.num_elements()):
        result.store(i, result[i] * scale)
    
    return result


fn all_gather[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
    gather_dim: Int = 0,
) -> Tensor[dtype]:
    """
    All-gather across tensor parallel group.
    
    Each process contributes its local tensor, and all processes
    receive the concatenation of all tensors along gather_dim.
    
    Used to reconstruct full tensors from sharded tensors.
    """
    if not group.needs_reduce():
        return tensor
    
    # Calculate output shape
    var output_shape = List[Int]()
    for i in range(tensor.rank()):
        if i == gather_dim:
            output_shape.append(tensor.shape()[i] * group.tp_size)
        else:
            output_shape.append(tensor.shape()[i])
    
    var result = Tensor[dtype](TensorShape(output_shape))
    
    # Calculate stride for gathering
    let gather_size = tensor.shape()[gather_dim]
    let offset = group.tp_rank * gather_size
    
    # Copy local data to correct position (in real impl, use ncclAllGather)
    # This is a placeholder showing the data layout
    let elements_per_slice = tensor.num_elements() // gather_size
    
    for i in range(gather_size):
        for j in range(elements_per_slice):
            let src_idx = i * elements_per_slice + j
            let dst_idx = (offset + i) * elements_per_slice + j
            result.store(dst_idx, tensor[src_idx])
    
    return result


fn reduce_scatter[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
    scatter_dim: Int = 0,
) -> Tensor[dtype]:
    """
    Reduce-scatter across tensor parallel group.
    
    First reduces (sums) all tensors, then scatters the result
    so each process gets a portion along scatter_dim.
    
    Inverse of all-gather.
    """
    if not group.needs_reduce():
        return tensor
    
    # Calculate output shape (scattered size)
    var output_shape = List[Int]()
    for i in range(tensor.rank()):
        if i == scatter_dim:
            output_shape.append(tensor.shape()[i] // group.tp_size)
        else:
            output_shape.append(tensor.shape()[i])
    
    var result = Tensor[dtype](TensorShape(output_shape))
    
    # Calculate offset for this rank's portion
    let scatter_size = tensor.shape()[scatter_dim] // group.tp_size
    let offset = group.tp_rank * scatter_size
    
    # In real impl: ncclReduceScatter
    let elements_per_slice = tensor.num_elements() // tensor.shape()[scatter_dim]
    
    for i in range(scatter_size):
        for j in range(elements_per_slice):
            let src_idx = (offset + i) * elements_per_slice + j
            let dst_idx = i * elements_per_slice + j
            result.store(dst_idx, tensor[src_idx])
    
    return result


fn broadcast[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
    src_rank: Int = 0,
) -> Tensor[dtype]:
    """
    Broadcast tensor from src_rank to all processes.
    """
    if not group.needs_reduce():
        return tensor
    
    var result = Tensor[dtype](tensor.shape())
    
    # In real impl: ncclBroadcast
    if group.tp_rank == src_rank:
        memcpy(result.data(), tensor.data(), tensor.num_elements() * sizeof[dtype]())
    
    # Receive broadcast data on other ranks
    # ncclBroadcast(result.data(), result.data(), num_elements, dtype, src_rank, comm, stream)
    
    return result


# ==============================================
# Tensor Sharding Utilities
# ==============================================

fn shard_tensor[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
    shard_dim: Int = 0,
) -> Tensor[dtype]:
    """
    Shard a tensor across the tensor parallel group.
    
    Args:
        tensor: Input tensor to shard
        group: Tensor parallel group
        shard_dim: Dimension to shard along
    
    Returns:
        This rank's portion of the tensor
    """
    if not group.needs_reduce():
        return tensor
    
    let full_size = tensor.shape()[shard_dim]
    let shard_size = full_size // group.tp_size
    let offset = group.tp_rank * shard_size
    
    # Calculate output shape
    var output_shape = List[Int]()
    for i in range(tensor.rank()):
        if i == shard_dim:
            output_shape.append(shard_size)
        else:
            output_shape.append(tensor.shape()[i])
    
    var result = Tensor[dtype](TensorShape(output_shape))
    
    # Copy shard
    # This is dimension-aware slicing
    _copy_shard(tensor, result, shard_dim, offset, shard_size)
    
    return result


fn _copy_shard[
    dtype: DType
](
    src: Tensor[dtype],
    dst: Tensor[dtype],
    shard_dim: Int,
    offset: Int,
    shard_size: Int,
):
    """Copy a shard from source to destination tensor."""
    # Simplified implementation for 2D tensors
    if shard_dim == 0:
        # Shard along rows
        for i in range(shard_size):
            for j in range(src.shape()[1]):
                dst.store(i, j, src[offset + i, j])
    else:
        # Shard along columns
        for i in range(src.shape()[0]):
            for j in range(shard_size):
                dst.store(i, j, src[i, offset + j])


fn unshard_tensor[
    dtype: DType
](
    tensor: Tensor[dtype],
    group: TensorParallelGroup,
    shard_dim: Int = 0,
) -> Tensor[dtype]:
    """
    Reconstruct full tensor from shards using all-gather.
    """
    return all_gather(tensor, group, shard_dim)


# ==============================================
# Column/Row Parallel Operations
# ==============================================

fn column_parallel_linear[
    dtype: DType
](
    input: Tensor[dtype],
    weight: Tensor[dtype],  # Already sharded [hidden, local_output]
    bias: Tensor[dtype],    # Already sharded [local_output]
    group: TensorParallelGroup,
) -> Tensor[dtype]:
    """
    Column-parallel linear: output dimension is sharded.
    
    Each GPU computes a portion of the output features.
    No communication needed (each GPU has independent outputs).
    """
    # Standard linear: input @ weight.T + bias
    var output = input @ weight.transpose(-2, -1)
    
    if bias.num_elements() > 0:
        output = output + bias
    
    # No all-reduce needed for column parallel
    return output


fn row_parallel_linear[
    dtype: DType
](
    input: Tensor[dtype],  # Already sharded along input dim
    weight: Tensor[dtype], # Already sharded [local_input, output]
    bias: Tensor[dtype],   # Full bias (not sharded)
    group: TensorParallelGroup,
) -> Tensor[dtype]:
    """
    Row-parallel linear: input dimension is sharded.
    
    Each GPU computes partial output, then all-reduce to sum.
    """
    # Local computation
    var local_output = input @ weight.transpose(-2, -1)
    
    # All-reduce to sum partial outputs
    var output = all_reduce_sum(local_output, group)
    
    # Add bias (only on one rank to avoid counting multiple times)
    if bias.num_elements() > 0 and group.tp_rank == 0:
        output = output + bias
    
    return output


# ==============================================
# Parallel Attention Operations
# ==============================================

fn parallel_attention_forward[
    dtype: DType
](
    q: Tensor[dtype],  # [batch, seq, local_heads, head_dim]
    k: Tensor[dtype],  # [batch, seq, local_kv_heads, head_dim]
    v: Tensor[dtype],  # [batch, seq, local_kv_heads, head_dim]
    group: TensorParallelGroup,
) -> Tensor[dtype]:
    """
    Compute attention with tensor-parallel heads.
    
    Each GPU handles a subset of attention heads independently.
    No communication needed during attention computation.
    """
    let batch_size = q.shape()[0]
    let seq_len = q.shape()[1]
    let local_heads = q.shape()[2]
    let head_dim = q.shape()[3]
    
    # Standard scaled dot-product attention
    let scale = 1.0 / sqrt(Float32(head_dim))
    
    let scores = q @ k.transpose(-2, -1) * scale
    let attn_weights = softmax(scores, axis=-1)
    let output = attn_weights @ v
    
    # Output is [batch, seq, local_heads, head_dim]
    # Will be projected and reduced by row-parallel output proj
    return output


# ==============================================
# Synchronization Primitives
# ==============================================

fn barrier(group: TensorParallelGroup):
    """
    Synchronization barrier for all processes in group.
    """
    if not group.needs_reduce():
        return
    
    # In real impl: cudaStreamSynchronize + NCCL barrier
    # ncclGroupStart()
    # ncclGroupEnd()
    pass


fn sync_stream(group: TensorParallelGroup):
    """
    Synchronize CUDA stream.
    """
    # In real impl: cudaStreamSynchronize(stream)
    pass