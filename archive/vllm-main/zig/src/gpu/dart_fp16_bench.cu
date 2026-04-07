// DART + FP16 HGEMM End-to-End Benchmark
//
// Loads real 7B Q4_0 GGUF, dequants to FP16 on GPU, runs:
//   1. Single-token decode (FP16 HGEMM B=1) — baseline TPS
//   2. Simulated DART with batch-K verify (FP16 HGEMM B=K) — effective TPS
//
// This is the proof-of-concept for achieving 133+ TPS on T4.
//
// Compile: nvcc -O3 -arch=sm_75 -lcublas -o dart_fp16_bench dart_fp16_bench.cu
// Run:     ./dart_fp16_bench /path/to/llama-2-7b-chat.Q4_0.gguf

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda_fp16.h>

#define CHECK_CUDA(call) do { \
    cudaError_t err = (call); \
    if (err != cudaSuccess) { \
        printf("CUDA error at %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(1); \
    } \
} while(0)

#define CHECK_CUBLAS(call) do { \
    cublasStatus_t st = (call); \
    if (st != CUBLAS_STATUS_SUCCESS) { \
        printf("cuBLAS error at %s:%d: status=%d\n", __FILE__, __LINE__, (int)st); \
        exit(1); \
    } \
} while(0)

// ============================================================================
// GGUF Parser (minimal, for Q4_0 models)
// ============================================================================
struct GGUFHeader {
    uint32_t magic;
    uint32_t version;
    uint64_t n_tensors;
    uint64_t n_kv;
};

struct TensorDesc {
    const char* name;
    int name_len;
    uint32_t n_dims;
    uint64_t dims[4];
    uint32_t type;  // 2 = Q4_0, 0 = F32, 1 = F16
    uint64_t offset;
    const uint8_t* data;
    size_t data_bytes;
};

static uint64_t read_u64(const uint8_t* p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static uint32_t read_u32(const uint8_t* p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static size_t skip_gguf_string(const uint8_t* data, size_t pos) {
    uint64_t len = read_u64(data + pos);
    return pos + 8 + (size_t)len;
}

static size_t skip_gguf_value(const uint8_t* data, size_t pos, uint32_t vtype) {
    switch (vtype) {
        case 0: return pos + 1;   // u8
        case 1: return pos + 1;   // i8
        case 2: return pos + 2;   // u16
        case 3: return pos + 2;   // i16
        case 4: return pos + 4;   // u32
        case 5: return pos + 4;   // i32
        case 6: return pos + 4;   // f32
        case 7: return pos + 1;   // bool
        case 8: return skip_gguf_string(data, pos); // string
        case 9: {  // array
            uint32_t elem_type = read_u32(data + pos);
            uint64_t count = read_u64(data + pos + 4);
            size_t p = pos + 12;
            for (uint64_t i = 0; i < count; i++)
                p = skip_gguf_value(data, p, elem_type);
            return p;
        }
        case 10: return pos + 8;  // u64
        case 11: return pos + 8;  // i64
        case 12: return pos + 8;  // f64
        default:
            printf("Unknown GGUF value type: %u\n", vtype);
            exit(1);
    }
}

static size_t skip_gguf_kv(const uint8_t* data, size_t pos) {
    uint64_t key_len = read_u64(data + pos);
    pos += 8 + (size_t)key_len;
    uint32_t vtype = read_u32(data + pos);
    pos += 4;
    return skip_gguf_value(data, pos, vtype);
}

static int64_t find_gguf_int(const uint8_t* data, size_t start, uint64_t n_kv,
                              const char* target_key) {
    size_t pos = start;
    int target_len = strlen(target_key);
    for (uint64_t i = 0; i < n_kv; i++) {
        uint64_t key_len = read_u64(data + pos);
        const char* key = (const char*)(data + pos + 8);
        pos += 8 + (size_t)key_len;
        uint32_t vtype = read_u32(data + pos);
        pos += 4;
        if ((int)key_len == target_len && memcmp(key, target_key, key_len) == 0) {
            if (vtype == 4) return (int64_t)read_u32(data + pos);
            if (vtype == 5) return (int64_t)(int32_t)read_u32(data + pos);
            if (vtype == 10) return (int64_t)read_u64(data + pos);
            if (vtype == 11) return (int64_t)read_u64(data + pos);
            return -1;
        }
        pos = skip_gguf_value(data, pos, vtype);
    }
    return -1;
}

// ============================================================================
// Q4_0 → FP16 dequant kernel (GPU)
// ============================================================================
__global__ void dequant_q4_to_fp16_kernel(__half* __restrict__ out,
                                           const uint8_t* __restrict__ q4_data,
                                           int M, int K) {
    int n_blocks_per_row = K >> 5;
    int block_idx = blockIdx.x * blockDim.x + threadIdx.x;
    int total_blocks = M * n_blocks_per_row;
    if (block_idx >= total_blocks) return;

    int row = block_idx / n_blocks_per_row;
    int col_block = block_idx % n_blocks_per_row;

    const uint8_t* block_ptr = q4_data + (long long)row * n_blocks_per_row * 18 + col_block * 18;
    __half scale_h = *reinterpret_cast<const __half*>(block_ptr);
    float scale = __half2float(scale_h);

    int out_base = row * K + col_block * 32;

    // Q4_0 block layout: 2 bytes f16 scale + 16 bytes data
    // Data: each byte has 2 nibbles, low nibble first
    // GGUF split-half order: first 16 values from low nibbles, next 16 from high nibbles
    for (int j = 0; j < 16; j++) {
        uint8_t byte = block_ptr[2 + j];
        float lo = ((float)(byte & 0xF) - 8.0f) * scale;
        float hi = ((float)(byte >> 4) - 8.0f) * scale;
        out[out_base + j]      = __float2half(lo);
        out[out_base + j + 16] = __float2half(hi);
    }
}

void dequant_q4_to_fp16(__half* d_out, const uint8_t* d_q4, int M, int K) {
    int n_blocks = M * (K / 32);
    int threads = 256;
    int grids = (n_blocks + threads - 1) / threads;
    dequant_q4_to_fp16_kernel<<<grids, threads>>>(d_out, d_q4, M, K);
}

// ============================================================================
// Model structure
// ============================================================================
struct ModelConfig {
    int dim;
    int n_layers;
    int n_heads;
    int n_kv_heads;
    int ff_dim;
    int vocab_size;
    int head_dim;
};

struct FP16Layer {
    __half *wq, *wk, *wv, *wo;
    __half *w_gate, *w_up, *w_down;
    // RMS norm weights (keep as FP32 for accuracy)
    float *rms_attn, *rms_ffn;
};

struct FP16Model {
    ModelConfig cfg;
    FP16Layer* layers;
    __half* token_embd;   // [vocab × dim] FP16
    float* rms_final;     // [dim] FP32
    __half* lm_head;      // [vocab × dim] FP16 (may be tied to token_embd)
    size_t total_vram;
};

// ============================================================================
// Batch forward pass (GEMM only, no attention for now)
// ============================================================================
float bench_batch_forward(cublasHandle_t handle, FP16Model& model, int B, int n_iters) {
    int dim = model.cfg.dim;
    int ff = model.cfg.ff_dim;
    int nl = model.cfg.n_layers;

    // Allocate activations
    __half *d_hidden, *d_q, *d_k, *d_v, *d_attn_out;
    __half *d_gate, *d_up, *d_ffn_out;
    CHECK_CUDA(cudaMalloc(&d_hidden, (size_t)B * dim * 2));
    CHECK_CUDA(cudaMalloc(&d_q, (size_t)B * dim * 2));
    CHECK_CUDA(cudaMalloc(&d_k, (size_t)B * dim * 2));
    CHECK_CUDA(cudaMalloc(&d_v, (size_t)B * dim * 2));
    CHECK_CUDA(cudaMalloc(&d_attn_out, (size_t)B * dim * 2));
    CHECK_CUDA(cudaMalloc(&d_gate, (size_t)B * ff * 2));
    CHECK_CUDA(cudaMalloc(&d_up, (size_t)B * ff * 2));
    CHECK_CUDA(cudaMalloc(&d_ffn_out, (size_t)B * dim * 2));

    __half alpha = __float2half(1.0f);
    __half beta = __float2half(0.0f);

    // Warmup
    for (int w = 0; w < 2; w++) {
        for (int l = 0; l < nl; l++) {
            FP16Layer& lw = model.layers[l];
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wq, dim, d_hidden, dim, &beta, d_q, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wk, dim, d_hidden, dim, &beta, d_k, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wv, dim, d_hidden, dim, &beta, d_v, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wo, dim, d_q, dim, &beta, d_attn_out, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, ff, B, dim, &alpha,
                         lw.w_gate, ff, d_hidden, dim, &beta, d_gate, ff);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, ff, B, dim, &alpha,
                         lw.w_up, ff, d_hidden, dim, &beta, d_up, ff);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, ff, &alpha,
                         lw.w_down, dim, d_gate, ff, &beta, d_ffn_out, dim);
        }
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // Benchmark
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        for (int l = 0; l < nl; l++) {
            FP16Layer& lw = model.layers[l];
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wq, dim, d_hidden, dim, &beta, d_q, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wk, dim, d_hidden, dim, &beta, d_k, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wv, dim, d_hidden, dim, &beta, d_v, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, dim, &alpha,
                         lw.wo, dim, d_q, dim, &beta, d_attn_out, dim);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, ff, B, dim, &alpha,
                         lw.w_gate, ff, d_hidden, dim, &beta, d_gate, ff);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, ff, B, dim, &alpha,
                         lw.w_up, ff, d_hidden, dim, &beta, d_up, ff);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, dim, B, ff, &alpha,
                         lw.w_down, dim, d_gate, ff, &beta, d_ffn_out, dim);
        }
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms;
    cudaEventElapsedTime(&ms, start, stop);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(d_hidden); cudaFree(d_q); cudaFree(d_k); cudaFree(d_v);
    cudaFree(d_attn_out); cudaFree(d_gate); cudaFree(d_up); cudaFree(d_ffn_out);

    return ms / n_iters;
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv) {
    if (argc < 2) {
        printf("Usage: %s <model.gguf>\n", argv[0]);
        return 1;
    }

    // Memory-map GGUF file
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st;
    fstat(fd, &st);
    size_t file_size = st.st_size;
    const uint8_t* data = (const uint8_t*)mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (data == MAP_FAILED) { perror("mmap"); return 1; }

    printf("GGUF file: %s (%.1f GB)\n", argv[1], file_size / 1e9);

    // Parse header
    GGUFHeader hdr;
    memcpy(&hdr, data, sizeof(hdr));
    if (hdr.magic != 0x46554747) { printf("Bad magic\n"); return 1; }
    printf("GGUF v%u: %lu tensors, %lu KV pairs\n", hdr.version, hdr.n_tensors, hdr.n_kv);

    // Parse model config from KV metadata
    size_t kv_start = sizeof(GGUFHeader);
    ModelConfig cfg;
    cfg.dim = (int)find_gguf_int(data, kv_start, hdr.n_kv, "llama.embedding_length");
    cfg.n_layers = (int)find_gguf_int(data, kv_start, hdr.n_kv, "llama.block_count");
    cfg.n_heads = (int)find_gguf_int(data, kv_start, hdr.n_kv, "llama.attention.head_count");
    cfg.n_kv_heads = (int)find_gguf_int(data, kv_start, hdr.n_kv, "llama.attention.head_count_kv");
    cfg.ff_dim = (int)find_gguf_int(data, kv_start, hdr.n_kv, "llama.feed_forward_length");
    cfg.head_dim = cfg.dim / cfg.n_heads;

    printf("Model: dim=%d layers=%d heads=%d kv_heads=%d ff=%d\n",
           cfg.dim, cfg.n_layers, cfg.n_heads, cfg.n_kv_heads, cfg.ff_dim);

    // Skip KV pairs to reach tensor descriptors
    size_t pos = kv_start;
    for (uint64_t i = 0; i < hdr.n_kv; i++) pos = skip_gguf_kv(data, pos);

    // Parse tensor descriptors
    TensorDesc* tensors = new TensorDesc[hdr.n_tensors];
    size_t tensor_desc_start = pos;
    for (uint64_t i = 0; i < hdr.n_tensors; i++) {
        TensorDesc& t = tensors[i];
        t.name_len = (int)read_u64(data + pos);
        t.name = (const char*)(data + pos + 8);
        pos += 8 + t.name_len;
        t.n_dims = read_u32(data + pos); pos += 4;
        for (uint32_t d = 0; d < t.n_dims; d++) {
            t.dims[d] = read_u64(data + pos); pos += 8;
        }
        for (uint32_t d = t.n_dims; d < 4; d++) t.dims[d] = 1;
        t.type = read_u32(data + pos); pos += 4;
        t.offset = read_u64(data + pos); pos += 8;
    }

    // Compute data start (aligned to 32 bytes)
    size_t data_start = (pos + 31) & ~31ULL;
    for (uint64_t i = 0; i < hdr.n_tensors; i++) {
        TensorDesc& t = tensors[i];
        t.data = data + data_start + t.offset;
        // Compute data size
        uint64_t n_elem = t.dims[0] * t.dims[1];
        if (t.type == 2) { // Q4_0
            t.data_bytes = (n_elem / 32) * 18;
        } else if (t.type == 0) { // F32
            t.data_bytes = n_elem * 4;
        } else if (t.type == 1) { // F16
            t.data_bytes = n_elem * 2;
        }
    }

    // Find vocab size from token_embd tensor
    cfg.vocab_size = 0;
    for (uint64_t i = 0; i < hdr.n_tensors; i++) {
        if (strncmp(tensors[i].name, "token_embd.weight", tensors[i].name_len) == 0) {
            cfg.vocab_size = (int)tensors[i].dims[1];
            break;
        }
    }
    printf("Vocab: %d\n", cfg.vocab_size);

    // GPU setup
    size_t free_mem, total_mem;
    CHECK_CUDA(cudaMemGetInfo(&free_mem, &total_mem));
    printf("\nGPU VRAM: %.1f GB free / %.1f GB total\n", free_mem / 1e9, total_mem / 1e9);

    // Allocate FP16 model on GPU
    FP16Model model;
    model.cfg = cfg;
    model.layers = new FP16Layer[cfg.n_layers];
    model.total_vram = 0;

    printf("Loading and dequanting Q4_0 → FP16...\n");

    // Helper: find tensor by name, upload Q4_0 to GPU, dequant to FP16
    auto load_weight = [&](const char* name, int M, int K) -> __half* {
        // Find tensor
        TensorDesc* found = nullptr;
        for (uint64_t i = 0; i < hdr.n_tensors; i++) {
            if (strncmp(tensors[i].name, name, tensors[i].name_len) == 0 &&
                (int)strlen(name) == tensors[i].name_len) {
                found = &tensors[i];
                break;
            }
        }
        if (!found) {
            printf("  Tensor not found: %s\n", name);
            return nullptr;
        }

        // Upload Q4_0 data to GPU
        uint8_t* d_q4;
        CHECK_CUDA(cudaMalloc(&d_q4, found->data_bytes));
        CHECK_CUDA(cudaMemcpy(d_q4, found->data, found->data_bytes, cudaMemcpyHostToDevice));

        // Allocate FP16 output
        size_t fp16_bytes = (size_t)M * K * 2;
        __half* d_fp16;
        CHECK_CUDA(cudaMalloc(&d_fp16, fp16_bytes));
        model.total_vram += fp16_bytes;

        // Dequant
        dequant_q4_to_fp16(d_fp16, d_q4, M, K);
        CHECK_CUDA(cudaDeviceSynchronize());

        // Free Q4_0 staging
        CHECK_CUDA(cudaFree(d_q4));

        return d_fp16;
    };

    // Load all layers
    for (int l = 0; l < cfg.n_layers; l++) {
        char name[128];
        int dim = cfg.dim;
        int kv_dim = cfg.n_kv_heads * cfg.head_dim;
        int ff = cfg.ff_dim;

        snprintf(name, sizeof(name), "blk.%d.attn_q.weight", l);
        model.layers[l].wq = load_weight(name, dim, dim);

        snprintf(name, sizeof(name), "blk.%d.attn_k.weight", l);
        model.layers[l].wk = load_weight(name, kv_dim, dim);

        snprintf(name, sizeof(name), "blk.%d.attn_v.weight", l);
        model.layers[l].wv = load_weight(name, kv_dim, dim);

        snprintf(name, sizeof(name), "blk.%d.attn_output.weight", l);
        model.layers[l].wo = load_weight(name, dim, dim);

        snprintf(name, sizeof(name), "blk.%d.ffn_gate.weight", l);
        model.layers[l].w_gate = load_weight(name, ff, dim);

        snprintf(name, sizeof(name), "blk.%d.ffn_up.weight", l);
        model.layers[l].w_up = load_weight(name, ff, dim);

        snprintf(name, sizeof(name), "blk.%d.ffn_down.weight", l);
        model.layers[l].w_down = load_weight(name, dim, ff);

        if (l == 0 || l == cfg.n_layers - 1)
            printf("  Layer %d loaded (%.0f MB cumulative)\n", l, model.total_vram / 1e6);
    }

    printf("Total FP16 weight VRAM: %.1f GB\n", model.total_vram / 1e9);
    CHECK_CUDA(cudaMemGetInfo(&free_mem, &total_mem));
    printf("VRAM remaining: %.1f GB free\n", free_mem / 1e9);

    // cuBLAS setup
    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));
    CHECK_CUBLAS(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

    printf("\n========== Batch Forward Pass Benchmark ==========\n");
    printf("(GEMM only — no attention, RMSNorm, RoPE, SwiGLU)\n\n");

    for (int B : {1, 2, 4, 8, 16}) {
        int iters = (B <= 4) ? 20 : 10;
        float ms_gemm = bench_batch_forward(handle, model, B, iters);

        // Estimate real overhead: ~2.5ms base + ~0.5ms per extra token
        float overhead = 2.5f + 0.5f * (B - 1);
        float total_ms = ms_gemm + overhead;

        printf("B=%2d: GEMM=%.1f ms  overhead≈%.1f ms  total≈%.1f ms\n",
               B, ms_gemm, overhead, total_ms);

        if (B > 1) {
            for (float alpha : {0.5f, 0.7f, 0.85f, 0.9f, 0.95f}) {
                int K = B;
                float accepted = alpha * K + 1;
                float dart_tps = accepted / total_ms * 1000.0f;
                const char* marker = (dart_tps >= 133) ? " ✓ TARGET" : "";
                printf("  DART K=%d α=%.2f: %.1f tokens → %6.0f effective TPS%s\n",
                       K, alpha, accepted, dart_tps, marker);
            }
        }
        printf("\n");
    }

    // Cleanup
    cublasDestroy(handle);
    for (int l = 0; l < cfg.n_layers; l++) {
        cudaFree(model.layers[l].wq);
        cudaFree(model.layers[l].wk);
        cudaFree(model.layers[l].wv);
        cudaFree(model.layers[l].wo);
        cudaFree(model.layers[l].w_gate);
        cudaFree(model.layers[l].w_up);
        cudaFree(model.layers[l].w_down);
    }
    delete[] model.layers;
    delete[] tensors;
    munmap((void*)data, file_size);
    close(fd);

    return 0;
}
