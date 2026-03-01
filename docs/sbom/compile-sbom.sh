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
TEX_FILE="SAP-OSS-SBOM-Complete.tex"
PDF_OUTPUT="SAP-AI-Platform-SBOM-2026.pdf"

cd "$SCRIPT_DIR"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║        SAP AI Platform SBOM PDF Generator                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if [ "$1" == "--docker" ]; then
    echo "📦 Using Docker for compilation..."
    
    docker run --rm -v "$SCRIPT_DIR:/workspace" \
        texlive/texlive:latest \
        bash -c "cd /workspace && pdflatex -interaction=nonstopmode $TEX_FILE && pdflatex -interaction=nonstopmode $TEX_FILE"
    
else
    # Check for pdflatex
    if ! command -v pdflatex &> /dev/null; then
        echo "❌ pdflatex not found!"
        echo ""
        echo "Install options:"
        echo "  macOS:   brew install --cask mactex"
        echo "  Ubuntu:  sudo apt-get install texlive-full"
        echo "  Docker:  $0 --docker"
        exit 1
    fi

    echo "📄 Compiling $TEX_FILE..."
    echo ""
    
    # Run twice to resolve references
    pdflatex -interaction=nonstopmode "$TEX_FILE" || true
    pdflatex -interaction=nonstopmode "$TEX_FILE"
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
    echo "📂 Output: $SCRIPT_DIR/$PDF_OUTPUT"
else
    echo "❌ PDF generation failed!"
    exit 1
fi