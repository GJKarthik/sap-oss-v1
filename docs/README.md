# SAP OSS Documentation Pipeline

This directory contains all documentation for the SAP OSS AI Platform, with **LaTeX source files**, **generated PDFs**, and **Word documents** in separate folders.

## Directory Structure

```
docs/
├── latex/                       # LaTeX source files (.tex)
│   ├── sbom/                    # SBOM documents (17 files)
│   │   ├── sbom-lineage.tex     # Combined SBOM report
│   │   ├── sbom-*.tex           # Per-service reports
│   │   └── SAP-OSS-SBOM-*.tex   # Comprehensive SBOMs
│   ├── technical-reports/       # Technical reports (5 files)
│   │   ├── 03-prompt-routing.tex
│   │   ├── 04-trial-balance-ai-specification.tex
│   │   ├── 06-singapore-ai-safety-framework.tex
│   │   ├── 07-singapore-ai-safety-approval-pack.tex
│   │   └── 08-simula-training-data-framework.tex
│   └── specs/                   # Domain specifications
│       ├── arabic/              # Arabic AP Invoice (9 .tex files)
│       ├── tb/                  # Trial Balance Review (9 .tex files)
│       └── regulations/         # AI Regulations (9 .tex files)
│
├── pdf/                         # Generated PDFs
│   ├── sbom/                    # SBOM PDFs
│   ├── technical-reports/       # Technical report PDFs
│   └── specs/                   # Specification PDFs
│
├── docx/                        # Generated Word documents
│   ├── sbom/                    # SBOM DOCX files
│   ├── technical-reports/       # Technical report DOCX files
│   └── specs/                   # Specification DOCX files
│
├── api/                         # OpenAPI specifications
├── arabic/                      # Arabic invoice source documents
├── business-briefs/             # Business strategy (Markdown)
├── hana-cloud/                  # HANA Cloud deployment docs
├── regulations/                 # AI governance reference docs
├── runbooks/                    # Operational guides
├── sbom/                        # SBOM JSON data files
└── tb/                          # Trial Balance source documents
```

## LaTeX Document Generation

All LaTeX documents can be compiled to PDF and Word format using the Makefile targets. Outputs go to separate `pdf/` and `docx/` directories.

### Prerequisites

- **LaTeX**: Install MacTeX (macOS) or TeX Live (Linux/Windows)
  ```bash
  # macOS
  brew install --cask mactex
  
  # Alternative: tectonic (lightweight)
  brew install tectonic
  ```

- **Pandoc**: For Word document generation
  ```bash
  brew install pandoc
  ```

### Make Targets

#### SBOM Documents

```bash
# Generate SBOM LaTeX from CycloneDX BOMs
make sbom-lineage           # → docs/latex/sbom/sbom-lineage.tex

# Compile SBOM to PDF
make sbom-lineage-pdf       # → docs/pdf/sbom/sbom-lineage.pdf

# Export SBOM to Word
make sbom-lineage-docx      # → docs/docx/sbom/sbom-lineage.docx

# Generate both PDF and Word
make sbom-lineage-export

# Per-service reports
make sbom-per-service       # Generate .tex files
make sbom-pdf-all-services  # → docs/pdf/sbom/sbom-*.pdf
make sbom-docx-all-services # → docs/docx/sbom/sbom-*.docx
make sbom-export-all-services
```

#### Technical Reports

```bash
# Compile all technical reports to PDF
make technical-reports-pdf    # → docs/pdf/technical-reports/*.pdf

# Export all technical reports to Word
make technical-reports-docx   # → docs/docx/technical-reports/*.docx

# Both PDF and Word
make technical-reports-export
```

#### Domain Specifications

```bash
# Individual specs
make spec-arabic            # → docs/pdf/specs/arabic-ap-spec.pdf
make spec-tb                # → docs/pdf/specs/tb-review-spec.pdf
make spec-regulations       # → docs/pdf/specs/regulations-spec.pdf

# All specs
make specs-all              # Compile all PDFs
make specs-docx             # Export all to Word
make specs-export           # PDF + DOCX
```

### File Locations

