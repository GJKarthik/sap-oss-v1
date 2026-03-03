#!/usr/bin/env python3
"""
NVIDIA Model Optimizer HTTP Server
Production-ready server with Uvicorn + Gunicorn support
"""

import os
import sys
import argparse
import logging
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("server.log")
    ]
)
logger = logging.getLogger("modelopt-server")


def parse_args():
    parser = argparse.ArgumentParser(
        description="NVIDIA Model Optimizer HTTP Server",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Development mode (auto-reload)
  python server.py --dev

  # Production mode
  python server.py --host 0.0.0.0 --port 8001

  # With workers (production)
  python server.py --workers 4

  # With SSL
  python server.py --ssl-cert cert.pem --ssl-key key.pem
        """
    )
    
    parser.add_argument(
        "--host",
        type=str,
        default=os.getenv("HOST", "0.0.0.0"),
        help="Host to bind (default: 0.0.0.0)"
    )
    
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.getenv("PORT", "8001")),
        help="Port to bind (default: 8001)"
    )
    
    parser.add_argument(
        "--workers",
        type=int,
        default=int(os.getenv("WORKERS", "1")),
        help="Number of worker processes (default: 1)"
    )
    
    parser.add_argument(
        "--dev",
        action="store_true",
        help="Development mode with auto-reload"
    )
    
    parser.add_argument(
        "--ssl-cert",
        type=str,
        help="SSL certificate file"
    )
    
    parser.add_argument(
        "--ssl-key",
        type=str,
        help="SSL key file"
    )
    
    parser.add_argument(
        "--log-level",
        type=str,
        default=os.getenv("LOG_LEVEL", "info"),
        choices=["debug", "info", "warning", "error", "critical"],
        help="Log level (default: info)"
    )
    
    parser.add_argument(
        "--access-log",
        action="store_true",
        default=True,
        help="Enable access logging"
    )
    
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Request timeout in seconds (default: 120)"
    )
    
    return parser.parse_args()


def run_dev_server(args):
    """Run development server with auto-reload."""
    import uvicorn
    
    logger.info(f"Starting development server on http://{args.host}:{args.port}")
    logger.info("Auto-reload enabled - changes will restart the server")
    
    uvicorn.run(
        "api.main:app",
        host=args.host,
        port=args.port,
        reload=True,
        reload_dirs=["api"],
        log_level=args.log_level,
        access_log=args.access_log,
    )


def run_prod_server(args):
    """Run production server with Uvicorn."""
    import uvicorn
    
    logger.info(f"Starting production server on http://{args.host}:{args.port}")
    logger.info(f"Workers: {args.workers}")
    
    ssl_options = {}
    if args.ssl_cert and args.ssl_key:
        ssl_options = {
            "ssl_certfile": args.ssl_cert,
            "ssl_keyfile": args.ssl_key,
        }
        logger.info(f"SSL enabled with cert: {args.ssl_cert}")
    
    uvicorn.run(
        "api.main:app",
        host=args.host,
        port=args.port,
        workers=args.workers,
        log_level=args.log_level,
        access_log=args.access_log,
        timeout_keep_alive=args.timeout,
        **ssl_options
    )


def run_gunicorn_server(args):
    """Run production server with Gunicorn (Linux only)."""
    import subprocess
    
    cmd = [
        "gunicorn",
        "api.main:app",
        "-w", str(args.workers),
        "-k", "uvicorn.workers.UvicornWorker",
        "-b", f"{args.host}:{args.port}",
        "--timeout", str(args.timeout),
        "--log-level", args.log_level,
    ]
    
    if args.access_log:
        cmd.extend(["--access-logfile", "-"])
    
    if args.ssl_cert and args.ssl_key:
        cmd.extend(["--certfile", args.ssl_cert, "--keyfile", args.ssl_key])
    
    logger.info(f"Starting Gunicorn server: {' '.join(cmd)}")
    subprocess.run(cmd)


def main():
    args = parse_args()
    
    # Add current directory to path
    sys.path.insert(0, str(Path(__file__).parent))
    
    logger.info("=" * 60)
    logger.info("NVIDIA Model Optimizer HTTP Server")
    logger.info("=" * 60)
    logger.info(f"Host: {args.host}")
    logger.info(f"Port: {args.port}")
    logger.info(f"Workers: {args.workers}")
    logger.info(f"Mode: {'Development' if args.dev else 'Production'}")
    logger.info("=" * 60)
    
    # Print OpenAI-compatible endpoints
    print("""
OpenAI-Compatible Endpoints:
  GET  /v1/models              - List available models
  GET  /v1/models/{id}         - Get model info
  POST /v1/chat/completions    - Chat completion
  POST /v1/embeddings          - Create embeddings

Model Optimizer Endpoints:
  GET  /health                 - Health check
  GET  /gpu/status             - GPU status
  GET  /models/catalog         - Model catalog
  GET  /models/quant-formats   - Supported formats
  POST /jobs                   - Create optimization job
  GET  /jobs                   - List jobs
  GET  /jobs/{id}              - Get job details
    """)
    
    try:
        if args.dev:
            run_dev_server(args)
        else:
            run_prod_server(args)
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()