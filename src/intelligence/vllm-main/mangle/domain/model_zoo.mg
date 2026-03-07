% Model Zoo — HuggingFace model catalog as Mangle facts
% Auto-loaded by MangleQueryEngine from mangle/domain/
% hf_model(repo_id, family, param_billions, default_quant, gguf_filename, description)

% Family metadata: model_family_meta(family, context_length)
model_family_meta("llama", 131072).
model_family_meta("mistral", 32768).
model_family_meta("phi", 131072).
model_family_meta("qwen", 131072).
model_family_meta("qwen35", 32768).   % Qwen3.5 family — 32K native, extend via YaRN
model_family_meta("gemma", 8192).
model_family_meta("deepseek", 163840).
model_family_meta("yi", 200000).
model_family_meta("chatglm", 131072).
model_family_meta("internlm", 204800).
model_family_meta("command_r", 131072).
model_family_meta("starcoder", 16384).
model_family_meta("falcon", 32768).
model_family_meta("dbrx", 32768).
model_family_meta("baichuan", 4096).
model_family_meta("jamba", 262144).
model_family_meta("olmo", 4096).
model_family_meta("nemotron", 131072).
model_family_meta("granite", 131072).
model_family_meta("solar", 32768).
model_family_meta("minicpm", 131072).
model_family_meta("rwkv", 32768).
model_family_meta("mpt", 65536).
model_family_meta("arctic", 4096).

% HuggingFace search: hf_search(family, query, filter)
hf_search("llama", "llama gguf instruct", "gguf").
hf_search("mistral", "mistral gguf instruct", "gguf").
hf_search("phi", "phi microsoft gguf", "gguf").
hf_search("qwen", "qwen gguf instruct", "gguf").
hf_search("gemma", "gemma google gguf", "gguf").
hf_search("deepseek", "deepseek gguf", "gguf").
hf_search("yi", "yi 01-ai gguf", "gguf").
hf_search("chatglm", "chatglm thudm gguf", "gguf").
hf_search("internlm", "internlm gguf", "gguf").
hf_search("command_r", "command-r cohere gguf", "gguf").
hf_search("starcoder", "starcoder bigcode gguf", "gguf").
hf_search("falcon", "falcon tiiuae gguf", "gguf").
hf_search("dbrx", "dbrx databricks gguf", "gguf").
hf_search("baichuan", "baichuan gguf", "gguf").
hf_search("jamba", "jamba ai21 gguf", "gguf").
hf_search("olmo", "olmo allenai gguf", "gguf").
hf_search("nemotron", "nemotron nvidia gguf", "gguf").
hf_search("granite", "granite ibm gguf", "gguf").
hf_search("solar", "solar upstage gguf", "gguf").
hf_search("minicpm", "minicpm openbmb gguf", "gguf").
hf_search("rwkv", "rwkv gguf", "gguf").
hf_search("mpt", "mpt mosaicml gguf", "gguf").
hf_search("arctic", "arctic snowflake gguf", "gguf").

hf_search("qwen35", "qwen3.5 gguf instruct", "gguf").

