#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT="${REPO_ROOT}/process_check_app"
PORT="${PROCESS_CHECK_HTTP_PORT:-${PROCESS_CHECK_UI_PORT:-8000}}"
SYNC_UI="${SYNC_MOONSHOT_UI:-1}"

if [[ "${SYNC_UI}" == "1" ]]; then
  "${REPO_ROOT}/scripts/sync_moonshot_console_ui.sh"
fi

echo "Serving Process Check UI from ${APP_ROOT} on port ${PORT}"
python3 -m http.server "${PORT}" --directory "${APP_ROOT}"
