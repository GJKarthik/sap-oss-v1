#!/bin/bash
# =============================================================================
# Spec-Drift Pre-Commit Hook
# Path: scripts/spec-drift/pre-commit-hook.sh
# =============================================================================
# This script runs the spec-drift auditor on staged files before commit.
# Install by running: ln -sf ../../scripts/spec-drift/pre-commit-hook.sh .git/hooks/pre-commit
# Or use the pre-commit framework with .pre-commit-config.yaml
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔍 Running Spec-Drift Pre-Commit Audit...${NC}"

# Get list of staged files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)

if [ -z "$STAGED_FILES" ]; then
    echo -e "${GREEN}✓ No staged files to audit${NC}"
    exit 0
fi

# Filter for governed files only
GOVERNED_FILES=""
for file in $STAGED_FILES; do
    if [[ $file == docs/latex/specs/* ]] || \
       [[ $file == docs/schema/* ]] || \
       [[ $file == src/* ]] || \
       [[ $file == */.clinerules* ]]; then
        GOVERNED_FILES="$GOVERNED_FILES $file"
    fi
done

if [ -z "$GOVERNED_FILES" ]; then
    echo -e "${GREEN}✓ No governed files in staged changes${NC}"
    exit 0
fi

echo "Checking files:$GOVERNED_FILES"

# Run the audit script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit.py"

if [ ! -f "$AUDIT_SCRIPT" ]; then
    echo -e "${YELLOW}⚠️  Warning: Audit script not found at $AUDIT_SCRIPT${NC}"
    echo -e "${YELLOW}   Skipping spec-drift check${NC}"
    exit 0
fi

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}⚠️  Warning: Python3 not found, skipping spec-drift audit${NC}"
    exit 0
fi

# Check if PyYAML is available
if ! python3 -c "import yaml" &> /dev/null; then
    echo -e "${YELLOW}⚠️  Warning: PyYAML not installed, skipping spec-drift audit${NC}"
    echo -e "${YELLOW}   Install with: pip install pyyaml${NC}"
    exit 0
fi

# Run the audit
python3 "$AUDIT_SCRIPT" \
    --mode pre-commit \
    --changed-files $GOVERNED_FILES \
    --output-format console \
    --no-fail-on-blocking

AUDIT_EXIT_CODE=$?

if [ $AUDIT_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Spec-drift audit passed${NC}"
else
    echo -e "${RED}✗ Spec-drift audit found issues${NC}"
    echo -e "${YELLOW}Review the findings above and either:${NC}"
    echo -e "${YELLOW}  1. Update related artifacts in the same commit${NC}"
    echo -e "${YELLOW}  2. Document why no update is needed in commit message${NC}"
    echo -e "${YELLOW}  3. Add a drift exception if this is intentional${NC}"
    # Don't block commit in pre-commit, just warn
    # To make it blocking, change --no-fail-on-blocking to --fail-on-blocking
fi

exit 0