#!/usr/bin/env python3
"""
NVIDIA Model Optimizer Setup Verification Script
Verifies that all dependencies are correctly installed for T4 GPU optimization.
"""

import sys
import platform
from typing import Optional


def print_status(name: str, status: bool, details: str = "") -> None:
    """Print a formatted status line."""
    icon = "✓" if status else "✗"
    color_start = "\033[92m" if status else "\033[91m"
    color_end = "\033[0m"
    detail_str = f" ({details})" if details else ""
    print(f"  {color_start}{icon}{color_end} {name}{detail_str}")


def check_python_version() -> tuple[bool, str]:
    """Check if Python version is 3.10+."""
    version = sys.version_info
    version_str = f"{version.major}.{version.minor}.{version.micro}"
    is_valid = version.major >= 3 and version.minor >= 10
    return is_valid, version_str


def check_torch() -> tuple[bool, str]:
    """Check PyTorch installation and CUDA availability."""
    try:
        import torch
        version = torch.__version__
        cuda_available = torch.cuda.is_available()
        if cuda_available:
            cuda_version = torch.version.cuda
            device_count = torch.cuda.device_count()
            device_name = torch.cuda.get_device_name(0) if device_count > 0 else "Unknown"
            return True, f"v{version}, CUDA {cuda_version}, {device_name}"
        else:
            return True, f"v{version}, CPU only (no CUDA)"
    except ImportError:
        return False, "Not installed"


def check_transformers() -> tuple[bool, str]:
    """Check Transformers library installation."""
    try:
        import transformers
        return True, f"v{transformers.__version__}"
    except ImportError:
        return False, "Not installed"


def check_modelopt() -> tuple[bool, str]:
    """Check NVIDIA Model Optimizer installation."""
    try:
        import modelopt
        version = getattr(modelopt, "__version__", "unknown")
        return True, f"v{version}"
    except ImportError:
        return False, "Not installed - run: pip install 'nvidia-modelopt[all]' -U --extra-index-url https://pypi.nvidia.com"


def check_modelopt_modules() -> dict[str, tuple[bool, str]]:
    """Check individual ModelOpt modules."""
    modules = {}
    
    # Quantization module
    try:
        import modelopt.torch.quantization as mtq
        modules["modelopt.torch.quantization"] = (True, "Available")
    except ImportError as e:
        modules["modelopt.torch.quantization"] = (False, str(e))
    
    # Pruning module
    try:
        import modelopt.torch.prune as mtp
        modules["modelopt.torch.prune"] = (True, "Available")
    except ImportError as e:
        modules["modelopt.torch.prune"] = (False, str(e))
    
    # Export module
    try:
        from modelopt.torch.export import export_hf_checkpoint
        modules["modelopt.torch.export"] = (True, "Available")
    except ImportError as e:
        modules["modelopt.torch.export"] = (False, str(e))
    
    # Speculative decoding module
    try:
        import modelopt.torch.speculative as mtsp
        modules["modelopt.torch.speculative"] = (True, "Available")
    except ImportError as e:
        modules["modelopt.torch.speculative"] = (False, str(e))
    
    return modules


def check_quantization_configs() -> dict[str, tuple[bool, str]]:
    """Check available quantization configurations."""
    configs = {}
    
    try:
        import modelopt.torch.quantization as mtq
        
        # Check INT8 (T4 compatible)
        if hasattr(mtq, "INT8_DEFAULT_CFG"):
            configs["INT8"] = (True, "Available - Recommended for T4")
        else:
            configs["INT8"] = (False, "Config not found")
        
        # Check INT4 (T4 compatible)
        if hasattr(mtq, "INT4_AWQ_CFG") or hasattr(mtq, "W4A16_AWQ_CFG"):
            configs["INT4/W4A16"] = (True, "Available - Best compression for T4")
        else:
            configs["INT4/W4A16"] = (False, "Config not found")
        
        # Check FP8 (NOT T4 compatible - requires Ada+)
        if hasattr(mtq, "FP8_DEFAULT_CFG"):
            configs["FP8"] = (True, "Available - NOT supported on T4 (requires RTX 40xx/H100)")
        else:
            configs["FP8"] = (False, "Config not found")
        
        # Check NVFP4 (NOT T4 compatible - requires Blackwell)
        if hasattr(mtq, "NVFP4_DEFAULT_CFG"):
            configs["NVFP4"] = (True, "Available - NOT supported on T4 (requires Blackwell)")
        else:
            configs["NVFP4"] = (False, "Config not found")
            
    except ImportError:
        configs["INT8"] = (False, "modelopt not installed")
        configs["INT4/W4A16"] = (False, "modelopt not installed")
        configs["FP8"] = (False, "modelopt not installed")
        configs["NVFP4"] = (False, "modelopt not installed")
    
    return configs


