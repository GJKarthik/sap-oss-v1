# SAP OSS System - Software Bill of Materials

## CycloneDX + git lineage (generated)

These files are produced from `scripts/sbom-lineage/boms/*.cyclonedx.json` and `scripts/sbom-lineage/lineage.json`:

| Output | Description |
|--------|-------------|
| `docs/sbom-lineage.tex` | Combined report (all services) |
| `docs/sbom/sbom-lineage.tex` | Copy of the combined report |
| `docs/sbom/sbom-<cyclonedx-stem>.tex` | One LaTeX file per entry in `sbom-lineage-manifest.yaml` |

Regenerate:

```bash
python3 scripts/sbom-lineage/collect_lineage.py
python3 scripts/sbom-lineage/generate_latex.py --output docs/sbom-lineage.tex
cp docs/sbom-lineage.tex docs/sbom/sbom-lineage.tex
python3 scripts/sbom-lineage/gen_per_service.py
```

---

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
