// diag_llama_dump.c — Layer-0 numerical diagnostic using llama.cpp
//
// Loads a Qwen3.5 GGUF, evaluates a single token with a graph eval callback
// that dumps intermediate tensor values at layer 0 for comparison with our
// Zig CUDA forward pass [DIAG] output.
//
// The cb() hooks in llama.cpp's qwen35.cpp assign names like:
//   "attn_norm-0", "linear_attn_qkv_mixed-0", "conv_output_silu-0",
//   "q_conv-0", "k_conv-0", "v_conv-0", "beta-0", "alpha-0",
//   "attn_output-0", "final_output-0", "linear_attn_out-0"
//
// Build:
//   gcc -O2 -o diag_llama_dump diag_llama_dump.c \
//     -I/root/llama.cpp/include -I/root/llama.cpp/ggml/include \
//     -L/root/llama.cpp/build_cuda/bin \
//     -lllama -lggml -lggml-base -lggml-cuda -lggml-cpu \
//     -lstdc++ -lm -lpthread -lcuda -lcudart
//
// Run:
//   LD_LIBRARY_PATH=/root/llama.cpp/build_cuda/bin \
//   ./diag_llama_dump /root/models/qwen35/Qwen3.5-0.8B-Q4_0.gguf
//
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "llama.h"
#include "ggml.h"
#include "ggml-backend.h"

// Tensor names at layer 0 that we want to dump (matching qwen35.cpp cb() names)
static const char *target_names[] = {
    "attn_norm",
    "linear_attn_qkv_mixed",
    "z",
    "conv_output_raw",
    "conv_output_silu",
    "q_conv",
    "k_conv",
    "v_conv",
    "q_conv_predelta",
    "k_conv_predelta",
    "v_conv_predelta",
    "beta",
    "alpha",
    "a_softplus",
    "gate",
    "attn_output",
    "final_output",
    "linear_attn_out",
    "attn_residual",
    "ffn_out",
    "post_ffn",
    NULL
};

static void dump_first_n(const char *label, const float *data, int n) {
    printf("[LLAMA_DIAG] %s:", label);
    int count = (n > 16) ? 16 : n;
    for (int i = 0; i < count; i++) {
        printf(" %.6f", data[i]);
    }
    printf("\n");
}

// eval callback: called for each tensor in the graph before/after compute
static bool eval_cb(struct ggml_tensor *t, bool ask, void *user_data) {
    (void)user_data;

    if (ask) {
        // Return true for tensors we want to inspect (layer 0 only)
        if (!t->name) return false;
        const char *name = t->name;
        for (int i = 0; target_names[i]; i++) {
            size_t len = strlen(target_names[i]);
            // Match "name-0" (layer 0)
            if (strncmp(name, target_names[i], len) == 0 &&
                name[len] == '-' && name[len+1] == '0' && name[len+2] == '\0') {
                return true;
            }
            // Also match names without layer suffix (e.g. "result_norm")
            if (strcmp(name, target_names[i]) == 0) return true;
        }
        // Also capture these global tensors
        if (strcmp(name, "model.input_embed") == 0) return true;
        if (strcmp(name, "result_norm") == 0) return true;
        if (strcmp(name, "result_output") == 0) return true;
        return false;
    }

    // Tensor is computed — dump its values
    if (!t->name) return true;

    int n_elem = 1;
    for (int i = 0; i < GGML_MAX_DIMS; i++) {
        if (t->ne[i] > 0) n_elem *= t->ne[i];
    }

    // Read back data — use ggml_backend_tensor_get for GPU tensors
    int count = (n_elem > 16) ? 16 : n_elem;
    float buf[16] = {0};

    // ggml_backend_tensor_get copies from any backend (GPU/CPU) to host
    size_t bytes = count * sizeof(float);
    if (t->type == GGML_TYPE_F32) {
        ggml_backend_tensor_get(t, buf, 0, bytes);
    } else {
        // For quantized tensors, read raw and note the type
        float tmp[16] = {0};
        size_t raw_bytes = count * ggml_type_size(t->type) / ggml_blck_size(t->type);
        if (raw_bytes > sizeof(tmp)) raw_bytes = sizeof(tmp);
        ggml_backend_tensor_get(t, tmp, 0, raw_bytes);
        // Just show the raw float interpretation — enough for comparison
        memcpy(buf, tmp, raw_bytes < sizeof(buf) ? raw_bytes : sizeof(buf));
    }

    char label[256];
    snprintf(label, sizeof(label), "%s [%lldx%lldx%lldx%lld %s]",
        t->name, (long long)t->ne[0], (long long)t->ne[1],
        (long long)t->ne[2], (long long)t->ne[3],
        ggml_type_name(t->type));
    dump_first_n(label, buf, count);

    return true;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <model.gguf> [token_id]\n", argv[0]);
        return 1;
    }
    const char *model_path = argv[1];
    int32_t test_token = (argc > 2) ? atoi(argv[2]) : 9707;

    llama_backend_init();

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 999;
    struct llama_model *model = llama_model_load_from_file(model_path, mparams);
    if (!model) { fprintf(stderr, "Failed to load model\n"); return 1; }

    int n_vocab = llama_vocab_n_tokens(llama_model_get_vocab(model));
    printf("[LLAMA_DIAG] model: %s\n", model_path);
    printf("[LLAMA_DIAG] vocab: %d\n", n_vocab);

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx    = 512;
    cparams.n_batch  = 1;
    cparams.no_perf  = false;
    cparams.cb_eval       = eval_cb;
    cparams.cb_eval_user_data = NULL;

    struct llama_context *ctx = llama_init_from_model(model, cparams);
    if (!ctx) { fprintf(stderr, "Failed to create context\n"); return 1; }

    printf("[LLAMA_DIAG] token_id: %d\n", test_token);
    printf("[LLAMA_DIAG] --- Evaluating single token ---\n");

    struct llama_batch batch = llama_batch_get_one(&test_token, 1);
    int rc = llama_decode(ctx, batch);
    if (rc != 0) { fprintf(stderr, "llama_decode failed: %d\n", rc); return 1; }

    const float *logits = llama_get_logits(ctx);
    if (logits) {
        dump_first_n("logits", logits, 16);
        int argmax = 0;
        float maxval = logits[0];
        for (int i = 1; i < n_vocab; i++) {
            if (logits[i] > maxval) { maxval = logits[i]; argmax = i; }
        }
        printf("[LLAMA_DIAG] argmax: %d (%.4f)\n", argmax, maxval);
    }

    printf("[LLAMA_DIAG] --- Done ---\n");
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}

