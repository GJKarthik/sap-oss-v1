#!/bin/sh
set -eu

if [ "${SKIP_STORE_MIGRATION:-false}" != "true" ]; then
  python scripts/store_admin.py migrate
fi

exec uvicorn src.main:app --host 0.0.0.0 --port 8000
