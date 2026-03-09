#!/bin/bash
# Deployment script for nvidia-modelopt to EC2

set -e

EC2_HOST="ec2-54-81-198-135.compute-1.amazonaws.com"
EC2_PORT="2222"
DEPLOY_DIR="/opt/nvidia-modelopt"

echo "=== Deploying nvidia-modelopt to $EC2_HOST:$EC2_PORT ==="

# Package the application
echo "Packaging application..."
cd "$(dirname "$0")"
tar -czf /tmp/nvidia-modelopt.tar.gz \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='venv' \
    --exclude='test_venv' \
    --exclude='node_modules' \
    --exclude='.pytest_cache' \
    --exclude='dist' \
    .

# Copy to server
echo "Copying to server..."
scp -P $EC2_PORT /tmp/nvidia-modelopt.tar.gz ubuntu@$EC2_HOST:/tmp/

# Deploy on server
echo "Deploying on server..."
ssh -p $EC2_PORT ubuntu@$EC2_HOST << 'ENDSSH'
set -e

# Create deployment directory
sudo mkdir -p /opt/nvidia-modelopt
sudo chown ubuntu:ubuntu /opt/nvidia-modelopt

# Extract
cd /opt/nvidia-modelopt
tar -xzf /tmp/nvidia-modelopt.tar.gz

# Setup Python environment
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install fastapi uvicorn pydantic httpx pytest

# Run tests
echo "=== Running tests ==="
python -m pytest tests/test_api.py -v --tb=short

# Start server (in background, using nohup)
echo "=== Starting server ==="
pkill -f "uvicorn api.main:app" || true
nohup python -m uvicorn api.main:app --host 0.0.0.0 --port 8001 > /tmp/modelopt.log 2>&1 &
sleep 3

# Test endpoints
echo "=== Testing endpoints ==="
curl -s http://localhost:8001/ | head -1
curl -s http://localhost:8001/health | head -1
curl -s http://localhost:8001/v1/models | head -1
curl -s http://localhost:8001/gpu/status | head -1

echo "=== Deployment complete ==="
echo "Service running at http://$HOSTNAME:8001"
ENDSSH

# Cleanup
rm /tmp/nvidia-modelopt.tar.gz

echo ""
echo "=== Deployment successful ==="
echo "API available at: http://$EC2_HOST:8001"