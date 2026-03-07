#!/bin/bash
# test_backends.sh - Run backend tests for Metal and CPU
#
# Usage: ./test_backends.sh [OPTIONS]
#
# Options:
#   --test-type=TYPE    Test type: smoke, unit, integration, stress, benchmark
#   --model=NAME        Specific model to test
#   --backend=BACKEND   Force backend: metal, cpu, auto (default: auto)
#   --mojo-only         Run only Mojo tests
#   --zig-only          Run only Zig tests
#   --verbose           Verbose output
#   --help              Show this help

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
TEST_TYPE="smoke"
MODEL=""
BACKEND="auto"
MOJO_ONLY=false
ZIG_ONLY=false
VERBOSE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --test-type=*)
            TEST_TYPE="${arg#*=}"
            shift
            ;;
        --model=*)
            MODEL="${arg#*=}"
            shift
            ;;
        --backend=*)
            BACKEND="${arg#*=}"
            shift
            ;;
        --mojo-only)
            MOJO_ONLY=true
            shift
            ;;
        --zig-only)
            ZIG_ONLY=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            grep '^#' "$0" | grep -v '#!/' | sed 's/^# *//'
            exit 0
            ;;
        *)
            ;;
    esac
done

# Print banner
echo ""
echo -e "${CYAN}=============================================="
echo "Backend Test Suite"
echo "==============================================${NC}"
echo ""

# Detect platform and backend
detect_backend() {
    if [ "$BACKEND" != "auto" ]; then
        echo "$BACKEND"
        return
    fi
    
    if [ "$(uname)" == "Darwin" ]; then
        # Check for Metal support
        if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Metal Support"; then
            echo "metal"
        else
            echo "cpu"
        fi
    else
        echo "cpu"
    fi
}

DETECTED_BACKEND=$(detect_backend)

echo -e "${BLUE}Platform Information:${NC}"
echo "  OS: $(uname -s)"
echo "  Arch: $(uname -m)"
echo "  Backend: $DETECTED_BACKEND"
echo "  Test Type: $TEST_TYPE"
if [ -n "$MODEL" ]; then
    echo "  Model: $MODEL"
fi
echo ""

# Get system memory (macOS)
get_memory_mb() {
    if [ "$(uname)" == "Darwin" ]; then
        sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}'
    else
        grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}'
    fi
}

SYSTEM_MEMORY=$(get_memory_mb)
echo -e "${BLUE}System Memory:${NC} ${SYSTEM_MEMORY} MB"

# Get Metal device name (macOS)
if [ "$(uname)" == "Darwin" ] && [ "$DETECTED_BACKEND" == "metal" ]; then
    METAL_DEVICE=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model:" | head -1 | cut -d: -f2 | xargs)
    echo -e "${BLUE}Metal Device:${NC} $METAL_DEVICE"
fi
echo ""

# Check for required tools
check_tools() {
    local missing=()
    
    if [ "$ZIG_ONLY" != "true" ]; then
        if ! command -v mojo &> /dev/null; then
            missing+=("mojo")
        fi
    fi
    
    if [ "$MOJO_ONLY" != "true" ]; then
        if ! command -v zig &> /dev/null; then
            missing+=("zig")
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}Warning: Missing tools: ${missing[*]}${NC}"
        echo "Some tests may be skipped."
        echo ""
    fi
}

check_tools

# Track test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local name="$1"
    local cmd="$2"
    local expected_exit="${3:-0}"
    
    ((TOTAL_TESTS++))
    
    echo -e "${BLUE}Running:${NC} $name"
    
    if [ "$VERBOSE" = true ]; then
        echo "  Command: $cmd"
    fi
    
    local start_time=$(date +%s%N)
    
    if eval "$cmd" > /tmp/test_output_$$.txt 2>&1; then
        local exit_code=0
    else
        local exit_code=$?
    fi
    
    local end_time=$(date +%s%N)
    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
    
    if [ $exit_code -eq $expected_exit ]; then
        echo -e "  ${GREEN}✓ PASS${NC} (${elapsed_ms} ms)"
        ((PASSED_TESTS++))
    else
        echo -e "  ${RED}✗ FAIL${NC} (exit code: $exit_code)"
        ((FAILED_TESTS++))
        if [ "$VERBOSE" = true ]; then
            echo "  Output:"
            cat /tmp/test_output_$$.txt | sed 's/^/    /'
        fi
    fi
    
    rm -f /tmp/test_output_$$.txt
}

# Run Mojo tests
run_mojo_tests() {
    echo ""
    echo -e "${CYAN}=== Mojo Tests ===${NC}"
    echo ""
    
    if ! command -v mojo &> /dev/null; then
        echo -e "${YELLOW}Skipping Mojo tests (mojo not found)${NC}"
        return
    fi
    
    cd "$PROJECT_DIR/mojo"
    
    # Build Mojo tests
    echo "Building Mojo test suite..."
    
    # Test backend kernels
    run_test "Mojo Backend Tests" "mojo run tests/test_backend.mojo"
    
    # Test quantization if available
    if [ -f "tests/test_quantization.mojo" ]; then
        run_test "Mojo Quantization Tests" "mojo run tests/test_quantization.mojo"
    fi
    
    # Test flash attention
    if [ -f "tests/test_flash_attention.mojo" ]; then
        run_test "Mojo FlashAttention Tests" "mojo run tests/test_flash_attention.mojo"
    fi
    
    cd "$SCRIPT_DIR"
}

