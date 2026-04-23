# Domain Specifications

This directory contains the **four core domain specifications** for the SAP AI Platform plus one cross-domain supplementary specification for `.clinerules` agents:

| Domain | Specification | LaTeX Source | PDF |
|--------|--------------|--------------|-----|
| **Arabic** | Arabic AP Invoice Processing | `arabic/arabic-ap-spec.tex` | `arabic-ap-spec.pdf` |
| **TB** | Trial Balance Review | `tb/tb-review-spec.tex` | `tb-review-spec.pdf` |
| **Regulations** | AI Governance & Compliance | `regulations/regulations-spec.tex` | `regulations-spec.pdf` |
| **Simula** | Training Data Framework | `simula/simula-training-spec.tex` | `simula-training-spec.pdf` |
| **Supplementary** | `.clinerules` Agent Swarm | `clinerules-agents/clinerules-agents-spec.tex` | `clinerules-agents-spec.pdf` |

## Directory Structure

```
specs/
├── arabic/                      # Arabic AP Invoice Processing
│   ├── arabic-ap-spec.tex       # Main document
│   └── chapters/                # 8 chapter files
│       ├── 00-frontmatter.tex
│       ├── 01-overview.tex
│       ├── 02-data-schema.tex
│       ├── 03-ai-pipeline.tex
│       ├── 04-vat-engine.tex
│       ├── 05-ap-workflow.tex
│       ├── 06-controls-and-testing.tex
│       └── 07-references.tex
│
├── tb/                          # Trial Balance Review
│   ├── tb-review-spec.tex       # Main document
│   └── chapters/                # 8 chapter files
│       ├── 00-frontmatter.tex
│       ├── 01-overview.tex
│       ├── 02-data-schema.tex
│       ├── 03-ai-pipeline.tex
│       ├── 04-controls-engine.tex
│       ├── 05-workflow.tex
│       ├── 06-controls-and-testing.tex
│       └── 07-references.tex
│
├── regulations/                 # AI Governance & Compliance
│   ├── regulations-spec.tex     # Main document
│   └── chapters/                # 8 chapter files
│       ├── 00-frontmatter.tex
│       ├── 01-overview.tex
│       ├── 02-data-schema.tex
│       ├── 03-mgf-framework.tex
│       ├── 04-agent-index.tex
│       ├── 05-empirical-evidence.tex
│       ├── 06-conformance-tooling.tex
│       └── 07-references.tex
│
├── clinerules-agents/           # Cross-domain .clinerules agent supplement
│   ├── clinerules-agents-spec.tex
│   └── chapters/
│       ├── 00-frontmatter.tex
│       ├── 01-overview.tex
│       ├── 02-regulatory-alignment.tex
│       ├── 03-agent-rule-pack-architecture.tex
│       ├── 04-regulatory-agents.tex
│       ├── 05-swarm-delivery.tex
│       ├── 06-validation.tex
│       └── 07-references.tex
│
└── simula/                      # Training Data Framework
    ├── simula-training-spec.tex # Main document
    └── chapters/                # 8 chapter files
        ├── 00-frontmatter.tex
        ├── 01-overview.tex
        ├── 02-data-schema.tex
        ├── 03-extraction-pipeline.tex
        ├── 04-taxonomy-engine.tex
        ├── 05-generation-engine.tex
        ├── 06-environment-cli.tex
        └── 07-references.tex
```

## Building PDFs

```bash
# From repository root:

# Build all specs, including the supplementary agent-swarm book
make specs-all

# Build individual specs
make spec-arabic       # Arabic AP Invoice
make spec-tb           # Trial Balance Review
make spec-regulations  # AI Regulations
make spec-simula       # Simula Training Data
make spec-clinerules-agents  # .clinerules Agent Swarm supplement

# Export to Word
make specs-docx
```

## Output Locations

| Output | Directory |
|--------|-----------|
| PDF files | `docs/pdf/specs/` |
| Word files | `docs/docx/specs/` |

**Note:** For specs with complex LaTeX (code listings), the Makefile uses pandoc. If pandoc fails, use pdf2docx:
```bash
pip install pdf2docx
python3 -c "from pdf2docx import Converter; cv = Converter('docs/pdf/specs/<name>.pdf'); cv.convert('docs/docx/specs/<name>.docx'); cv.close()"
```

## Specification Summaries

### 1. Arabic AP Invoice Processing (`arabic/`)

Specifies the AI-assisted accounts payable processing for Arabic invoices:
- Multi-language OCR for Arabic/English
- VAT calculation engine (Saudi ZATCA compliance)
- Document classification and data extraction
- Integration with SAP S/4HANA AP module

### 2. Trial Balance Review (`tb/`)

Specifies the AI-assisted month-end close controls:
- TB variance analysis with materiality thresholds
- P&L review anomaly detection
- Control workflow orchestration
- Audit trail and evidence generation

### 3. AI Regulations Compliance (`regulations/`)

Specifies conformance with AI governance frameworks:
- Singapore IMDA Model Governance Framework (MGF)
- AI Agent Index compliance
- Empirical testing methodology
- Conformance tooling integration

### 4. Simula Training Data Framework (`simula/`)

Specifies the synthetic training data generation pipeline:
- Taxonomy extraction from HANA schemas
- Multi-agent data generation (GPT-4o/Claude)
- Complexity calibration and diversity optimization
- Quality validation with critic agents

### 5. `.clinerules` Agent Swarm Supplement (`clinerules-agents/`)

Specifies the repository-wide operating model for `.clinerules` rule packs:
- Development and runtime-monitor agent split
- Alignment of all agent packs to the Regulations specification
- Placement conventions for domain rule packs and validation harnesses
- Swarm roles used to deliver and maintain `docs/pdf/specs/`

## Adding New Specifications

1. Create a new directory under `specs/`:
   ```bash
   mkdir -p docs/latex/specs/<domain>/chapters
   ```

2. Create the main `.tex` file and chapter files (optional)

3. Add a Make target in the root `Makefile`:
   ```makefile
   spec-<domain>:
       cd $(SPECS_LATEX)/<domain> && pdflatex ...
   ```

4. Add to `specs-all` and `specs-docx` targets

## Related Source Code

Each specification has corresponding implementation code:

| Specification | Code Location |
|---------------|---------------|
| Arabic | `src/intelligence/ocr/` |
| TB | `docs/tb/` (business docs) |
| Regulations | `src/intelligence/` and gateway/governance integration surfaces |
| Simula | `src/training/pipeline/` |
| `.clinerules` Agent Swarm | `src/*/.clinerules`, `src/*/.clinerules.runtime-monitor` |
