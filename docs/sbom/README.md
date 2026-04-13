# SAP OSS System - Software Bill of Materials

## Main artifact

| File | Format | Description |
|------|--------|-------------|
| `SAP-OSS-SBOM-Complete.tex` | LaTeX | Main single-column SBOM organized by the four system domains |
| `SAP-AI-Platform-SBOM-2026.pdf` | PDF | Exported PDF generated from `SAP-OSS-SBOM-Complete.tex` |
| `compile-sbom.sh` | Bash | Local PDF export script |

## Current structure

The SBOM is now organized around the four main parts of the system instead of the older service-by-service layout:

1. `intelligence`
2. `data`
3. `generativeUI`
4. `training`

Within each domain, the document treats each foldered software unit as an isolated software product and records:

- primary manifests;
- direct library declarations;
- internal libraries, apps, packages, or sidecars;
- codebase topology, entrypoints, and key implementation files;
- per-unit folder inventory and dominant source files;
- selected source-file catalog with file paths and LOC;
- build and deployment evidence.

The current document covers 13 isolated software units and 61 manifest/build artifacts across the four domains.

## Generate PDF

### Local LaTeX

```bash
cd docs/sbom
./compile-sbom.sh
```

The script uses `pdflatex` when available and falls back to `tectonic` if it is installed locally.

### Docker

```bash
cd docs/sbom
./compile-sbom.sh --docker
```

## Output

Successful compilation writes:

```bash
docs/sbom/SAP-AI-Platform-SBOM-2026.pdf
```

## Scope notes

- The LaTeX document is intentionally direct-dependency focused.
- Lockfiles are treated as supporting evidence, not the main reporting format.
- Folders without a local dependency manifest are still documented, but are marked as import-inferred or code-only software units.
