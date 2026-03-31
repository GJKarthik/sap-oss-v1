# SBOM & Lineage Document — Audit Report

**Document audited:** `docs/sbom-lineage.tex` (Software Bill of Materials and Change Lineage)  
**Service used for audit:** **Data Cleaning Copilot** (`training-console`)  
**Date:** 2026-02-28

---

## 1. Audit question: Does the document capture what the software is?

**Yes.**

For **Data Cleaning Copilot** the document includes:

| Audit need | Where it appears |
|------------|------------------|
| **What the software is** | Lineage section: *"What it is: This is a tool that takes in database schema and meta data describing that schema (e.g. description of the data in the tables, how the elements in the tables are connected, how the data is used) and helps users to formulate queries that can find errors or inconsistencies in the data."* (Sourced from `pyproject.toml` description.) |
| **Where it lives in the repo** | Path: `training-console`. |
| **What it depends on (SBOM)** | SBOM section: full table of direct dependencies (e.g. aioboto3, boto3, gradio, langchain, pandas, sqlalchemy, …) with **Package**, **Version**, and **Type** (runtime/dev/build). |

**Gap:** The project does not declare a **license** in `pyproject.toml`, so the document shows "—" for license. For audit, consider adding a `license` field to the project or to the SBOM-lineage manifest so the document can state the license explicitly.

---

## 2. Audit question: Does the document capture all changes made to the software?

**Yes**, with the following clarification.

- **Commits listed:** The lineage section lists every commit that modified the service path (`training-console`), as produced by:
  ```bash
  git log --follow -- training-console
  ```
- **Verification:** Running that command in the repo yields exactly **3 commits**, and all 3 appear in the document:

  | Hash (short) | Date | Author | Subject |
  |--------------|------|--------|---------|
  | 9b8071156c1a | 2026-02-26 09:31:42 +0800 | plturrell | Phase 1 & 2: OData Vocabularies Universal Dictionary enhancements |
  | 2903724fb841 | 2026-02-26 02:55:18 +0800 | plturrell | feat: add Angular UI5 frontend and FastAPI backend for data-cleaning-copilot |
  | 0b20d62146fa | 2026-02-26 02:02:05 +0800 | plturrell | Initial commit for fresh sap-oss repo |

- **Authoritative full list:** The document states: *"Full history: `git log --follow -- training-console`"*. An auditor can run this command to reproduce the **complete** list of changes for this service. If the generator caps the number of commits shown in the table (e.g. 50), the "Full history" command still defines the full audit trail.

**Note:** Commit subjects are the only change description in the document. For file-level or diff-level audit, use:
- `git log -p --follow -- training-console` (log with patches), or  
- `git show <hash> --stat` (files changed per commit).

---

## 3. Summary

| Criterion | Result |
|-----------|--------|
| Captures **what the software is** (description, path, dependencies) | **Yes** |
| Captures **all changes** to the service (via listed commits + “Full history” command) | **Yes** |
| License explicitly stated | **No** (project does not declare license; document shows "—") |

**Conclusion:** For **Data Cleaning Copilot**, the generated SBOM and lineage document is suitable for audit: it identifies the software, its dependencies, and all commits that modified it, and it points to the exact git command for the full change history. Recommended improvement: add license (in project or manifest) so the document can state it.
