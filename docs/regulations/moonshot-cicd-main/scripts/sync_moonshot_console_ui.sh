#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_WORKSPACE="${MOONSHOT_UI5_NX_ROOT:-/Users/user/Documents/sap-ai-suite/sdk/sap-sdk/sap-ui5-webcomponents-ngx}"
UI_APP_DIR="${UI_WORKSPACE}/apps/moonshot-console"
UI_DIST_DIR="${UI_WORKSPACE}/dist/apps/moonshot-console"
TARGET_ASSET_DIR="${REPO_ROOT}/process_check_app/assets/moonshot_console"
CANONICAL_SOURCE_DIR="${REPO_ROOT}/process_check_app/frontend/moonshot_console_src"

if [[ ! -d "${UI_WORKSPACE}" ]]; then
  echo "UI workspace not found: ${UI_WORKSPACE}" >&2
  echo "Set MOONSHOT_UI5_NX_ROOT to your sap-ui5-webcomponents-ngx path." >&2
  exit 1
fi

if [[ ! -d "${UI_APP_DIR}" ]]; then
  echo "Moonshot console app source not found: ${UI_APP_DIR}" >&2
  exit 1
fi

# Prefer the tracked source in moonshot-cicd-main as canonical app source.
if [[ -d "${CANONICAL_SOURCE_DIR}" ]]; then
  rsync -a --delete "${CANONICAL_SOURCE_DIR}/" "${UI_APP_DIR}/"
fi

pushd "${UI_WORKSPACE}" >/dev/null
NX_DAEMON=false yarn nx build moonshot-console \
  --configuration development \
  --base-href /assets/moonshot_console/ \
  --deploy-url /assets/moonshot_console/
popd >/dev/null

if [[ ! -d "${UI_DIST_DIR}" ]]; then
  echo "Build output not found: ${UI_DIST_DIR}" >&2
  exit 1
fi

mkdir -p "${TARGET_ASSET_DIR}"
mkdir -p "${CANONICAL_SOURCE_DIR}"

rsync -a --delete "${UI_DIST_DIR}/" "${TARGET_ASSET_DIR}/"
rsync -a --delete "${UI_APP_DIR}/" "${CANONICAL_SOURCE_DIR}/"

echo "Moonshot console synced to: ${TARGET_ASSET_DIR}"
echo "Moonshot console source mirrored to: ${CANONICAL_SOURCE_DIR}"
