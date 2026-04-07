#!/bin/bash
# Upload TinyLlama GGUF model to SAP AI Core S3 Object Store

set -e

# S3 Configuration from AI Core Object Store Secret
S3_BUCKET="hcp-4bf99a2c-376e-4f6b-b787-32d388b846de"
S3_PREFIX="ai/default"
S3_REGION="ap-southeast-1"
S3_ENDPOINT="https://s3-ap-southeast-1.amazonaws.com"

# Model configuration
MODEL_NAME="tinyllama-1.1b-chat.Q8_0.gguf"
MODEL_URL="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf"
MODEL_DIR="models/tinyllama"

echo "=== SAP AI Core S3 Model Upload ==="
echo "Bucket: $S3_BUCKET"
echo "Prefix: $S3_PREFIX"
echo "Region: $S3_REGION"
echo ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI not installed"
    echo "Install with: brew install awscli"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "ERROR: AWS credentials not configured"
    echo "Configure with: aws configure"
    echo ""
    echo "You'll need the Access Key and Secret Key from AI Core Object Store Secret"
    exit 1
fi

# Download model if not exists
if [ ! -f "$MODEL_NAME" ]; then
    echo "Downloading $MODEL_NAME from HuggingFace..."
    curl -L -o "$MODEL_NAME" "$MODEL_URL"
    echo "Download complete: $(du -h "$MODEL_NAME" | cut -f1)"
else
    echo "Model already exists: $(du -h "$MODEL_NAME" | cut -f1)"
fi

# Upload to S3
S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${MODEL_DIR}/${MODEL_NAME}"
echo ""
echo "Uploading to: $S3_PATH"
aws s3 cp "$MODEL_NAME" "$S3_PATH" \
    --endpoint-url "$S3_ENDPOINT" \
    --region "$S3_REGION"

echo ""
echo "=== Upload Complete ==="
echo ""
echo "Model uploaded to: ai://default/${MODEL_DIR}"
echo ""
echo "Register artifact in AI Core:"
echo ""
cat << EOF
curl -X POST "https://<ai-core-url>/v2/lm/artifacts" \\
  -H "Authorization: Bearer \$TOKEN" \\
  -H "AI-Resource-Group: default" \\
  -H "Content-Type: application/json" \\
  -d '{
    "name": "tinyllama-model",
    "kind": "model",
    "url": "ai://default/${MODEL_DIR}",
    "description": "TinyLlama 1.1B Chat Q8_0 GGUF",
    "scenarioId": "privatellm"
  }'
EOF