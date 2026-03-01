#!/usr/bin/env bash
# Build full CycloneDX SBOMs for Python services by installing their
# dependencies into a temporary virtualenv and running cyclonedx-py against
# the active environment.
#
# Requires: cyclonedx-bom >= 4.x (CLI: cyclonedx-py environment ...)
# Install:  pip install cyclonedx-bom
#
# WARNING: Some projects (especially vLLM) require GPU toolchains / CUDA.
# Run on a machine that can install the project. Per-service failures are
# reported but do not stop other services from being processed.
#
# Usage:
#   bash scripts/sbom-lineage/build_full_python_sbom.sh
#   PYTHON_BIN=python3.12 bash scripts/sbom-lineage/build_full_python_sbom.sh
#   SKIP_INSTALL=1 bash ...   # re-use existing venvs, skip pip install

set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SCHEMA_VERSION="${SCHEMA_VERSION:-1.5}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOMS_DIR="$REPO_ROOT/scripts/sbom-lineage/boms"

# Python services — keep in sync with docs/sbom-lineage-manifest.yaml
PYTHON_SERVICES=(
  "data-cleaning-copilot-main"
  "langchain-integration-for-sap-hana-cloud-main"
  "generative-ai-toolkit-for-sap-hana-cloud-main"
  "vllm-main"
)

mkdir -p "$BOMS_DIR"

FAIL=0

_cyclonedx_version() {
  # Returns the major version of the installed cyclonedx-bom package.
  python3 -c "import importlib.metadata; v=importlib.metadata.version('cyclonedx-bom'); print(int(v.split('.')[0]))" 2>/dev/null || echo "0"
}

_run_cyclonedx() {
  local out_file="$1"
  local major
  major=$(_cyclonedx_version)
  if [ "$major" -ge 4 ]; then
    # cyclonedx-bom >= 4.x: uses `cyclonedx-py environment`
    cyclonedx-py environment \
      --output-format json \
      --schema-version "$SCHEMA_VERSION" \
      --output-file "$out_file"
  else
    # cyclonedx-bom 3.x legacy CLI (kept for back-compat)
    cyclonedx-bom \
      --format json \
      --schema-version "$SCHEMA_VERSION" \
      -o "$out_file"
  fi
}

for svc in "${PYTHON_SERVICES[@]}"; do
  PROJ_DIR="$REPO_ROOT/$svc"
  if [ ! -d "$PROJ_DIR" ]; then
    echo "[SKIP] $svc — directory not found"
    continue
  fi

  echo ""
  echo "══════════════════════════════════════════"
  echo "  Building full Python SBOM: $svc"
  echo "══════════════════════════════════════════"

  VENV_DIR="$PROJ_DIR/.sbom-venv"

  # Create venv only if it doesn't exist (or SKIP_INSTALL=0 forces re-create)
  if [ ! -d "$VENV_DIR" ]; then
    echo "Creating venv at $VENV_DIR ..."
    "$PYTHON_BIN" -m venv "$VENV_DIR" \
      || { echo "[ERROR] venv creation failed for $svc"; FAIL=1; continue; }
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate" \
    || { echo "[ERROR] venv activation failed for $svc"; FAIL=1; continue; }

  pip install --quiet --upgrade pip wheel 2>&1 || true

  # Install cyclonedx-bom >= 4 into the venv
  pip install --quiet "cyclonedx-bom>=4.0" \
    || { echo "[ERROR] Failed to install cyclonedx-bom for $svc"; FAIL=1; deactivate; continue; }

  if [ "$SKIP_INSTALL" = "0" ]; then
    echo "Installing $svc into venv (may take a while for large projects)..."
    # Support both pyproject.toml and setup.py projects; use [extras] when present
    if pip install --quiet --editable "$PROJ_DIR" 2>/dev/null \
        || pip install --quiet "$PROJ_DIR"; then
      echo "[OK] Installed $svc"
    else
      echo "[ERROR] pip install failed for $svc"; FAIL=1; deactivate; continue
    fi
  fi

  OUT_FILE="$BOMS_DIR/$svc.cyclonedx.json"
  echo "Running cyclonedx-py -> $OUT_FILE"
  if _run_cyclonedx "$OUT_FILE"; then
    echo "[OK] Wrote $OUT_FILE"
  else
    echo "[ERROR] cyclonedx-py failed for $svc"
    FAIL=1
  fi

  deactivate || true
done

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All Python SBOMs built successfully."
else
  echo "Some SBOMs failed — check output above."
fi
exit "$FAIL"