def check_gpu_memory() -> tuple[bool, str]:
    """Check GPU memory availability."""
    try:
        import torch
        if torch.cuda.is_available():
            device = torch.cuda.current_device()
            total_memory = torch.cuda.get_device_properties(device).total_memory
            total_gb = total_memory / (1024**3)
            
            # T4 has 16GB
            if total_gb >= 15:  # Account for some overhead
                return True, f"{total_gb:.1f} GB (sufficient for Qwen3.5 with INT8)"
            elif total_gb >= 8:
                return True, f"{total_gb:.1f} GB (use INT4 for larger models)"
            else:
                return False, f"{total_gb:.1f} GB (may be insufficient for large models)"
        else:
            return False, "CUDA not available"
    except Exception as e:
        return False, str(e)


def check_accelerate() -> tuple[bool, str]:
    """Check accelerate library."""
    try:
        import accelerate
        return True, f"v{accelerate.__version__}"
    except ImportError:
        return False, "Not installed"


def check_safetensors() -> tuple[bool, str]:
    """Check safetensors library."""
    try:
        import safetensors
        return True, f"v{safetensors.__version__}"
    except ImportError:
        return False, "Not installed"


def main() -> int:
    """Run all verification checks."""
    print("\n" + "=" * 60)
    print("  NVIDIA Model Optimizer Setup Verification")
    print("  Optimized for T4 GPU (Turing Architecture)")
    print("=" * 60)
    
    all_passed = True
    
    # System information
    print("\n📋 System Information:")
    print(f"  Platform: {platform.system()} {platform.machine()}")
    
    # Python version
    print("\n🐍 Python Environment:")
    py_status, py_details = check_python_version()
    print_status("Python 3.10+", py_status, py_details)
    all_passed &= py_status
    
    # Core dependencies
    print("\n📦 Core Dependencies:")
    
    torch_status, torch_details = check_torch()
    print_status("PyTorch", torch_status, torch_details)
    all_passed &= torch_status
    
    trans_status, trans_details = check_transformers()
    print_status("Transformers", trans_status, trans_details)
    all_passed &= trans_status
    
    acc_status, acc_details = check_accelerate()
    print_status("Accelerate", acc_status, acc_details)
    all_passed &= acc_status
    
    safe_status, safe_details = check_safetensors()
    print_status("Safetensors", safe_status, safe_details)
    all_passed &= safe_status
    
    # NVIDIA Model Optimizer
    print("\n🚀 NVIDIA Model Optimizer:")
    modelopt_status, modelopt_details = check_modelopt()
    print_status("nvidia-modelopt", modelopt_status, modelopt_details)
    all_passed &= modelopt_status
    
    if modelopt_status:
        print("\n  ModelOpt Modules:")
        modules = check_modelopt_modules()
        for name, (status, details) in modules.items():
            short_name = name.split(".")[-1]
            print_status(f"  {short_name}", status, details)
            all_passed &= status
    
    # Quantization configurations
    print("\n⚙️  Quantization Formats:")
    configs = check_quantization_configs()
    for name, (status, details) in configs.items():
        # Mark T4-incompatible formats differently
        if "NOT supported on T4" in details:
            print(f"  ⚠ {name}: {details}")
        else:
            print_status(name, status, details)
    
    # GPU memory check
    print("\n🎮 GPU Memory:")
    mem_status, mem_details = check_gpu_memory()
    print_status("GPU Memory", mem_status, mem_details)
    
    # Summary
    print("\n" + "=" * 60)
    if all_passed:
        print("  ✅ All checks passed! Setup is ready.")
        print("=" * 60)
        print("\n  Next steps:")
        print("  1. Run: python scripts/quantize_qwen.py --help")
        print("  2. Start with: python scripts/quantize_qwen.py --model Qwen/Qwen3.5-1.8B --qformat int8")
        return 0
    else:
        print("  ❌ Some checks failed. Please resolve issues above.")
        print("=" * 60)
        return 1


if __name__ == "__main__":
    sys.exit(main())