#!/bin/bash
set -e

echo "=== Extracting modelopt package ==="
mkdir -p ~/nvidia-modelopt
cd ~/nvidia-modelopt
tar -xzf /tmp/modelopt-deploy.tar.gz

echo "=== Setting up Python environment ==="
python3 -m venv venv
source venv/bin/activate
pip install -q fastapi uvicorn pydantic httpx pytest

echo "=== Running tests ==="
python -m pytest tests/test_api.py -v --tb=short

echo "=== Checking GPU ==="
nvidia-smi || echo "No GPU detected"

echo "=== Starting server ==="
pkill -f "uvicorn api.main:app" 2>/dev/null || true
nohup python -m uvicorn api.main:app --host 0.0.0.0 --port 8001 > /tmp/modelopt.log 2>&1 &
sleep 3

echo "=== Testing endpoints ==="
curl -s http://localhost:8001/ | python -m json.tool
curl -s http://localhost:8001/health | python -m json.tool
curl -s http://localhost:8001/gpu/status | python -m json.tool

echo "=== Deployment complete! ==="
echo "Server running on port 8001"