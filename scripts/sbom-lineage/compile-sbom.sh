#!/bin/bash
#
# SBOM PDF Generation Script
# Compiles LaTeX SBOM document to PDF
#
# Requirements:
#   - pdflatex (TeXLive or MacTeX)
#   - OR docker with texlive image
#
# Usage:
#   ./compile-sbom.sh           # Uses local pdflatex
#   ./compile-sbom.sh --docker  # Uses Docker container
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SBOM_DIR="$REPO_ROOT/docs/sbom"
TEX_FILE="SAP-OSS-SBOM-Complete.tex"
PDF_OUTPUT="SAP-AI-Platform-SBOM-2026.pdf"

cd "$SBOM_DIR"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║        SAP AI Platform SBOM PDF Generator                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if [ "$1" == "--docker" ]; then
    echo "📦 Using Docker for compilation..."
    
    docker run --rm -v "$SBOM_DIR:/workspace" \
        texlive/texlive:latest \
        bash -c "cd /workspace && pdflatex -interaction=nonstopmode $TEX_FILE && pdflatex -interaction=nonstopmode $TEX_FILE"
    
else
    # Check for pdflatex
    if command -v pdflatex &> /dev/null; then
        echo "📄 Compiling $TEX_FILE with pdflatex..."
        echo ""

        # Run twice to resolve references
        pdflatex -interaction=nonstopmode "$TEX_FILE" || true
        pdflatex -interaction=nonstopmode "$TEX_FILE"
    elif command -v tectonic &> /dev/null; then
        echo "📄 Compiling $TEX_FILE with tectonic..."
        echo ""
        tectonic -X compile "$TEX_FILE"
    else
        echo "❌ No local TeX engine found!"
        echo ""
        echo "Install options:"
        echo "  macOS:   brew install --cask mactex"
        echo "  Fallback: brew install tectonic"
        echo "  Docker:  $0 --docker"
        exit 1
    fi
fi

# Rename output
if [ -f "SAP-OSS-SBOM-Complete.pdf" ]; then
    mv "SAP-OSS-SBOM-Complete.pdf" "$PDF_OUTPUT"
    echo ""
    echo "✅ PDF generated: $PDF_OUTPUT"
    echo ""
    
    # Show file info
    if command -v file &> /dev/null; then
        file "$PDF_OUTPUT"
    fi
    
    # Show page count
    if command -v pdfinfo &> /dev/null; then
        pdfinfo "$PDF_OUTPUT" | grep -E "^Pages:"
    fi
    
    # Cleanup auxiliary files
    rm -f *.aux *.log *.toc *.out *.fls *.fdb_latexmk 2>/dev/null || true
    
    echo ""
    echo "📂 Output: $SBOM_DIR/$PDF_OUTPUT"
else
    echo "❌ PDF generation failed!"
    exit 1
fi