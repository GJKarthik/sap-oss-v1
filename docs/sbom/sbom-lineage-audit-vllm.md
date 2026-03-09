# Audit: vLLM service in SBOM / Lineage document

This note confirms that the generated LaTeX document (`docs/sbom-lineage.tex`) captures what the software is and all changes made to it for **vLLM (inference engine)**, for audit purposes.

## 1. What the software is

The document includes:

- **Name:** vLLM (inference engine)
- **Path:** `vllm-main`
- **What it is:** *A high-throughput and memory-efficient inference and serving engine for LLMs* (from `vllm-main/pyproject.toml` description)
- **License:** Apache-2.0 (from `pyproject.toml`)
- **Upstream / original:** https://github.com/vllm-project/vllm (from `docs/sbom-lineage-manifest.yaml`)

So the document clearly identifies the component and its relationship to the original project.

## 2. Bill of materials (SBOM)

The SBOM section for vLLM lists direct build/runtime dependencies from `pyproject.toml`:

| Package        | Version           | Type  |
|----------------|-------------------|-------|
| cmake          | >=3.26.1          | build |
| grpcio-tools   | ==1.78.0          | build |
| jinja2         | (any)             | build |
| ninja          | (any)             | build |
| packaging      | >=24.2            | build |
| setuptools     | >=77.0.3,<81.0.0  | build |
| setuptools-scm | >=8.0             | build |
| torch          | == 2.10.0         | build |
| wheel          | (any)             | build |

Note: vLLM uses `dynamic = ["version", "dependencies", "optional-dependencies"]`, so full runtime dependencies are not listed in `pyproject.toml`; they are resolved at build time. The document reflects what is declared in the repo. For a full dependency tree, a lockfile or `pip freeze` could be added later.

## 3. All changes made to it (lineage)

The “Change Lineage” section for vLLM includes:

- **Audit note** at the start of the section: all commits that modified the service path are included (up to the configured max); full history is available via `git log --follow -- <path>` in the repo root.
- For **vllm-main**, the table of changes:

  | Hash          | Date                  | Author    | Subject |
  |---------------|-----------------------|-----------|--------|
  | 9b8071156c1a  | 2026-02-26 09:31:42   | plturrell | Phase 1 & 2: OData Vocabularies Universal Dictionary enhancements |
  | 0b20d62146fa  | 2026-02-26 02:02:05   | plturrell | Initial commit for fresh sap-oss repo |

- **Full history** command: `git log --follow -- vllm-main`

Verification:

```bash
git log --oneline --follow -- vllm-main
```

returns the same 2 commits. So the document lists every commit that touched `vllm-main` in this repository.

## 4. Conclusion

For the **vLLM** service, the generated document is suitable for audit in that it:

1. **Identifies the software:** name, path, description, license, and upstream.
2. **Lists declared dependencies:** build (and where present, runtime) from `pyproject.toml`.
3. **Records all changes:** every commit that modified `vllm-main` is in the lineage table, with hash, date, author, and subject, and the doc states how to obtain the full history with `git log --follow -- vllm-main`.

## 5. How to regenerate

From the repo root:

```bash
make sbom-lineage
```

To build the PDF:

```bash
make sbom-lineage-pdf
```

To increase the number of commits per service (e.g. for larger histories):

```bash
python scripts/sbom-lineage/collect_sbom_lineage.py --output scripts/sbom-lineage/sbom-lineage.json --git-max 500
python scripts/sbom-lineage/generate_latex.py --input scripts/sbom-lineage/sbom-lineage.json --output docs/sbom-lineage.tex --max-commits 200
```