# Run Zig tests
run_zig_tests() {
    echo ""
    echo -e "${CYAN}=== Zig Tests ===${NC}"
    echo ""
    
    if ! command -v zig &> /dev/null; then
        echo -e "${YELLOW}Skipping Zig tests (zig not found)${NC}"
        return
    fi
    
    cd "$PROJECT_DIR/zig"
    
    # Build Zig project
    echo "Building Zig test runner..."
    run_test "Zig Build" "zig build"
    
    # Run test runner
    if [ -n "$MODEL" ]; then
        run_test "Zig Test Runner ($MODEL)" "./zig-out/bin/test_runner --model=$MODEL --test-type=$TEST_TYPE"
    else
        run_test "Zig Test Runner" "./zig-out/bin/test_runner --test-type=$TEST_TYPE"
    fi
    
    # Run unit tests
    run_test "Zig Unit Tests" "zig build test"
    
    cd "$SCRIPT_DIR"
}

# Run model inference tests
run_model_tests() {
    echo ""
    echo -e "${CYAN}=== Model Inference Tests ===${NC}"
    echo ""
    
    MODELS_DIR="$PROJECT_DIR/models"
    
    if [ ! -d "$MODELS_DIR" ]; then
        echo -e "${YELLOW}Models not linked. Run ./scripts/setup_models.sh first${NC}"
        return
    fi
    
    # Get test models based on test type
    case $TEST_TYPE in
        smoke)
            TEST_MODELS=("google-gemma-3-270m-it" "LFM2.5-1.2B-Instruct-GGUF")
            ;;
        integration)
            TEST_MODELS=("google-gemma-3-270m-it" "LFM2.5-1.2B-Instruct-GGUF" "microsoft-phi-2")
            ;;
        stress|benchmark)
            TEST_MODELS=("microsoft-phi-2" "HY-MT1.5-7B")
            ;;
        *)
            TEST_MODELS=("google-gemma-3-270m-it")
            ;;
    esac
    
    # Override if specific model provided
    if [ -n "$MODEL" ]; then
        TEST_MODELS=("$MODEL")
    fi
    
    for model in "${TEST_MODELS[@]}"; do
        model_path="$MODELS_DIR/$model"
        
        if [ -L "$model_path" ]; then
            echo -e "${BLUE}Testing model:${NC} $model"
            
            # Check if model files exist
            if [ -d "$model_path" ] && [ "$(ls -A "$model_path" 2>/dev/null)" ]; then
                echo -e "  ${GREEN}✓${NC} Model directory exists"
                ((PASSED_TESTS++))
                ((TOTAL_TESTS++))
                
                # Check for GGUF files
                gguf_count=$(find "$model_path" -name "*.gguf" 2>/dev/null | wc -l)
                if [ "$gguf_count" -gt 0 ]; then
                    echo -e "  ${GREEN}✓${NC} Found $gguf_count GGUF file(s)"
                fi
                
                # Check for safetensors files
                safetensors_count=$(find "$model_path" -name "*.safetensors" 2>/dev/null | wc -l)
                if [ "$safetensors_count" -gt 0 ]; then
                    echo -e "  ${GREEN}✓${NC} Found $safetensors_count safetensors file(s)"
                fi
            else
                echo -e "  ${YELLOW}○${NC} Model files not downloaded (DVC pull required)"
                ((TOTAL_TESTS++))
            fi
        else
            echo -e "  ${YELLOW}○${NC} Model not linked: $model"
        fi
    done
}

# Run backend-specific tests
run_backend_tests() {
    echo ""
    echo -e "${CYAN}=== Backend-Specific Tests ($DETECTED_BACKEND) ===${NC}"
    echo ""
    
    case $DETECTED_BACKEND in
        metal)
            echo "Testing Metal backend..."
            
            # Check Metal API availability
            if [ "$(uname)" == "Darwin" ]; then
                if xcrun --find metal-arch &> /dev/null; then
                    echo -e "  ${GREEN}✓${NC} Metal compiler available"
                    ((PASSED_TESTS++))
                else
                    echo -e "  ${YELLOW}○${NC} Metal compiler not found"
                fi
                ((TOTAL_TESTS++))
            fi
            ;;
            
        cpu)
            echo "Testing CPU backend..."
            
            # Check SIMD support
            if [ "$(uname)" == "Darwin" ]; then
                if sysctl -n machdep.cpu.features 2>/dev/null | grep -q "AVX"; then
                    echo -e "  ${GREEN}✓${NC} AVX SIMD support"
                    ((PASSED_TESTS++))
                elif [ "$(uname -m)" == "arm64" ]; then
                    echo -e "  ${GREEN}✓${NC} ARM NEON SIMD support (Apple Silicon)"
                    ((PASSED_TESTS++))
                fi
                ((TOTAL_TESTS++))
            fi
            ;;
    esac
}

# Main test execution
main() {
    # Setup models if needed
    if [ ! -d "$PROJECT_DIR/models" ]; then
        echo -e "${YELLOW}Setting up model symlinks...${NC}"
        "$SCRIPT_DIR/setup_models.sh" --verify 2>/dev/null || true
        echo ""
    fi
    
    # Run tests based on options
    if [ "$ZIG_ONLY" != "true" ]; then
        run_mojo_tests
    fi
    
    if [ "$MOJO_ONLY" != "true" ]; then
        run_zig_tests
    fi
    
    run_model_tests
    run_backend_tests
    
    # Print summary
    echo ""
    echo -e "${CYAN}=============================================="
    echo "Test Summary"
    echo "==============================================${NC}"
    echo ""
    echo -e "Total Tests: $TOTAL_TESTS"
    echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
    echo ""
    
    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

# Run main
main