| Document Type | LaTeX Source | PDF Output | DOCX Output |
|---------------|--------------|------------|-------------|
| SBOM Combined | `latex/sbom/sbom-lineage.tex` | `pdf/sbom/` | `docx/sbom/` |
| SBOM Per-Service | `latex/sbom/sbom-*.tex` | `pdf/sbom/` | `docx/sbom/` |
| Technical Reports | `latex/technical-reports/*.tex` | `pdf/technical-reports/` | `docx/technical-reports/` |
| Arabic AP Spec | `latex/specs/arabic/*.tex` | `pdf/specs/` | `docx/specs/` |
| TB Review Spec | `latex/specs/tb/*.tex` | `pdf/specs/` | `docx/specs/` |
| Regulations Spec | `latex/specs/regulations/*.tex` | `pdf/specs/` | `docx/specs/` |

## Document Inventory

### LaTeX Source Files (49 total)

**SBOM Documents** (`docs/latex/sbom/`) - 17 files:
- `sbom-lineage.tex` - Combined SBOM report
- `sbom-*.tex` - 13 per-service SBOM reports
- `SAP-OSS-SBOM-*.tex` - 3 comprehensive variants
- `MODIFICATIONS-HISTORY.tex`

**Technical Reports** (`docs/latex/technical-reports/`) - 5 files:
- `03-prompt-routing.tex` - Multi-layer request classification
- `04-trial-balance-ai-specification.tex` - TB review AI specification
- `06-singapore-ai-safety-framework.tex` - AI governance framework
- `07-singapore-ai-safety-approval-pack.tex` - Regulatory approval
- `08-simula-training-data-framework.tex` - Training data generation

**Domain Specifications** (`docs/latex/specs/`) - 27 files:
- `arabic/` - Arabic AP Invoice (9 .tex files)
- `tb/` - Trial Balance Review (9 .tex files)  
- `regulations/` - AI Regulations Compliance (9 .tex files)

## Generation Scripts

All LaTeX generation scripts are located in `scripts/sbom-lineage/`:

| Script | Purpose |
|--------|---------|
| `generate_latex.py` | Generate combined SBOM report from CycloneDX BOMs |
| `gen_per_service.py` | Generate per-service SBOM reports |
| `compile-sbom.sh` | Compile SBOM LaTeX to PDF |
| `generate-latex-from-json.sh` | Generate detailed SBOM from service-inventory.json |
| `generate-full-sbom.sh` | Generate full CycloneDX SBOM |

## CI Integration

The `sbom-check` target verifies that generated files are up-to-date:

```bash
make sbom-check
```

This is used in CI to ensure documentation is regenerated before commits.

## Adding New Documents

### New Technical Report

1. Create a new `.tex` file in `docs/latex/technical-reports/`
2. Use an existing report as a template
3. Run `make technical-reports-pdf` to compile to `docs/pdf/technical-reports/`

### New SBOM Service

1. Add the service to manifest
2. Run `make sbom-per-service` to generate the `.tex` file in `docs/latex/sbom/`
3. Run `make sbom-pdf-all-services` to compile to `docs/pdf/sbom/`

### New Domain Specification

1. Create a new directory under `docs/latex/specs/`
2. Add main `.tex` file and `chapters/` subdirectory
3. Add a Make target in the Makefile

## Troubleshooting

### LaTeX compilation fails

```bash
# Check for pdflatex
which pdflatex

# Or use tectonic (auto-downloads packages)
tectonic docs/latex/technical-reports/03-prompt-routing.tex
```

### Pandoc conversion issues

Some LaTeX features may not convert perfectly to Word. Review the generated `.docx` files and manually adjust if needed.

### Missing packages

If pdflatex reports missing packages:
```bash
# macOS with MacTeX
sudo tlmgr install <package-name>

# Or use tectonic (handles packages automatically)
tectonic <file>.tex
```

## Version History

- **2026-04-18**: Separated tex/pdf/docx into separate directories
  - `docs/latex/` - All LaTeX source files
  - `docs/pdf/` - All generated PDFs
  - `docs/docx/` - All generated Word documents
- **2026-04-18**: Added domain specifications (Arabic, TB, Regulations)
- **2026-04-18**: Reorganized LaTeX generation pipeline
  - Consolidated shell scripts to `scripts/sbom-lineage/`
  - Converted Trial Balance report to LaTeX