% === Model Catalog ===
hf_model("meta-llama/Llama-3.1-8B-Instruct-GGUF", "llama", 8.0, "q4_k_m", "Llama-3.1-8B-Instruct-Q4_K_M.gguf", "Meta Llama 3.1 8B Instruct").
hf_model("meta-llama/Llama-3.3-70B-Instruct-GGUF", "llama", 70.0, "q4_k_m", "Llama-3.3-70B-Instruct-Q4_K_M.gguf", "Meta Llama 3.3 70B").
hf_model("meta-llama/Llama-3.2-3B-Instruct-GGUF", "llama", 3.0, "q4_k_m", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", "Meta Llama 3.2 3B").
hf_model("meta-llama/Llama-3.2-1B-Instruct-GGUF", "llama", 1.0, "q8_0", "Llama-3.2-1B-Instruct-Q8_0.gguf", "Meta Llama 3.2 1B").
hf_model("meta-llama/Llama-3.1-70B-Instruct-GGUF", "llama", 70.0, "q4_k_m", "Llama-3.1-70B-Instruct-Q4_K_M.gguf", "Meta Llama 3.1 70B").
hf_model("meta-llama/Llama-3.1-405B-Instruct-FP8-GGUF", "llama", 405.0, "q4_0", "Llama-3.1-405B-Instruct-Q4_0.gguf", "Meta Llama 3.1 405B").
hf_model("meta-llama/Llama-2-7b-chat-hf-GGUF", "llama", 7.0, "q4_k_m", "llama-2-7b-chat-Q4_K_M.gguf", "Meta Llama 2 7B Chat").
hf_model("meta-llama/Llama-2-13b-chat-hf-GGUF", "llama", 13.0, "q4_k_m", "llama-2-13b-chat-Q4_K_M.gguf", "Meta Llama 2 13B Chat").
hf_model("meta-llama/Llama-2-70b-chat-hf-GGUF", "llama", 70.0, "q4_k_m", "llama-2-70b-chat-Q4_K_M.gguf", "Meta Llama 2 70B Chat").
hf_model("meta-llama/CodeLlama-7b-Instruct-hf-GGUF", "llama", 7.0, "q4_k_m", "codellama-7b-instruct-Q4_K_M.gguf", "CodeLlama 7B").
hf_model("meta-llama/CodeLlama-34b-Instruct-hf-GGUF", "llama", 34.0, "q4_k_m", "codellama-34b-instruct-Q4_K_M.gguf", "CodeLlama 34B").
hf_model("meta-llama/CodeLlama-70b-Instruct-hf-GGUF", "llama", 70.0, "q4_k_m", "codellama-70b-instruct-Q4_K_M.gguf", "CodeLlama 70B").
hf_model("TinyLlama/TinyLlama-1.1B-Chat-v1.0-GGUF", "llama", 1.1, "q8_0", "tinyllama-1.1b-chat-v1.0-Q8_0.gguf", "TinyLlama 1.1B").
hf_model("meta-llama/Llama-Guard-3-8B-GGUF", "llama", 8.0, "q4_k_m", "Llama-Guard-3-8B-Q4_K_M.gguf", "Llama Guard 3 8B Safety").
hf_model("mistralai/Mistral-7B-Instruct-v0.3-GGUF", "mistral", 7.0, "q4_k_m", "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf", "Mistral 7B v0.3").
hf_model("mistralai/Mixtral-8x7B-Instruct-v0.1-GGUF", "mistral", 47.0, "q4_k_m", "Mixtral-8x7B-Instruct-v0.1-Q4_K_M.gguf", "Mixtral 8x7B MoE").
hf_model("mistralai/Mistral-Large-Instruct-2411-GGUF", "mistral", 123.0, "q4_0", "Mistral-Large-Instruct-2411-Q4_0.gguf", "Mistral Large 123B").
hf_model("mistralai/Mistral-Small-Instruct-2409-GGUF", "mistral", 22.0, "q4_k_m", "Mistral-Small-Instruct-2409-Q4_K_M.gguf", "Mistral Small 22B").
hf_model("mistralai/Mistral-Nemo-Instruct-2407-GGUF", "mistral", 12.0, "q4_k_m", "Mistral-Nemo-Instruct-2407-Q4_K_M.gguf", "Mistral Nemo 12B").
hf_model("mistralai/Mixtral-8x22B-Instruct-v0.1-GGUF", "mistral", 141.0, "q4_0", "Mixtral-8x22B-Instruct-v0.1-Q4_0.gguf", "Mixtral 8x22B MoE").
hf_model("mistralai/Codestral-22B-v0.1-GGUF", "mistral", 22.0, "q4_k_m", "Codestral-22B-v0.1-Q4_K_M.gguf", "Codestral 22B").
hf_model("mistralai/Pixtral-12B-2409-GGUF", "mistral", 12.0, "q4_k_m", "Pixtral-12B-2409-Q4_K_M.gguf", "Pixtral 12B Vision").
hf_model("microsoft/Phi-3.5-mini-instruct-GGUF", "phi", 3.8, "q4_k_m", "Phi-3.5-mini-instruct-Q4_K_M.gguf", "Phi-3.5 Mini 3.8B").
hf_model("microsoft/Phi-4-GGUF", "phi", 14.0, "q4_k_m", "Phi-4-Q4_K_M.gguf", "Phi-4 14B").
hf_model("microsoft/Phi-3-medium-128k-instruct-GGUF", "phi", 14.0, "q4_k_m", "Phi-3-medium-128k-instruct-Q4_K_M.gguf", "Phi-3 Medium 14B").
hf_model("microsoft/phi-2-GGUF", "phi", 2.7, "q4_k_m", "phi-2-Q4_K_M.gguf", "Phi-2 2.7B").
hf_model("microsoft/Phi-3-mini-4k-instruct-GGUF", "phi", 3.8, "q4_k_m", "Phi-3-mini-4k-instruct-Q4_K_M.gguf", "Phi-3 Mini 4K").
hf_model("Qwen/Qwen2.5-72B-Instruct-GGUF", "qwen", 72.0, "q4_k_m", "Qwen2.5-72B-Instruct-Q4_K_M.gguf", "Qwen 2.5 72B").
hf_model("Qwen/Qwen2.5-32B-Instruct-GGUF", "qwen", 32.0, "q4_k_m", "Qwen2.5-32B-Instruct-Q4_K_M.gguf", "Qwen 2.5 32B").
hf_model("Qwen/Qwen2.5-14B-Instruct-GGUF", "qwen", 14.0, "q4_k_m", "Qwen2.5-14B-Instruct-Q4_K_M.gguf", "Qwen 2.5 14B").
hf_model("Qwen/Qwen2.5-7B-Instruct-GGUF", "qwen", 7.0, "q4_k_m", "Qwen2.5-7B-Instruct-Q4_K_M.gguf", "Qwen 2.5 7B").
hf_model("Qwen/Qwen2.5-3B-Instruct-GGUF", "qwen", 3.0, "q4_k_m", "Qwen2.5-3B-Instruct-Q4_K_M.gguf", "Qwen 2.5 3B").
hf_model("Qwen/Qwen2.5-1.5B-Instruct-GGUF", "qwen", 1.5, "q8_0", "Qwen2.5-1.5B-Instruct-Q8_0.gguf", "Qwen 2.5 1.5B").
hf_model("Qwen/Qwen2.5-0.5B-Instruct-GGUF", "qwen", 0.5, "q8_0", "Qwen2.5-0.5B-Instruct-Q8_0.gguf", "Qwen 2.5 0.5B").
hf_model("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", "qwen", 7.0, "q4_k_m", "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf", "Qwen 2.5 Coder 7B").
hf_model("Qwen/Qwen2.5-Coder-32B-Instruct-GGUF", "qwen", 32.0, "q4_k_m", "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf", "Qwen 2.5 Coder 32B").
hf_model("Qwen/QwQ-32B-Preview-GGUF", "qwen", 32.0, "q4_k_m", "QwQ-32B-Preview-Q4_K_M.gguf", "QwQ 32B Reasoning").
hf_model("google/gemma-2-27b-it-GGUF", "gemma", 27.0, "q4_k_m", "gemma-2-27b-it-Q4_K_M.gguf", "Gemma 2 27B").
hf_model("google/gemma-2-9b-it-GGUF", "gemma", 9.0, "q4_k_m", "gemma-2-9b-it-Q4_K_M.gguf", "Gemma 2 9B").
hf_model("google/gemma-2-2b-it-GGUF", "gemma", 2.0, "q4_k_m", "gemma-2-2b-it-Q4_K_M.gguf", "Gemma 2 2B").
hf_model("google/gemma-3-12b-it-GGUF", "gemma", 12.0, "q4_k_m", "gemma-3-12b-it-Q4_K_M.gguf", "Gemma 3 12B").
hf_model("google/codegemma-7b-it-GGUF", "gemma", 7.0, "q4_k_m", "codegemma-7b-it-Q4_K_M.gguf", "CodeGemma 7B").
hf_model("deepseek-ai/DeepSeek-V3-GGUF", "deepseek", 671.0, "q4_0", "DeepSeek-V3-Q4_0.gguf", "DeepSeek V3 671B MoE").
hf_model("deepseek-ai/DeepSeek-V2.5-GGUF", "deepseek", 236.0, "q4_0", "DeepSeek-V2.5-Q4_0.gguf", "DeepSeek V2.5 236B MoE").
hf_model("deepseek-ai/DeepSeek-Coder-V2-Instruct-GGUF", "deepseek", 236.0, "q4_0", "DeepSeek-Coder-V2-Instruct-Q4_0.gguf", "DeepSeek Coder V2").
hf_model("deepseek-ai/DeepSeek-R1-GGUF", "deepseek", 671.0, "q4_0", "DeepSeek-R1-Q4_0.gguf", "DeepSeek R1 671B Reasoning").
hf_model("deepseek-ai/DeepSeek-R1-Distill-Qwen-7B-GGUF", "deepseek", 7.0, "q4_k_m", "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf", "DeepSeek R1 Distill 7B").
hf_model("01-ai/Yi-1.5-34B-Chat-GGUF", "yi", 34.0, "q4_k_m", "Yi-1.5-34B-Chat-Q4_K_M.gguf", "Yi 1.5 34B Chat").
hf_model("01-ai/Yi-1.5-9B-Chat-GGUF", "yi", 9.0, "q4_k_m", "Yi-1.5-9B-Chat-Q4_K_M.gguf", "Yi 1.5 9B Chat").
hf_model("01-ai/Yi-1.5-6B-Chat-GGUF", "yi", 6.0, "q4_k_m", "Yi-1.5-6B-Chat-Q4_K_M.gguf", "Yi 1.5 6B Chat").
hf_model("01-ai/Yi-Coder-9B-Chat-GGUF", "yi", 9.0, "q4_k_m", "Yi-Coder-9B-Chat-Q4_K_M.gguf", "Yi Coder 9B").
hf_model("THUDM/chatglm3-6b-GGUF", "chatglm", 6.0, "q4_k_m", "chatglm3-6b-Q4_K_M.gguf", "ChatGLM3 6B").
hf_model("THUDM/glm-4-9b-chat-GGUF", "chatglm", 9.0, "q4_k_m", "glm-4-9b-chat-Q4_K_M.gguf", "GLM-4 9B Chat").
hf_model("THUDM/codegeex4-all-9b-GGUF", "chatglm", 9.0, "q4_k_m", "codegeex4-all-9b-Q4_K_M.gguf", "CodeGeeX4 9B").
hf_model("internlm/internlm2_5-7b-chat-GGUF", "internlm", 7.0, "q4_k_m", "internlm2_5-7b-chat-Q4_K_M.gguf", "InternLM 2.5 7B").
hf_model("internlm/internlm2_5-20b-chat-GGUF", "internlm", 20.0, "q4_k_m", "internlm2_5-20b-chat-Q4_K_M.gguf", "InternLM 2.5 20B").
hf_model("CohereForAI/c4ai-command-r-plus-GGUF", "command_r", 104.0, "q4_0", "c4ai-command-r-plus-Q4_0.gguf", "Command R+ 104B").
hf_model("CohereForAI/c4ai-command-r-v01-GGUF", "command_r", 35.0, "q4_k_m", "c4ai-command-r-v01-Q4_K_M.gguf", "Command R 35B").
hf_model("bigcode/starcoder2-15b-GGUF", "starcoder", 15.0, "q4_k_m", "starcoder2-15b-Q4_K_M.gguf", "StarCoder2 15B").
hf_model("bigcode/starcoder2-7b-GGUF", "starcoder", 7.0, "q4_k_m", "starcoder2-7b-Q4_K_M.gguf", "StarCoder2 7B").
hf_model("bigcode/starcoder2-3b-GGUF", "starcoder", 3.0, "q4_k_m", "starcoder2-3b-Q4_K_M.gguf", "StarCoder2 3B").
hf_model("tiiuae/Falcon3-10B-Instruct-GGUF", "falcon", 10.0, "q4_k_m", "Falcon3-10B-Instruct-Q4_K_M.gguf", "Falcon 3 10B").
hf_model("tiiuae/Falcon3-7B-Instruct-GGUF", "falcon", 7.0, "q4_k_m", "Falcon3-7B-Instruct-Q4_K_M.gguf", "Falcon 3 7B").
hf_model("databricks/dbrx-instruct-GGUF", "dbrx", 132.0, "q4_k_m", "dbrx-instruct-Q4_K_M.gguf", "DBRX 132B MoE").
hf_model("baichuan-inc/Baichuan2-13B-Chat-GGUF", "baichuan", 13.0, "q4_k_m", "Baichuan2-13B-Chat-Q4_K_M.gguf", "Baichuan 2 13B").
hf_model("baichuan-inc/Baichuan2-7B-Chat-GGUF", "baichuan", 7.0, "q4_k_m", "Baichuan2-7B-Chat-Q4_K_M.gguf", "Baichuan 2 7B").
hf_model("ai21labs/Jamba-v0.1-GGUF", "jamba", 52.0, "q4_0", "Jamba-v0.1-Q4_0.gguf", "Jamba v0.1 52B SSM-Transformer").
hf_model("ai21labs/Jamba-1.5-Mini-GGUF", "jamba", 12.0, "q4_k_m", "Jamba-1.5-Mini-Q4_K_M.gguf", "Jamba 1.5 Mini 12B").
hf_model("allenai/OLMo-2-7B-Instruct-GGUF", "olmo", 7.0, "q4_k_m", "OLMo-2-7B-Instruct-Q4_K_M.gguf", "OLMo 2 7B").
hf_model("allenai/OLMo-2-13B-Instruct-GGUF", "olmo", 13.0, "q4_k_m", "OLMo-2-13B-Instruct-Q4_K_M.gguf", "OLMo 2 13B").
hf_model("nvidia/Nemotron-4-340B-Instruct-GGUF", "nemotron", 340.0, "q4_0", "Nemotron-4-340B-Instruct-Q4_0.gguf", "Nemotron 4 340B").
hf_model("nvidia/Llama-3.1-Nemotron-70B-Instruct-GGUF", "nemotron", 70.0, "q4_k_m", "Llama-3.1-Nemotron-70B-Q4_K_M.gguf", "Nemotron 70B").
hf_model("nvidia/Nemotron-Mini-4B-Instruct-GGUF", "nemotron", 4.0, "q8_0", "Nemotron-Mini-4B-Instruct-Q8_0.gguf", "Nemotron Mini 4B").
hf_model("ibm-granite/granite-3.1-8b-instruct-GGUF", "granite", 8.0, "q4_k_m", "granite-3.1-8b-instruct-Q4_K_M.gguf", "Granite 3.1 8B").
hf_model("ibm-granite/granite-3.1-2b-instruct-GGUF", "granite", 2.0, "q4_k_m", "granite-3.1-2b-instruct-Q4_K_M.gguf", "Granite 3.1 2B").
hf_model("ibm-granite/granite-34b-code-instruct-GGUF", "granite", 34.0, "q4_k_m", "granite-34b-code-instruct-Q4_K_M.gguf", "Granite 34B Code").
hf_model("upstage/SOLAR-10.7B-Instruct-v1.0-GGUF", "solar", 10.7, "q4_k_m", "SOLAR-10.7B-Instruct-v1.0-Q4_K_M.gguf", "SOLAR 10.7B").
hf_model("openbmb/MiniCPM3-4B-GGUF", "minicpm", 4.0, "q4_k_m", "MiniCPM3-4B-Q4_K_M.gguf", "MiniCPM3 4B").
hf_model("openbmb/MiniCPM-2B-GGUF", "minicpm", 2.0, "q4_k_m", "MiniCPM-2B-Q4_K_M.gguf", "MiniCPM 2B").
hf_model("RWKV/rwkv-6-world-7b-GGUF", "rwkv", 7.0, "q4_k_m", "rwkv-6-world-7b-Q4_K_M.gguf", "RWKV-6 World 7B").
hf_model("RWKV/rwkv-6-world-3b-GGUF", "rwkv", 3.0, "q4_k_m", "rwkv-6-world-3b-Q4_K_M.gguf", "RWKV-6 World 3B").
hf_model("mosaicml/mpt-7b-chat-GGUF", "mpt", 7.0, "q4_k_m", "mpt-7b-chat-Q4_K_M.gguf", "MPT 7B Chat").
hf_model("mosaicml/mpt-30b-chat-GGUF", "mpt", 30.0, "q4_k_m", "mpt-30b-chat-Q4_K_M.gguf", "MPT 30B Chat").
hf_model("Snowflake/snowflake-arctic-instruct-GGUF", "arctic", 480.0, "q4_0", "snowflake-arctic-instruct-Q4_0.gguf", "Arctic 480B MoE").
hf_model("deepseek-ai/DeepSeek-R1-Distill-Llama-70B-GGUF", "deepseek", 70.0, "q4_k_m", "DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf", "DeepSeek R1 Distill Llama 70B").
hf_model("deepseek-ai/DeepSeek-R1-Distill-Llama-8B-GGUF", "deepseek", 8.0, "q4_k_m", "DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf", "DeepSeek R1 Distill 8B").
hf_model("Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF", "qwen", 1.5, "q8_0", "Qwen2.5-Coder-1.5B-Instruct-Q8_0.gguf", "Qwen 2.5 Coder 1.5B").
hf_model("Qwen/Qwen2-VL-7B-Instruct-GGUF", "qwen", 7.0, "q4_k_m", "Qwen2-VL-7B-Instruct-Q4_K_M.gguf", "Qwen 2 VL 7B Vision").
hf_model("internlm/internlm2_5-1_8b-chat-GGUF", "internlm", 1.8, "q8_0", "internlm2_5-1_8b-chat-Q8_0.gguf", "InternLM 2.5 1.8B").
hf_model("allenai/OLMo-1.7-7B-hf-GGUF", "olmo", 7.0, "q4_k_m", "OLMo-1.7-7B-hf-Q4_K_M.gguf", "OLMo 1.7 7B").
hf_model("openbmb/MiniCPM-V-2_6-GGUF", "minicpm", 8.0, "q4_k_m", "MiniCPM-V-2_6-Q4_K_M.gguf", "MiniCPM-V 2.6 Vision").
hf_model("tiiuae/Falcon3-3B-Instruct-GGUF", "falcon", 3.0, "q4_k_m", "Falcon3-3B-Instruct-Q4_K_M.gguf", "Falcon 3 3B").
hf_model("google/gemma-3-4b-it-GGUF", "gemma", 4.0, "q4_k_m", "gemma-3-4b-it-Q4_K_M.gguf", "Gemma 3 4B").
hf_model("meta-llama/Llama-3.2-11B-Vision-Instruct-GGUF", "llama", 11.0, "q4_k_m", "Llama-3.2-11B-Vision-Q4_K_M.gguf", "Llama 3.2 11B Vision").
hf_model("microsoft/Phi-3.5-MoE-instruct-GGUF", "phi", 42.0, "q4_0", "Phi-3.5-MoE-instruct-Q4_0.gguf", "Phi-3.5 MoE 42B").
hf_model("mistralai/Mistral-7B-Instruct-v0.2-GGUF", "mistral", 7.0, "q4_k_m", "Mistral-7B-Instruct-v0.2-Q4_K_M.gguf", "Mistral 7B v0.2").
hf_model("nvidia/Llama-3.1-Nemotron-51B-Instruct-GGUF", "nemotron", 51.0, "q4_k_m", "Llama-3.1-Nemotron-51B-Q4_K_M.gguf", "Nemotron 51B").
hf_model("upstage/SOLAR-Mini-1B-GGUF", "solar", 1.0, "q8_0", "SOLAR-Mini-1B-Q8_0.gguf", "SOLAR Mini 1B").
hf_model("Snowflake/snowflake-arctic-embed-l-GGUF", "arctic", 335.0, "q4_0", "snowflake-arctic-embed-l-Q4_0.gguf", "Arctic Embed Large").

% =============================================================================
% Qwen3.5 Family (T4-optimized)
% =============================================================================
% hf_model(repo, family, params_B, t4_recommended_quant, gguf_file, description)
%
% T4 VRAM budget: 16 GB.  Model footprint at each quant:
%   0.8B: FP16 1.6 GB  Q8 0.8 GB  Q4 0.44 GB   → serve Q8_0 (max quality on T4)
%   9B  : FP16 18 GB   Q8 9 GB    Q4 5 GB       → serve Q4_K_M (fits; Q8 also fits)
%   35B : FP16 70 GB   Q8 35 GB   Q4 19 GB  Q3 13 GB → serve Q3_K_M only on T4
hf_model("Qwen/Qwen3.5-0.8B-Instruct-GGUF", "qwen35", 0.8, "q8_0",
    "Qwen3.5-0.8B-Instruct-Q8_0.gguf", "Qwen 3.5 0.8B Instruct").
hf_model("Qwen/Qwen3.5-9B-Instruct-GGUF",   "qwen35", 9.0, "q4_k_m",
    "Qwen3.5-9B-Instruct-Q4_K_M.gguf",   "Qwen 3.5 9B Instruct").
hf_model("Qwen/Qwen3.5-35B-Instruct-GGUF",  "qwen35", 35.0, "q3_k_m",
    "Qwen3.5-35B-Instruct-Q3_K_M.gguf",  "Qwen 3.5 35B Instruct").

% Architecture facts used by t4_optimization.mg to calculate batch size,
% KV-cache budget, and context-length limits.
% model_params_billions, model_hidden_dim, model_layers, model_heads_kv,
% model_hidden_dim, model_vocab_size are consumed by t4_optimization rules.

% Qwen3.5-0.8B: tiny, GQA 2:1 (16Q / 8KV), head_dim=64
model_params_billions("qwen3.5-0.8b", 0.8).
model_hidden_dim("qwen3.5-0.8b", 1024).
model_layers("qwen3.5-0.8b", 28).
model_heads_kv("qwen3.5-0.8b", 8).
model_vocab_size("qwen3.5-0.8b", 151936).

% Qwen3.5-9B: GQA 4:1 (32Q / 8KV), head_dim=128
model_params_billions("qwen3.5-9b", 9.0).
model_hidden_dim("qwen3.5-9b", 4096).
model_layers("qwen3.5-9b", 36).
model_heads_kv("qwen3.5-9b", 8).
model_vocab_size("qwen3.5-9b", 151936).

% Qwen3.5-35B: GQA 8:1 (64Q / 8KV), head_dim=128
model_params_billions("qwen3.5-35b", 35.0).
model_hidden_dim("qwen3.5-35b", 7168).
model_layers("qwen3.5-35b", 64).
model_heads_kv("qwen3.5-35b", 8).
model_vocab_size("qwen3.5-35b", 151936).

% Memory footprints (MB) at each quantization — override default formula
% for more accurate T4 planning.
model_memory_fp16_mb("qwen3.5-0.8b", 1600).
model_memory_int8_mb("qwen3.5-0.8b", 800).
model_memory_int4_mb("qwen3.5-0.8b", 440).

model_memory_fp16_mb("qwen3.5-9b", 18000).
model_memory_int8_mb("qwen3.5-9b", 9000).
model_memory_int4_mb("qwen3.5-9b", 5000).

model_memory_fp16_mb("qwen3.5-35b", 70000).
model_memory_int8_mb("qwen3.5-35b", 35000).
model_memory_int4_mb("qwen3.5-35b", 19250).  % Q4_K_M 0.55 B/param — too large for T4

% Q3_K_M footprint for 35B: 35 * 1024 * 0.375 = ~13440 MB — fits with 2.5 GB for KV
model_memory_q3_mb("qwen3.5-35b", 13440).

% T4-specific tuning recommendations (injected as Mangle runtime facts at startup)
% qwen35_t4_config(model_id, recommended_quant, max_context, max_concurrent_req)
qwen35_t4_config("qwen3.5-0.8b", "q8_0", 32768, 80).
qwen35_t4_config("qwen3.5-9b",   "q4_k_m", 8192, 14).
qwen35_t4_config("qwen3.5-35b",  "q3_k_m", 2048, 3).

% === VRAM Estimation Rules ===
% Approximate VRAM (MB) = param_billions * quant_multiplier
% quant_bytes_per_param(quant, bytes)
quant_bytes_per_param("q2_k",   0.25).
quant_bytes_per_param("q3_k_m", 0.375).
quant_bytes_per_param("q4_0",   0.5).
quant_bytes_per_param("q4_k_m", 0.55).
quant_bytes_per_param("q5_k_m", 0.65).
quant_bytes_per_param("q6_k",   0.75).
quant_bytes_per_param("q8_0",   1.0).
quant_bytes_per_param("f16",    2.0).
quant_bytes_per_param("f32",    4.0).

% SAP Object Store path derivation: object_store_key(repo_id, quant, path)
% Path format: models/gguf/{org}/{model}/{quant}/{filename}
object_store_prefix("models/gguf").
