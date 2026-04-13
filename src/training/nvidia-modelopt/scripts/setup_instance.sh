#!/bin/bash
# setup_instance.sh - Install all dependencies for training
# Run this on each GPU instance (T4, L4, H200)

set -e

echo "=========================================="
echo "Setting up training environment"
echo "=========================================="

# Detect GPU
echo "Detecting GPU..."
nvidia-smi --query-gpu=name,memory.total --format=csv

# Install Python packages
echo ""
echo "Installing Python packages..."
pip install --upgrade pip

pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

pip install \
    transformers>=4.40.0 \
    datasets>=2.18.0 \
    accelerate>=0.28.0 \
    peft>=0.10.0 \
    bitsandbytes>=0.43.0 \
    trl>=0.8.0 \
    sentencepiece \
    protobuf \
    tensorboard \
    wandb

# Install Flash Attention 2 (for H200/L4)
echo ""
echo "Installing Flash Attention 2..."
pip install flash-attn --no-build-isolation || echo "Flash Attention install failed (ok for T4)"

# Clone repo
echo ""
echo "Setting up training data..."
cd /workspace 2>/dev/null || cd ~

if [ ! -d "sap-oss-v1" ]; then
    git clone https://github.com/GJKarthik/sap-oss-v1.git sap-oss-v1
fi

cd sap-oss-v1/src/training

# Generate training data
echo ""
echo "Generating 100K training examples per specialist..."
cd schema_pipeline
python specialist_data_generator.py --output-dir ../data/specialist_training --examples 100000

echo ""
echo "=========================================="
echo "Setup complete! Training data ready."
echo "=========================================="
echo ""
echo "Next steps:"
echo "  cd nvidia-modelopt/scripts"
echo "  python train_h200.py --specialist performance  # For H200"
echo "  python train_l4.py --specialist treasury       # For L4"
echo "  python train_t4.py --specialist router         # For T4"