#!/bin/bash
# NVIDIA Model Optimizer Setup Script for T4 GPU
# This script automates the installation and configuration of NVIDIA ModelOpt

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  NVIDIA Model Optimizer Setup for T4 GPU${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

# Check if running on macOS (for development) or Linux (for deployment)
OS_TYPE=$(uname -s)
echo -e "${YELLOW}Detected OS: ${OS_TYPE}${NC}"

# Function to check Python version
check_python() {
    if command -v python3 &> /dev/null; then
        PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
        PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)
        
        if [ "$PYTHON_MAJOR" -ge 3 ] && [ "$PYTHON_MINOR" -ge 10 ]; then
            echo -e "${GREEN}✓ Python ${PYTHON_VERSION} detected${NC}"
            return 0
        else
            echo -e "${RED}✗ Python 3.10+ required, found ${PYTHON_VERSION}${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ Python3 not found${NC}"
        return 1
    fi
}

# Function to check CUDA
check_cuda() {
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo -e "${YELLOW}⚠ macOS detected - CUDA not available locally${NC}"
        echo -e "${YELLOW}  Model Optimizer will run in CPU mode for testing${NC}"
        echo -e "${YELLOW}  Deploy to a T4 GPU instance for full functionality${NC}"
        return 0
    fi
    
    if command -v nvidia-smi &> /dev/null; then
        echo -e "${GREEN}✓ NVIDIA GPU detected${NC}"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
        return 0
    else
        echo -e "${RED}✗ nvidia-smi not found - CUDA may not be installed${NC}"
        return 1
    fi
}

# Function to check nvcc
check_nvcc() {
    if [ "$OS_TYPE" = "Darwin" ]; then
        return 0
    fi
    
    if command -v nvcc &> /dev/null; then
        CUDA_VERSION=$(nvcc --version | grep "release" | awk '{print $5}' | sed 's/,//')
        echo -e "${GREEN}✓ CUDA ${CUDA_VERSION} detected${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ nvcc not found - CUDA toolkit may not be in PATH${NC}"
        return 0
    fi
}

# Step 1: Check prerequisites
echo -e "\n${YELLOW}Step 1: Checking prerequisites...${NC}"
check_python || { echo -e "${RED}Please install Python 3.10 or higher${NC}"; exit 1; }
check_cuda
check_nvcc

# Step 2: Create virtual environment
echo -e "\n${YELLOW}Step 2: Creating virtual environment...${NC}"
VENV_DIR="venv"
if [ -d "$VENV_DIR" ]; then
    echo -e "${YELLOW}Virtual environment already exists. Skipping creation.${NC}"
else
    python3 -m venv "$VENV_DIR"
    echo -e "${GREEN}✓ Virtual environment created${NC}"
fi

# Activate virtual environment
source "$VENV_DIR/bin/activate"
echo -e "${GREEN}✓ Virtual environment activated${NC}"

# Step 3: Upgrade pip
echo -e "\n${YELLOW}Step 3: Upgrading pip...${NC}"
pip install --upgrade pip

# Step 4: Install requirements
echo -e "\n${YELLOW}Step 4: Installing dependencies...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pip install -r "$SCRIPT_DIR/requirements.txt"

# Step 5: Install NVIDIA Model Optimizer
echo -e "\n${YELLOW}Step 5: Installing NVIDIA Model Optimizer...${NC}"
pip install "nvidia-modelopt[all]" -U --extra-index-url https://pypi.nvidia.com

# Step 6: Clone TensorRT-Model-Optimizer examples (optional)
echo -e "\n${YELLOW}Step 6: Checking for example repository...${NC}"
EXAMPLES_DIR="TensorRT-Model-Optimizer"
if [ -d "$EXAMPLES_DIR" ]; then
    echo -e "${YELLOW}Example repository already exists. Skipping clone.${NC}"
else
    echo -e "${YELLOW}Cloning TensorRT-Model-Optimizer examples...${NC}"
    git clone --depth 1 https://github.com/NVIDIA/TensorRT-Model-Optimizer.git
    echo -e "${GREEN}✓ Examples cloned${NC}"
fi

# Step 7: Run verification
echo -e "\n${YELLOW}Step 7: Running verification...${NC}"
python "$SCRIPT_DIR/scripts/verify_setup.py"

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}  Setup Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "To activate the environment:"
echo -e "  ${YELLOW}source venv/bin/activate${NC}"
echo ""
echo -e "To run INT8 quantization on Qwen3.5:"
echo -e "  ${YELLOW}python scripts/quantize_qwen.py --model Qwen/Qwen3.5-1.8B --qformat int8${NC}"
echo ""
echo -e "For more options, see:"
echo -e "  ${YELLOW}python scripts/quantize_qwen.py --help${NC}"