#!/usr/bin/env python3
"""
Job Executor for Model Optimization
Runs quantization jobs in background
"""

import asyncio
import logging
import subprocess
import sys
from datetime import datetime
from typing import Optional
from pathlib import Path

logger = logging.getLogger(__name__)


class JobExecutor:
    """Execute optimization jobs asynchronously"""
    
    def __init__(self):
        self.running_jobs = {}
    
    async def execute_job(self, job_id: str, config: dict, update_callback) -> None:
        """Execute a quantization job"""
        try:
            await update_callback(job_id, "running", 0.0, started_at=datetime.utcnow())
            
            model_name = config.get("model_name", "Qwen/Qwen3.5-1.8B")
            quant_format = config.get("quant_format", "int8")
            export_format = config.get("export_format", "hf")
            calib_samples = config.get("calib_samples", 512)
            enable_pruning = config.get("enable_pruning", False)
            pruning_sparsity = config.get("pruning_sparsity", 0.2)
            
            # Build command
            script_path = Path(__file__).parent.parent / "scripts" / "quantize_qwen.py"
            output_dir = Path(__file__).parent.parent / "outputs"
            
            cmd = [
                sys.executable,
                str(script_path),
                "--model", model_name,
                "--qformat", quant_format,
                "--output", str(output_dir),
                "--calib-samples", str(calib_samples),
                "--export-format", export_format,
            ]
            
            if enable_pruning:
                cmd.extend(["--enable-pruning", "--pruning-sparsity", str(pruning_sparsity)])
            
            logger.info(f"Starting job {job_id}: {' '.join(cmd)}")
            
            # Run the quantization process
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            
            self.running_jobs[job_id] = process
            
            # Monitor progress
            output_lines = []
            async for line in process.stdout:
                line_text = line.decode().strip()
                output_lines.append(line_text)
                logger.info(f"[{job_id}] {line_text}")
                
                # Parse progress from output
                progress = self._parse_progress(line_text)
                if progress is not None:
                    await update_callback(job_id, "running", progress)
            
            await process.wait()
            
            if process.returncode == 0:
                model_short = model_name.split("/")[-1]
                output_path = str(output_dir / f"{model_short}_{quant_format}")
                await update_callback(
                    job_id, "completed", 100.0,
                    completed_at=datetime.utcnow(),
                    output_path=output_path
                )
                logger.info(f"Job {job_id} completed successfully")
            else:
                error_msg = "\n".join(output_lines[-10:])  # Last 10 lines
                await update_callback(
                    job_id, "failed", 0.0,
                    completed_at=datetime.utcnow(),
                    error=f"Process exited with code {process.returncode}: {error_msg}"
                )
                logger.error(f"Job {job_id} failed with code {process.returncode}")
            
        except asyncio.CancelledError:
            await update_callback(job_id, "cancelled", 0.0, completed_at=datetime.utcnow())
            logger.info(f"Job {job_id} was cancelled")
            raise
        except Exception as e:
            await update_callback(
                job_id, "failed", 0.0,
                completed_at=datetime.utcnow(),
                error=str(e)
            )
            logger.exception(f"Job {job_id} failed with exception")
        finally:
            self.running_jobs.pop(job_id, None)
    
    def _parse_progress(self, line: str) -> Optional[float]:
        """Parse progress percentage from log line"""
        # Look for patterns like "Calibrating: 50%" or "Progress: 0.5"
        import re
        
        # Percentage pattern
        match = re.search(r'(\d+(?:\.\d+)?)\s*%', line)
        if match:
            return float(match.group(1))
        
        # Fraction pattern like "100/512 samples"
        match = re.search(r'(\d+)/(\d+)\s*(?:samples|batches)', line, re.IGNORECASE)
        if match:
            current, total = int(match.group(1)), int(match.group(2))
            return (current / total) * 100 if total > 0 else 0
        
        return None
    
    async def cancel_job(self, job_id: str) -> bool:
        """Cancel a running job"""
        process = self.running_jobs.get(job_id)
        if process:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                process.kill()
            return True
        return False


# Singleton instance
_executor: Optional[JobExecutor] = None


def get_executor() -> JobExecutor:
    """Get the singleton job executor"""
    global _executor
    if _executor is None:
        _executor = JobExecutor()
    return _executor