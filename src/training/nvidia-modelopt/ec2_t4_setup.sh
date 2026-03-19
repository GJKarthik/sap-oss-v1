#!/bin/bash
# EC2 T4 GPU Setup Script
# For AWS g4dn instances with NVIDIA T4 (16GB)
#
# Usage:
#   chmod +x ec2_t4_setup.sh
#   ./ec2_t4_setup.sh
#
# Target: ec2-54-158-157-13.compute-1.amazonaws.com

set -e

echo "=========================================="
echo "EC2 T4 GPU Training Environment Setup"
echo "=========================================="

# Check if running on EC2 with T4
echo "[1/8] Checking GPU..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total --format=csv
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    if [[ "$GPU_NAME" == *"T4"* ]]; then
        echo "✅ NVIDIA T4 GPU detected"
    else
        echo "⚠️  GPU detected: $GPU_NAME (not T4, config may need adjustment)"
    fi
else
    echo "❌ nvidia-smi not found. Is CUDA installed?"
    exit 1
fi

# Check CUDA version
echo ""
echo "[2/8] Checking CUDA..."
if command -v nvcc &> /dev/null; then
    nvcc --version | grep "release"
else
    echo "⚠️  nvcc not found. Checking nvidia-smi for CUDA version..."
    nvidia-smi | grep "CUDA Version"
fi

# Install system dependencies
echo ""
echo "[3/8] Installing system dependencies..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y python3-pip python3-venv git wget
elif command -v yum &> /dev/null; then
    sudo yum update -y
    sudo yum install -y python3-pip python3 git wget
fi

# Create virtual environment
echo ""
echo "[4/8] Setting up Python virtual environment..."
cd "$(dirname "$0")"
VENV_DIR="${PWD}/.venv-t4"

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install --upgrade pip

# Install PyTorch with CUDA
echo ""
echo "[5/8] Installing PyTorch with CUDA support..."
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install training dependencies
echo ""
echo "[6/8] Installing training dependencies..."
pip install \
    transformers>=4.38.0 \
    datasets>=2.16.0 \
    accelerate>=0.26.0 \
    peft>=0.8.0 \
    trl>=0.7.10 \
    bitsandbytes>=0.42.0 \
    scipy \
    tensorboard \
    pyyaml \
    safetensors \
    sentencepiece \
    protobuf

# Verify installation
echo ""
echo "[7/8] Verifying installation..."
python3 << 'EOF'
import torch
import transformers
import peft
import bitsandbytes

