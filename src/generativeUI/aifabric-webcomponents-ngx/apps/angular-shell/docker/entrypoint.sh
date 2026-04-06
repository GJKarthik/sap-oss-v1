#!/bin/sh
set -eu

escape_js() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

API_BASE_URL="${SAP_API_BASE_URL:-/api/v1}"
ELASTICSEARCH_MCP_URL="${SAP_ELASTICSEARCH_MCP_URL:-${SAP_LANGCHAIN_MCP_URL:-}}"
PAL_MCP_URL="${SAP_PAL_MCP_URL:-${SAP_STREAMING_MCP_URL:-}}"

cat > /usr/share/nginx/html/runtime-config.js <<EOF
window.__SAP_CONFIG__ = {
  apiBaseUrl: "$(escape_js "$API_BASE_URL")",
  elasticsearchMcpUrl: "$(escape_js "$ELASTICSEARCH_MCP_URL")",
  palMcpUrl: "$(escape_js "$PAL_MCP_URL")"
};
EOF

exec /docker-entrypoint.sh nginx -g 'daemon off;'
