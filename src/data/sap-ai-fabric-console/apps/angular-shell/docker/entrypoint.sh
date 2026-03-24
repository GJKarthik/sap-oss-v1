#!/bin/sh
set -eu

escape_js() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_sed() {
  printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

API_BASE_URL="${SAP_API_BASE_URL:-/api/v1}"
API_UPSTREAM="${SAP_API_UPSTREAM:-http://api:8000}"
LANGCHAIN_MCP_URL="${SAP_LANGCHAIN_MCP_URL:-}"
STREAMING_MCP_URL="${SAP_STREAMING_MCP_URL:-}"

cat > /usr/share/nginx/html/runtime-config.js <<EOF
window.__SAP_CONFIG__ = {
  apiBaseUrl: "$(escape_js "$API_BASE_URL")",
  langchainMcpUrl: "$(escape_js "$LANGCHAIN_MCP_URL")",
  streamingMcpUrl: "$(escape_js "$STREAMING_MCP_URL")"
};
EOF

sed "s|__SAP_API_UPSTREAM__|$(escape_sed "$API_UPSTREAM")|g" \
  /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf

exec /docker-entrypoint.sh nginx -g 'daemon off;'