print(f"PyTorch version: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"CUDA version: {torch.version.cuda}")
    print(f"GPU: {torch.cuda.get_device_name(0)}")
    print(f"GPU Memory: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")
print(f"Transformers version: {transformers.__version__}")
print(f"PEFT version: {peft.__version__}")
print(f"BitsAndBytes version: {bitsandbytes.__version__}")
EOF

# Create test script
echo ""
echo "[8/8] Creating quick test script..."
cat > test_t4_training.py << 'TESTSCRIPT'
#!/usr/bin/env python3
"""
Quick T4 GPU Training Test
Tests model loading and basic forward pass with 4-bit quantization
"""
import os
import sys
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

def test_gpu():
    """Test GPU availability"""
    print("=" * 50)
    print("GPU Test")
    print("=" * 50)
    
    if not torch.cuda.is_available():
        print("❌ CUDA not available!")
        return False
    
    device = torch.device("cuda:0")
    print(f"✅ CUDA available")
    print(f"   Device: {torch.cuda.get_device_name(0)}")
    print(f"   Memory: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")
    
    # Quick memory test
    x = torch.randn(1000, 1000, device=device)
    y = torch.matmul(x, x)
    del x, y
    torch.cuda.empty_cache()
    print(f"   Memory test: ✅ Passed")
    
    return True

def test_model_loading():
    """Test 4-bit model loading"""
    print("\n" + "=" * 50)
    print("Model Loading Test (4-bit)")
    print("=" * 50)
    
    model_name = "Qwen/Qwen2.5-1.5B-Instruct"  # Smaller model for quick test
    
    print(f"Loading {model_name} with 4-bit quantization...")
    
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_use_double_quant=True,
    )
    
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
        model = AutoModelForCausalLM.from_pretrained(
            model_name,
            quantization_config=bnb_config,
            device_map="auto",
            trust_remote_code=True,
        )
        
        print(f"✅ Model loaded successfully")
        print(f"   Model dtype: {next(model.parameters()).dtype}")
        
        # Memory usage
        memory_used = torch.cuda.memory_allocated() / 1e9
        memory_total = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"   GPU Memory: {memory_used:.1f} / {memory_total:.1f} GB ({100*memory_used/memory_total:.1f}%)")
        
        # Quick inference test
        print("\nTesting inference...")
        inputs = tokenizer("What is SQL?", return_tensors="pt").to("cuda")
        with torch.no_grad():
            outputs = model.generate(**inputs, max_new_tokens=20)
        response = tokenizer.decode(outputs[0], skip_special_tokens=True)
        print(f"   Input: 'What is SQL?'")
        print(f"   Output: '{response[:100]}...'")
        print(f"✅ Inference test passed")
        
        del model, tokenizer
        torch.cuda.empty_cache()
        return True
        
    except Exception as e:
        print(f"❌ Model loading failed: {e}")
        return False

def test_lora():
    """Test LoRA adapter creation"""
    print("\n" + "=" * 50)
    print("LoRA Adapter Test")
    print("=" * 50)
    
    try:
        from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
        
        model_name = "Qwen/Qwen2.5-1.5B-Instruct"
        
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_quant_type="nf4",
        )
        
        model = AutoModelForCausalLM.from_pretrained(
            model_name,
            quantization_config=bnb_config,
            device_map="auto",
            trust_remote_code=True,
        )
        
        model = prepare_model_for_kbit_training(model)
        
        lora_config = LoraConfig(
            r=8,
            lora_alpha=16,
            target_modules=["q_proj", "v_proj"],
            lora_dropout=0.05,
            bias="none",
            task_type="CAUSAL_LM",
        )
        
        model = get_peft_model(model, lora_config)
        
        trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
        all_params = sum(p.numel() for p in model.parameters())
        print(f"✅ LoRA adapter created")
        print(f"   Trainable params: {trainable_params:,} ({100*trainable_params/all_params:.2f}%)")
        print(f"   Total params: {all_params:,}")
        
        del model
        torch.cuda.empty_cache()
        return True
        
    except Exception as e:
        print(f"❌ LoRA test failed: {e}")
        return False

def main():
    print("=" * 50)
    print("T4 GPU Training Environment Test")
    print("=" * 50)
    
    results = {
        "GPU": test_gpu(),
        "Model Loading": test_model_loading(),
        "LoRA": test_lora(),
    }
    
    print("\n" + "=" * 50)
    print("Summary")
    print("=" * 50)
    
    all_passed = True
    for test, passed in results.items():
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"  {test}: {status}")
        if not passed:
            all_passed = False
    
    if all_passed:
        print("\n🎉 All tests passed! Ready for training.")
        print("\nTo start training:")
        print("  python scripts/prune_retrain_workflow.py --config configs/t4_qwen_7b.yaml")
    else:
        print("\n⚠️  Some tests failed. Check errors above.")
        sys.exit(1)

if __name__ == "__main__":
    main()
TESTSCRIPT

chmod +x test_t4_training.py

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "To activate the environment:"
echo "  source $VENV_DIR/bin/activate"
echo ""
echo "To run quick tests:"
echo "  python test_t4_training.py"
echo ""
echo "To start training:"
echo "  python scripts/prune_retrain_workflow.py --config configs/t4_qwen_7b.yaml"
echo ""