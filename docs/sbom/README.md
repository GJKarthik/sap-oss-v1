# SAP AI Platform - Software Bill of Materials (SBOM)

## Files

| File | Format | Description |
|------|--------|-------------|
| `SAP-OSS-SBOM-Comprehensive.tex` | LaTeX | **Main PDF** - full technical detail + modifications history |
| `MODIFICATIONS-HISTORY.tex` | LaTeX | Git commit history and change documentation |
| `SAP-OSS-SBOM-Detailed.tex` | LaTeX | Service summary PDF (584 lines) |
| `SAP-OSS-SBOM-Complete.tex` | LaTeX | Overview PDF document |
| `service-inventory.json` | JSON | **Machine-readable** architecture (688 lines) |
| `sbom-cyclonedx.json` | CycloneDX 1.6 JSON | Summary SBOM (22 components) |
| `sbom-cyclonedx-full.json` | CycloneDX 1.6 JSON | Full SBOM (549+ npm packages) |
| `compile-sbom.sh` | Bash | PDF compilation script |
| `generate-full-sbom.sh` | Bash | Full SBOM generator |
| `generate-latex-from-json.sh` | Bash | Regenerate LaTeX from JSON |

## Generate PDF

### Option 1: Local LaTeX (Recommended)

```bash
# Install MacTeX on macOS
brew install --cask mactex

# Generate PDF
./compile-sbom.sh
```

### Option 2: Docker (No local install)

```bash
# Requires Docker to be running
./compile-sbom.sh --docker
```

### Option 3: Online LaTeX Editor

1. Go to [Overleaf](https://www.overleaf.com) or [Papeeria](https://papeeria.com)
2. Upload `SAP-OSS-SBOM-Complete.tex`
3. Click "Recompile" to generate PDF
4. Download the PDF

### Option 4: GitHub Actions (CI/CD)

Add to `.github/workflows/sbom.yml`:

```yaml
name: Generate SBOM PDF
on:
  push:
    paths: ['docs/sbom/**']

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: xu-cheng/latex-action@v3
        with:
          root_file: docs/sbom/SAP-OSS-SBOM-Complete.tex
      - uses: actions/upload-artifact@v4
        with:
          name: SBOM-PDF
          path: docs/sbom/*.pdf
```

## SBOM Content Overview

The SBOM covers **13 services** across the SAP AI Platform:

| Service | Language | Primary License |
|---------|----------|----------------|
| ai-core-streaming | Zig | Apache-2.0 |
| ai-core-pal | Zig/Mojo | Apache-2.0 |
| vllm-main | Python/Zig | Apache-2.0 |
| generative-ai-toolkit | Python | Apache-2.0 |
| mangle-query-service | Go | Apache-2.0 |
| cap-llm-plugin | TypeScript | Apache-2.0 |
| ai-sdk-js | TypeScript | Apache-2.0 |
| elasticsearch-main | Java | Elastic License 2.0 |
| langchain-integration | Python | Apache-2.0 |
| odata-vocabularies | Python | Apache-2.0 |
| ui5-webcomponents-ngx | TypeScript | Apache-2.0 |
| world-monitor | Python | MIT |
| data-cleaning-copilot | Python | Apache-2.0 |

## Compliance

- ✅ **NTIA Minimum Elements**: Complete
- ✅ **CycloneDX 1.6**: Valid schema
- ✅ **SPDX 2.3**: Valid license expressions
- ✅ **REUSE 3.2**: Compliant

## Verification Commands

```bash
# Validate CycloneDX format
cyclonedx validate --input-file sbom-cyclonedx.json

# Check REUSE compliance
cd /path/to/sap-oss && reuse lint

# Scan for vulnerabilities
snyk test --all-projects --json > vulnerability-report.json
```

## Document Information

| Field | Value |
|-------|-------|
| Document ID | SBOM-SAP-AI-2026-001 |
| Version | 1.0 |
| Generated | March 1, 2026 |
| Classification | Internal |