#!/usr/bin/env bash
# Create root .env and .secrets from examples for local docker compose bring-up.
# Replace placeholder secret file contents before connecting to real HANA / AI Core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  echo "Keeping existing .env (remove it first to regenerate from .env.example)."
else
  cp .env.example .env
  if [[ "$(uname)" == Darwin ]]; then
    sed -i '' 's|\.secrets\.example/|.secrets/|g' .env
  else
    sed -i 's|\.secrets\.example/|.secrets/|g' .env
  fi
  echo "Created .env from .env.example (secret paths -> .secrets/). Edit HANA_* and AICORE_* URLs."
fi

mkdir -p .secrets
for f in hana_user hana_password aicore_client_id aicore_client_secret; do
  if [[ -f ".secrets/$f" ]]; then
    echo "Skipping existing .secrets/$f"
  else
    cp ".secrets.example/$f" ".secrets/$f"
    echo "Created .secrets/$f from placeholder — overwrite with real credentials."
  fi
done

echo "Done. Next: edit .env and .secrets/* then run docker compose -f docker-compose.yml config -q"
