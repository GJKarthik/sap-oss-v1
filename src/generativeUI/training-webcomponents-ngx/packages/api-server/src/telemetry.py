import warnings

import psutil
try:
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="The pynvml package is deprecated.*",
            category=FutureWarning,
        )
        import pynvml
    HAS_NVML = True
    pynvml.nvmlInit()
except BaseException:
    HAS_NVML = False

def get_system_telemetry() -> dict:
    """Returns GPU metrics if available, otherwise CPU/RAM metrics"""
    if dict and HAS_NVML:
        try:
            handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            name = pynvml.nvmlDeviceGetName(handle)
            mem_info = pynvml.nvmlDeviceGetMemoryInfo(handle)
            util = pynvml.nvmlDeviceGetUtilizationRates(handle)
            temp = pynvml.nvmlDeviceGetTemperature(handle, pynvml.NVML_TEMPERATURE_GPU)
            
            if isinstance(name, bytes):
                name = name.decode('utf-8')
            
            driver_ver = pynvml.nvmlSystemGetDriverVersion()
            if isinstance(driver_ver, bytes):
                driver_ver = driver_ver.decode('utf-8')
                
            return {
                "gpu_name": name,
                "total_memory_gb": round(mem_info.total / (1024**3), 1),
                "used_memory_gb": round(mem_info.used / (1024**3), 1),
                "free_memory_gb": round(mem_info.free / (1024**3), 1),
                "utilization_percent": util.gpu,
                "temperature_c": temp,
                "driver_version": driver_ver,
                "cuda_version": "Detected"
            }
        except Exception:
            pass # Fallback to CPU safely
            
    # Fallback to general system stats (CPU/RAM)
    vm = psutil.virtual_memory()
    return {
        "gpu_name": "System CPU / Unified Memory",
        "total_memory_gb": round(vm.total / (1024**3), 1),
        "used_memory_gb": round(vm.used / (1024**3), 1),
        "free_memory_gb": round(vm.available / (1024**3), 1),
        "utilization_percent": int(psutil.cpu_percent(interval=None)),
        "temperature_c": 40,  # Fallback dummy thermal
        "driver_version": "N/A",
        "cuda_version": "N/A"
    }
