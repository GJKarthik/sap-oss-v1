#!/usr/bin/env python3
"""
Build CycloneDX 1.5 SBOMs per project from the manifest.
- Node (npm/pnpm/yarn): runs @cyclonedx/cdxgen to produce full BOM (transitive deps, purl, etc.).
- Python: produces CycloneDX 1.5 JSON from pyproject.toml (direct deps; optional cyclonedx-python-lib for more).

Usage: python build_cyclonedx.py [--repo REPO] [--manifest PATH] [--out-dir DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "docs" / "sbom" / "sbom-lineage-manifest.yaml"
BOMS_DIR = REPO_ROOT / "scripts" / "sbom-lineage" / "boms"


def load_manifest(path: Path) -> list[dict]:
    if not path.exists():
        return []
    if yaml is None:
        raise RuntimeError("PyYAML required: pip install pyyaml")
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return data.get("services", [])


def slug(p: str) -> str:
    return p.replace("/", "-").strip()


# ── CycloneDX 1.5 shared metadata helpers ────────────────────────────────────

TOOL_METADATA = {
    "components": [
        {
            "type": "application",
            "bom-ref": "pkg:pypi/sap-oss-build-cyclonedx@1.0",
            "author": "SAP SE",
            "name": "build_cyclonedx.py",
            "version": "1.0",
            "description": "SAP OSS SBOM generator script",
        }
    ]
}

SAP_AUTHOR = {"name": "SAP SE", "url": "https://sap.com"}


def _bom_metadata(root_name: str, root_version: str, root_purl: str | None) -> dict:
    """Return a fully-populated metadata block that satisfies NTIA §3.6 and CycloneDX 1.5."""
    root: dict = {
        "type": "application",
        "bom-ref": "root-component",
        "name": root_name,
        "version": root_version,
    }
    if root_purl:
        root["purl"] = root_purl
    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tools": TOOL_METADATA,
        "authors": [SAP_AUTHOR],
        "lifecycles": [{"phase": "build"}],
        "component": root,
    }


def _make_bom(metadata: dict, components: list[dict], dependencies: list[dict]) -> dict:
    """Assemble a complete CycloneDX 1.5 BOM document."""
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": metadata,
        "components": components,
        "dependencies": dependencies,
    }


def _supplier_from_module(module: str) -> dict | None:
    """Infer a supplier object from a Go module path (github.com/foo → foo)."""
    parts = module.split("/")
    if len(parts) >= 2 and "." in parts[0]:
        org = parts[1] if len(parts) > 1 else parts[0]
        return {"name": org, "url": f"https://{parts[0]}/{org}"}
    return None


def _pypi_supplier(name: str) -> dict:
    return {"name": "PyPI community", "url": f"https://pypi.org/project/{name}/"}


# ── SPDX licence normalisation ────────────────────────────────────────────────

_KNOWN_SPDX_IDS = {
    "MIT", "MIT-0", "Apache-2.0", "Apache-1.1",
    "BSD-2-Clause", "BSD-3-Clause", "BSD-4-Clause",
    "ISC", "0BSD", "Unlicense",
    "MPL-2.0", "EPL-1.0", "EPL-2.0", "EUPL-1.2",
    "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later",
    "LGPL-2.0-only", "LGPL-2.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later",
    "LGPL-3.0-only", "LGPL-3.0-or-later",
    "AGPL-3.0-only", "AGPL-3.0-or-later",
    "CC0-1.0", "CC-BY-3.0", "CC-BY-4.0", "CC-BY-SA-4.0",
    "BlueOak-1.0.0", "PSF-2.0", "Python-2.0",
    "NOASSERTION",
}

_SPDX_PATTERNS: list[tuple[str, str]] = [
    ("mit license", "MIT"), ("the mit", "MIT"),
    ("apache software license", "Apache-2.0"),
    ("apache license, version 2", "Apache-2.0"),
    ("apache license 2", "Apache-2.0"),      # "Apache License 2.0"
    ("apache-2", "Apache-2.0"), ("apache 2", "Apache-2.0"),
    ("bsd 3-clause", "BSD-3-Clause"), ("3-clause bsd", "BSD-3-Clause"),
    ("bsd 2-clause", "BSD-2-Clause"), ("2-clause bsd", "BSD-2-Clause"),
    ("new bsd", "BSD-3-Clause"), ("simplified bsd", "BSD-2-Clause"),
    ("bsd license", "BSD-3-Clause"),
    ("isc license", "ISC"), ("isc", "ISC"),
    ("mozilla public license 2", "MPL-2.0"), ("mpl-2", "MPL-2.0"),
    ("mpl 2", "MPL-2.0"),
    ("lgpl-2.1", "LGPL-2.1-or-later"),
    ("gnu lesser general public", "LGPL-2.1-or-later"),
    ("lesser general public license", "LGPL-2.1-or-later"),  # "GNU Library or Lesser…"
    ("library general public", "LGPL-2.0-or-later"),
    ("gnu general public license v3", "GPL-3.0-or-later"),
    ("gnu general public license v2", "GPL-2.0-or-later"),
    ("psf", "PSF-2.0"), ("python software foundation", "PSF-2.0"),
    ("cc0", "CC0-1.0"), ("unlicense", "Unlicense"), ("0bsd", "0BSD"),
    ("blueoak", "BlueOak-1.0.0"),
    ("public domain", "CC0-1.0"),
    ("mit/x11", "MIT"), ("x11", "MIT"),   # MIT/X11 variant
    ("freebsd", "BSD-2-Clause"),
    # Plain "BSD" with no qualifier → assume BSD-3-Clause (most common)
    ("bsd", "BSD-3-Clause"),
]

# Free-form licence strings that are proprietary / non-SPDX.
# We map them to LicenseRef-* identifiers (valid CycloneDX extension mechanism).
_PROPRIETARY_LICENSE_MAP: dict[str, str] = {
    "sap developer license agreement": "LicenseRef-SAP-DeveloperAgreement",
    "see license in license": "LicenseRef-SeeFile",
    "see license in license.md": "LicenseRef-SeeFile",
    "see license in license file": "LicenseRef-SeeFile",
    "see license in licence": "LicenseRef-SeeFile",
    "see license file": "LicenseRef-SeeFile",   # "See LICENSE file" (no "IN")
    "see the license file": "LicenseRef-SeeFile",
    "intel end user license agreement": "LicenseRef-Intel-EULA",
    "commercial": "LicenseRef-Commercial",
    "proprietary": "LicenseRef-Proprietary",
}


def _normalize_spdx(raw: str) -> str:
    """Map a free-form license string to the closest SPDX / LicenseRef-* identifier."""
    if not raw:
        return ""
    stripped = raw.strip()
    if stripped in _KNOWN_SPDX_IDS:
        return stripped
    low = stripped.lower()
    # Check proprietary map first (exact, case-insensitive)
    for key, ref in _PROPRIETARY_LICENSE_MAP.items():
        if key in low:
            return ref
    for pattern, spdx in _SPDX_PATTERNS:
        if pattern in low:
            return spdx
    return stripped  # return as-is; audit will flag truly unknown IDs


# ── PyPI JSON API enrichment ──────────────────────────────────────────────────

_PYPI_CACHE: dict[str, dict] = {}


def _fetch_pypi_meta(name: str, version: str) -> dict:
    """
    Fetch licence SPDX ID, SHA-256 hash, and author from PyPI JSON API.
    Returns {"license_id": str, "sha256": str, "author": str}.
    Fails silently (returns empty strings) on any error.
    """
    cache_key = f"{name}@{version}"
    if cache_key in _PYPI_CACHE:
        return _PYPI_CACHE[cache_key]

    result: dict = {"license_id": "", "sha256": "", "author": ""}
    norm = re.sub(r"[-_.]+", "-", name).lower()

    for url in (
        f"https://pypi.org/pypi/{norm}/{version}/json",
        f"https://pypi.org/pypi/{norm}/json",
    ):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "SAP-OSS-SBOM/1.0"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                data = json.loads(resp.read())
            info = data.get("info", {})

            # SHA-256 and author — take from first successful response
            if not result["sha256"]:
                for f in data.get("urls") or []:
                    sha = f.get("digests", {}).get("sha256", "")
                    if sha:
                        result["sha256"] = sha
                        break
            if not result["author"]:
                author = info.get("author", "") or info.get("author_email", "")
                result["author"] = str(author).split(",")[0].split("<")[0].strip()

            # Licence — priority order (most-authoritative first):
            #   1. license_expression (PEP 639 SPDX expression, already valid)
            #   2. OSI / License classifiers (short, authoritative labels)
            #   3. license field ONLY if short (<= 100 chars, i.e. a label not full text)
            lic_expr = (info.get("license_expression") or "").strip()
            lic = ""

            if lic_expr:
                # Compound expression like "BSD-3-Clause AND MIT AND CC0-1.0"
                if " AND " in lic_expr or " OR " in lic_expr:
                    # Store as CycloneDX expression; also record the primary ID
                    result["license_expression"] = lic_expr
                    # Primary = first token before any operator
                    primary = re.split(r"\s+(?:AND|OR)\s+", lic_expr)[0].strip("()")
                    lic = primary
                else:
                    lic = lic_expr

            if not lic:
                for cl in info.get("classifiers", []):
                    if " :: License ::" in cl or "License :: OSI" in cl:
                        parts = [p.strip() for p in cl.split("::")]
                        if len(parts) >= 3:
                            lic = parts[-1]
                            break
            if not lic:
                raw_lic = (info.get("license") or "").strip()
                if raw_lic:
                    low_lic = raw_lic.lower()
                    # Short string → treat as SPDX label directly
                    # Long string → only accept if it starts with a known name
                    _KNOWN_PREFIXES = (
                        "mit license", "mit ", "apache license", "apache software",
                        "bsd ", "bsd-", "isc license", "mpl-", "lgpl-", "gpl-",
                        "mozilla public license", "gnu ", "cc0", "unlicense",
                    )
                    if len(raw_lic) <= 100 or any(low_lic.startswith(p) for p in _KNOWN_PREFIXES):
                        lic = raw_lic
            if lic:
                result["license_id"] = _normalize_spdx(lic)
                break   # licence found — no need to try unversioned fallback
        except Exception:
            continue

    _PYPI_CACHE[cache_key] = result
    return result


# ── Go module licence table ───────────────────────────────────────────────────
# Sorted longest-prefix-first for greedy matching.

GO_LICENSE_TABLE: list[tuple[str, str]] = sorted([
    # google.golang.org — most are Apache-2.0, specific packages differ
    ("google.golang.org/grpc", "Apache-2.0"),
    ("google.golang.org/protobuf", "BSD-3-Clause"),
    ("google.golang.org/api", "BSD-3-Clause"),
    ("google.golang.org/", "Apache-2.0"),
    # golang.org/x/* — all BSD-3-Clause (Go extended standard library)
    ("golang.org/x/", "BSD-3-Clause"),
    # github.com/google/*
    ("github.com/google/go-cmp", "BSD-3-Clause"),
    ("github.com/google/", "Apache-2.0"),
    # github.com/golang/* — mostly BSD-3-Clause but glog is Apache-2.0
    ("github.com/golang/glog", "Apache-2.0"),
    ("github.com/golang/", "BSD-3-Clause"),
    # antlr, stretchr, chzyer, uber
    ("github.com/antlr4-go/", "BSD-3-Clause"),
    ("github.com/stretchr/testify", "MIT"),
    ("github.com/stretchr/", "MIT"),
    ("github.com/chzyer/", "MIT"),
    ("go.uber.org/", "MIT"),
    # others
    ("bitbucket.org/creachadair/", "BSD-3-Clause"),
    ("github.com/elastic/", "Apache-2.0"),
    ("github.com/pkg/errors", "BSD-2-Clause"),
    ("github.com/davecgh/", "ISC"),
    ("github.com/pmezard/", "BSD-2-Clause"),
    ("github.com/cespare/", "MIT"),
    ("github.com/go-logr/", "Apache-2.0"),
    ("go.opentelemetry.io/", "Apache-2.0"),
], key=lambda x: -len(x[0]))


def _go_license(module: str) -> str:
    """Return an SPDX licence ID for a known Go module, or empty string."""
    for prefix, spdx in GO_LICENSE_TABLE:
        if module.startswith(prefix):
            return spdx
    return ""


# ── npm registry enrichment ───────────────────────────────────────────────────

_NPM_CACHE: dict[str, dict] = {}


def _fetch_npm_meta(pkg_name: str, version: str = "") -> dict:
    """
    Fetch licence SPDX ID and author/publisher from the npm registry.
    Returns {"license_id": str, "author": str}.
    Fails silently on any error.
    Tries /latest first, then versioned endpoint if author is missing.
    """
    cache_key = f"{pkg_name}@{version}" if version else pkg_name
    if cache_key in _NPM_CACHE:
        return _NPM_CACHE[cache_key]

    result: dict = {"license_id": "", "author": ""}
    encoded = urllib.parse.quote(pkg_name, safe="@/")
    urls_to_try = [f"https://registry.npmjs.org/{encoded}/latest"]
    if version:
        urls_to_try.append(f"https://registry.npmjs.org/{encoded}/{version}")

    for url in urls_to_try:
        try:
            req = urllib.request.Request(
                url, headers={"Accept": "application/json", "User-Agent": "SAP-OSS-SBOM/1.0"}
            )
            with urllib.request.urlopen(req, timeout=8) as resp:
                d = json.loads(resp.read())

            lic = d.get("license", "")
            if isinstance(lic, dict):
                lic = lic.get("type", "")
            if lic and not result["license_id"]:
                result["license_id"] = _normalize_spdx(str(lic).strip())

            author = d.get("author", {})
            if isinstance(author, dict):
                author = author.get("name", "")
            author_str = str(author).strip() if author else ""
            # Fallback: use first maintainer when author field is absent
            if not author_str:
                maintainers = d.get("maintainers", [])
                if maintainers and isinstance(maintainers[0], dict):
                    author_str = maintainers[0].get("name", "") or maintainers[0].get("email", "")
            if author_str and not result["author"]:
                result["author"] = author_str

            # Both found — no need to try versioned endpoint
            if result["license_id"] and result["author"]:
                break
        except Exception:
            continue

    _NPM_CACHE[cache_key] = result
    return result


# ── Java/Gradle version detection ─────────────────────────────────────────────

def _detect_java_version(project_path: Path) -> str:
    """
    Try to read the project version from Gradle/Maven descriptor files.
    Checks in order: version.properties, gradle.properties, pom.xml.
    """
    candidates = [
        project_path / "build-tools-internal" / "version.properties",
        project_path / "gradle.properties",
        project_path / "version.properties",
        project_path / "version.txt",
    ]
    for fp in candidates:
        if not fp.exists():
            continue
        for line in fp.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"^\s*(?:elasticsearch|version)\s*=\s*([0-9][0-9a-zA-Z._-]*)", line, re.IGNORECASE)
            if m:
                return m.group(1).strip()
    # pom.xml fallback
    pom = project_path / "pom.xml"
    if pom.exists():
        m = re.search(r"<version>([^<]+)</version>", pom.read_text(encoding="utf-8"), re.MULTILINE)
        if m:
            return m.group(1).strip()
    return "0.0.0"


# ── CycloneDX 1.5 shared metadata helpers ────────────────────────────────────

def _parse_pyproject_deps(project_path: Path) -> list[tuple[str, str]]:
    """
    Parse direct dependencies from pyproject.toml.
    Supports both PEP-621 [project].dependencies and Poetry [tool.poetry.dependencies].
    """
    out: list[tuple[str, str]] = []
    pyproject = project_path / "pyproject.toml"
    if not pyproject.exists():
        return out
    try:
        content = pyproject.read_text(encoding="utf-8")
    except OSError:
        return out

    # ── PEP-621 format: [project] / dependencies = [ "foo>=1.0", ... ] ──────
    in_project = False
    in_deps = False
    depth = 0
    for line in content.splitlines():
        s = line.strip()
        # Track which TOML section we're in
        if re.match(r"^\[", s):
            in_project = (s == "[project]")
            in_deps = False
        if in_project and re.match(r"^dependencies\s*=", s):
            in_deps = True
            depth = s.count("[") - s.count("]")
        if in_deps:
            if not re.match(r"^dependencies\s*=", s):
                depth += s.count("[") - s.count("]")
            for m in re.finditer(r'["\']([^"\']+)["\']', s):
                spec = m.group(1).strip()
                # Skip TOML file references like "requirements.txt"
                if spec.endswith(".txt") or spec.endswith(".cfg"):
                    continue
                base = re.sub(r"\[.*?\]", "", spec)  # strip extras
                nv = re.match(r"^([a-zA-Z0-9_.-]+)\s*(.*?)$", base.strip())
                if nv and nv.group(1).lower() not in ("python",):
                    name = nv.group(1)
                    ver = re.sub(r"[^0-9.*+><!=~^]", "", nv.group(2)).strip() or "*"
                    out.append((name, ver))
            if depth <= 0:
                in_deps = False

    # ── Poetry format: [tool.poetry.dependencies] / foo = "^1.0" ────────────
    in_poetry = False
    for line in content.splitlines():
        s = line.strip()
        if s == "[tool.poetry.dependencies]":
            in_poetry = True
            continue
        if in_poetry and re.match(r"^\[", s):
            break  # left the section
        if in_poetry and s and not s.startswith("#"):
            m = re.match(r'^([a-zA-Z0-9_.-]+)\s*=\s*(.+)$', s)
            if m:
                name = m.group(1).strip()
                if name.lower() in ("python", "python-dotenv"):
                    continue
                raw_ver = m.group(2).strip().strip('"\'')
                # Handle table form: {version = "^1.0", ...}
                tbl = re.search(r'version\s*=\s*["\']([^"\']+)["\']', raw_ver)
                ver = tbl.group(1) if tbl else raw_ver.split(",")[0].strip()
                # Skip if it's a path/git reference
                if not any(kw in raw_ver for kw in ("path", "git", "url", "develop")):
                    out.append((name, ver))

    # Deduplicate by name (keep first occurrence)
    seen: set[str] = set()
    deduped: list[tuple[str, str]] = []
    for name, ver in out:
        if name not in seen:
            seen.add(name)
            deduped.append((name, ver))
    return deduped


def _resolve_python_versions(project_path: Path, deps: list[tuple[str, str]]) -> dict[str, str]:
    """
    Try to resolve version specifiers to pinned versions by reading lock files.
    Returns {name: resolved_version}.  Falls back to the specifier if not found.

    Sources tried in order:
      1. poetry.lock  (Poetry)
      2. requirements.txt / requirements/*.txt  (pip)
    """
    resolved: dict[str, str] = {}

    # ── poetry.lock ──────────────────────────────────────────────────────────
    lock = project_path / "poetry.lock"
    if lock.exists():
        content = lock.read_text(encoding="utf-8", errors="replace")
        # Each package block: [[package]] / name = "foo" / version = "1.2.3"
        for block in re.split(r"\[\[package\]\]", content):
            nm = re.search(r'^name\s*=\s*"([^"]+)"', block, re.MULTILINE)
            vr = re.search(r'^version\s*=\s*"([^"]+)"', block, re.MULTILINE)
            if nm and vr:
                resolved[nm.group(1).lower().replace("-", "_")] = vr.group(1)

    # ── requirements.txt files (including requirements/common.txt, etc.) ─────
    req_files = list(project_path.glob("requirements*.txt"))
    req_dir = project_path / "requirements"
    if req_dir.is_dir():
        # Prefer common.txt / base.txt for projects using dynamic pyproject deps
        for priority in ("common.txt", "base.txt", "main.txt"):
            p = req_dir / priority
            if p.exists() and p not in req_files:
                req_files.insert(0, p)
        for f in req_dir.glob("*.txt"):
            if f not in req_files:
                req_files.append(f)
    for req_file in req_files:
        for line in req_file.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("-"):
                continue
            # Strip inline comments
            line = re.sub(r"\s*#.*$", "", line).strip()
            # Prefer pinned == versions; also accept >= as a lower-bound hint
            m_pin  = re.match(r"^([a-zA-Z0-9_.-]+(?:\[[^\]]*\])?)==([^\s;,]+)", line)
            m_ge   = re.match(r"^([a-zA-Z0-9_.-]+(?:\[[^\]]*\])?)[>~]=([^\s;,]+)", line)
            # Plain package name (no version constraint) — record with empty version
            m_bare = re.match(r"^([a-zA-Z0-9_.-]+(?:\[[^\]]*\])?)$", line)
            m = m_pin or m_ge or m_bare
            if m:
                raw_name = re.sub(r"\[.*?\]", "", m.group(1))  # strip extras
                key = raw_name.lower().replace("-", "_")
                ver = m.group(2) if len(m.groups()) >= 2 else ""
                if key not in resolved:
                    resolved[key] = ver

    return resolved


def _purl_pypi(name: str, version: str) -> str:
    """Build a valid pypi purl with a concrete version (no ranges)."""
    ver = re.sub(r"[^0-9a-zA-Z._+\-]", "", version).strip() or "0"
    # Normalise name per PEP 503
    norm = re.sub(r"[-_.]+", "-", name).lower()
    return f"pkg:pypi/{norm}@{ver}"


def build_cyclonedx_python(
    project_path: Path,
    project_name: str,
    repo_root: Path,
    manifest_version: str = "",
) -> dict:
    """
    Build CycloneDX 1.5 BOM for a Python project.

    - Resolves versions from poetry.lock / requirements*.txt (NTIA §3.3).
    - Enriches each component with licence and SHA-256 hash via PyPI JSON API.
    - manifest_version overrides the detected root version when supplied.
    """
    raw_deps = _parse_pyproject_deps(project_path)

    # Fallback: projects with dynamic deps (e.g. vllm) use requirements/*.txt
    if not raw_deps:
        version_map = _resolve_python_versions(project_path, [])
        raw_deps = [(name.replace("_", "-"), ver) for name, ver in version_map.items()]
    else:
        version_map = _resolve_python_versions(project_path, raw_deps)

    # Root version: manifest override → pyproject.toml → fallback
    root_version = manifest_version or "0.0.0"
    if not manifest_version:
        try:
            content = (project_path / "pyproject.toml").read_text(encoding="utf-8")
            vm = re.search(r'^\s*version\s*=\s*["\']([^"\']+)["\']', content, re.MULTILINE)
            if vm:
                root_version = vm.group(1)
        except (OSError, AttributeError):
            pass

    root_purl = f"pkg:pypi/{re.sub(r'[-_.]+', '-', project_name).lower()}@{root_version}"

    components: list[dict] = []
    dep_refs: list[str] = []

    for pkg_name, spec_ver in raw_deps:
        key = pkg_name.lower().replace("-", "_")
        resolved = version_map.get(key) or version_map.get(pkg_name.lower()) or None
        if resolved:
            ver = resolved
        else:
            ver = re.sub(r"[^0-9.]", "", spec_ver).strip(".") or "0"

        purl = _purl_pypi(pkg_name, ver)
        pypi = _fetch_pypi_meta(pkg_name, ver)

        author = pypi.get("author", "")
        supplier = (
            {"name": author, "url": f"https://pypi.org/project/{pkg_name}/"}
            if author
            else _pypi_supplier(pkg_name)
        )

        comp: dict = {
            "type": "library",
            "bom-ref": purl,
            "name": pkg_name,
            "version": ver,
            "purl": purl,
            "supplier": supplier,
        }
        if pypi.get("license_expression"):
            # Compound SPDX expression — use CycloneDX expression key
            comp["licenses"] = [{"expression": pypi["license_expression"]}]
        elif pypi.get("license_id"):
            comp["licenses"] = [{"license": {"id": pypi["license_id"]}}]
        if pypi.get("sha256"):
            comp["hashes"] = [{"alg": "SHA-256", "content": pypi["sha256"]}]
        components.append(comp)
        dep_refs.append(purl)

    metadata = _bom_metadata(project_name, root_version, root_purl)
    dependencies = _make_full_dependencies("root-component", dep_refs)
    return _make_bom(metadata, components, dependencies)


def _make_full_dependencies(root_ref: str, dep_refs: list[str]) -> list[dict]:
    """
    Build a complete dependencies[] array where:
      - root depends on all direct dep_refs
      - every library also has its own entry with dependsOn:[]
    This ensures no component bom-ref is orphaned (NTIA §3.5 / CycloneDX §4.11).
    """
    result = [{"ref": root_ref, "dependsOn": dep_refs}]
    for ref in dep_refs:
        result.append({"ref": ref, "dependsOn": []})
    return result



# Scope-to-publisher map for npm scoped packages without an "author" in the registry.
_NPM_SCOPE_PUBLISHERS: dict[str, str] = {
    "@types": "Microsoft (DefinitelyTyped)",
    "@microsoft": "Microsoft Corporation",
    "@azure": "Microsoft Corporation",
    "@typescript-eslint": "TypeScript ESLint Contributors",
    "@eslint": "ESLint contributors",
    "@babel": "Babel Contributors",
    "@jest": "Meta Platforms, Inc.",
    "@esbuild": "Evan Wallace",
    "@google-cloud": "Google LLC",
    "@google": "Google LLC",
    "@angular": "Google LLC",
    "@aws-sdk": "Amazon Web Services",
    "@aws-crypto": "Amazon Web Services",
    "@smithy": "Amazon Web Services",
    "@actions": "GitHub, Inc.",
    "@octokit": "Octokit contributors",
    "@sap": "SAP SE",
    "@sap-ai-sdk": "SAP SE",
    "@sap-cloud-sdk": "SAP SE",
    "@opentelemetry": "OpenTelemetry authors",
    "@changesets": "Changesets contributors",
    "@nodelib": "nodelib authors",
    "@nx": "Nrwl, Inc.",
    "@nrwl": "Nrwl, Inc.",
    "@vitest": "Vitest contributors",
    "@rollup": "rollup contributors",
    "@tsconfig": "tsconfig contributors",
    "@orval": "orval contributors",
    "@manypkg": "Changesets contributors",
    "@apidevtools": "APIDevTools contributors",
    "@commander-js": "commander contributors",
    "@istanbuljs": "Istanbul contributors",
    "@sinonjs": "Sinon.JS contributors",
    "@langchain": "LangChain, Inc.",
    "@isaacs": "Isaac Z. Schlueter",
    "@pkgjs": "npm, Inc.",
    "@cspotcode": "cspotcode contributors",
    "@exodus": "Exodus contributors",
    "@gerrit0": "Gerrit Jansen van Rensburg",
    "@rtsao": "Ryan Tsao",
}


_CARGO_CACHE: dict[str, dict] = {}


def _fetch_cargo_meta(crate: str) -> dict:
    """Fetch licence and authors from crates.io JSON API. Fails silently."""
    if crate in _CARGO_CACHE:
        return _CARGO_CACHE[crate]
    result: dict = {"license_id": "", "author": ""}
    try:
        url = f"https://crates.io/api/v1/crates/{crate}"
        req = urllib.request.Request(
            url,
            headers={"Accept": "application/json", "User-Agent": "SAP-OSS-SBOM/1.0 (contact: sbom@sap.com)"},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            d = json.loads(resp.read())
        # The crates.io /crates/{name} endpoint does NOT include a top-level
        # 'license' field in the 'crate' object.  The licence lives in each
        # version record; use the newest (first) version.
        versions = d.get("versions", [])
        lic = (versions[0].get("license") or "") if versions else ""
        result["license_id"] = _normalize_spdx(lic)

        # Fetch owners from the dedicated owners endpoint.
        # Response: {"users": [{"login": "...", "name": "...", "kind": "user"}]}
        # We use the first owner's display name (or login as fallback).
        try:
            owners_url = f"https://crates.io/api/v1/crates/{crate}/owner_user"
            owners_req = urllib.request.Request(
                owners_url,
                headers={"Accept": "application/json",
                         "User-Agent": "SAP-OSS-SBOM/1.0 (contact: sbom@sap.com)"},
            )
            with urllib.request.urlopen(owners_req, timeout=8) as oresp:
                owners_data = json.loads(oresp.read())
            users = owners_data.get("users", [])
            if users:
                first = users[0]
                result["author"] = first.get("name") or first.get("login") or ""
        except Exception:
            pass  # owners endpoint is best-effort; licence is the critical field
    except Exception:
        pass
    _CARGO_CACHE[crate] = result
    return result


# Known supplier / licence for generic and Nix packages that crates.io won't cover
_GENERIC_PKG_TABLE: dict[str, tuple[str, str]] = {
    # Bare (Holepunch/Pear) runtime components
    "cmake-bare": ("Holepunch contributors", "Apache-2.0"),
    "cmake-fetch": ("Holepunch contributors", "Apache-2.0"),
    "bare_url": ("Holepunch contributors", "Apache-2.0"),
    "bare_os": ("Holepunch contributors", "Apache-2.0"),
    "bare_fs": ("Holepunch contributors", "Apache-2.0"),
    # Nix
    "nixpkgs": ("NixOS Foundation", "MIT"),
    "utils": ("NixOS contributors", "MIT"),
}

# Well-known Cargo crate authors (when crates.io API is insufficient)
_CARGO_KNOWN_AUTHORS: dict[str, str] = {
    "serde": "David Tolnay",
    "serde_json": "David Tolnay",
    "reqwest": "Sean McArthur",
    "tauri": "Tauri Programme",
    "keyring": "hwchen",
}


def _fix_cdxgen_bom(bom: dict) -> dict:
    """
    Post-process a cdxgen-generated BOM:
    1. Fix malformed purls (missing @version)
    2. Fix empty version fields
    3. Ensure every component bom-ref appears in dependencies[]
    4. Normalise existing licence IDs (raw strings from cdxgen)
    5. Enrich npm components missing licence or supplier via npm registry API
    6. Scope-based publisher inference for packages with no registry author
    """
    comps = bom.get("components", [])

    # Pass 1: structural fixes (purl, version)
    for c in comps:
        purl = c.get("purl", "")
        ver = str(c.get("version", "")).strip()
        if not ver:
            c["version"] = "0"
            ver = "0"
        if purl and "@" not in purl:
            new_purl = f"{purl}@{ver}"
            if c.get("bom-ref") == purl:
                c["bom-ref"] = new_purl
            c["purl"] = new_purl

    # Pass 2: normalise existing licence IDs (cdxgen may emit raw strings)
    for c in comps:
        new_lics = []
        for le in c.get("licenses", []):
            if le.get("expression"):
                new_lics.append(le)
                continue
            lid = le.get("license", {}).get("id", "")
            if lid:
                # Compound expression stored in the id field — move to expression key
                if " AND " in lid or " OR " in lid:
                    new_lics.append({"expression": lid})
                    continue
                normed = _normalize_spdx(lid)
                if normed != lid:
                    le["license"]["id"] = normed
            new_lics.append(le)
        if new_lics != c.get("licenses"):
            c["licenses"] = new_lics

    # Pass 2b: GitHub Actions licence + publisher
    _GH_ACTIONS_ORGS: dict[str, str] = {
        "actions": ("GitHub, Inc.", "MIT"),
        "github": ("GitHub, Inc.", "MIT"),
    }
    for c in comps:
        purl = c.get("purl", "")
        if not purl.startswith("pkg:github/"):
            continue
        # e.g. pkg:github/actions/checkout@v4 → org = "actions"
        path_part = purl[len("pkg:github/"):].split("@")[0]
        org = path_part.split("/")[0] if "/" in path_part else path_part
        org_info = _GH_ACTIONS_ORGS.get(org)
        if not c.get("licenses"):
            lid = org_info[1] if org_info else "NOASSERTION"
            c["licenses"] = [{"license": {"id": lid}}]
        if not any(c.get(k) for k in ("supplier", "author", "publisher", "manufacturer")):
            if org_info:
                c["supplier"] = {"name": org_info[0]}

    # Pass 2c: Known npm licence data corrections.
    # cdxgen (and some registry snapshots) occasionally report the wrong SPDX ID.
    # These corrections are based on the upstream project's LICENSE file.
    # Format: (package_name, version_prefix_or_None) -> correct_spdx_id
    _NPM_LICENCE_CORRECTIONS: dict[tuple[str, str | None], str] = {
        # ua-parser-js v0.x and v1.x are MIT-licensed.
        # v2.x introduced a dual MIT/AGPL model but that version is rarely deployed.
        # cdxgen sometimes mis-reads the npm registry and reports AGPL-3.0-or-later.
        ("ua-parser-js", "0."): "MIT",
        ("ua-parser-js", "1."): "MIT",
    }
    for c in comps:
        c_name = c.get("name", "")
        c_ver  = str(c.get("version", ""))
        for (pkg_name_key, ver_prefix), correct_lid in _NPM_LICENCE_CORRECTIONS.items():
            if c_name == pkg_name_key and (ver_prefix is None or c_ver.startswith(ver_prefix)):
                current_lics = c.get("licenses", [])
                current_lid  = current_lics[0].get("license", {}).get("id", "") if current_lics else ""
                if current_lid != correct_lid:
                    c["licenses"] = [{"license": {"id": correct_lid}}]
                    props = c.setdefault("properties", [])
                    props.append({
                        "name":  "sap:licence-correction",
                        "value": f"cdxgen reported '{current_lid}'; corrected to '{correct_lid}' "
                                 f"for {pkg_name_key} v{c_ver} based on upstream LICENSE file.",
                    })
                break

    # Pass 3: npm licence + supplier enrichment
    for c in comps:
        purl = c.get("purl", "")
        if not purl.startswith("pkg:npm/"):
            continue
        needs_lic = not c.get("licenses")
        needs_sup = not any(c.get(k) for k in ("supplier", "author", "publisher", "manufacturer"))
        if not (needs_lic or needs_sup):
            continue

        group = c.get("group", "")
        name = c.get("name", "")
        pkg_name = f"@{group}/{name}" if group and not group.startswith("@") else (
            f"{group}/{name}" if group else name
        )
        comp_ver = str(c.get("version", "")).strip()
        meta = _fetch_npm_meta(pkg_name, version=comp_ver)

        if needs_lic:
            if meta.get("license_id"):
                c["licenses"] = [{"license": {"id": meta["license_id"]}}]
            else:
                # Not on npm or no licence declared
                c["licenses"] = [{"license": {"id": "NOASSERTION"}}]
        if needs_sup and meta.get("author"):
            c["supplier"] = {"name": meta["author"]}

    # Pass 4: scope-based + name-pattern publisher inference for still-missing suppliers
    for c in comps:
        purl = c.get("purl", "")
        if not purl.startswith("pkg:npm/") and not purl.startswith("pkg:github/"):
            continue
        if any(c.get(k) for k in ("supplier", "author", "publisher", "manufacturer")):
            continue
        group = c.get("group", "")
        name_c = c.get("name", "")
        scope = f"@{group}" if group and not group.startswith("@") else group
        if scope in _NPM_SCOPE_PUBLISHERS:
            c["supplier"] = {"name": _NPM_SCOPE_PUBLISHERS[scope]}
        else:
            combined = (group + name_c).lower()
            _SAP_NAME_PREFIXES = ("odata-", "ui5-", "sap-", "hana-")
            if "sap" in combined or any(name_c.lower().startswith(p) for p in _SAP_NAME_PREFIXES):
                c["supplier"] = {"name": "SAP SE"}

    # Pass 4b: Cargo crate licence + supplier enrichment
    for c in comps:
        purl = c.get("purl", "")
        if not purl.startswith("pkg:cargo/"):
            continue
        has_lic = bool(c.get("licenses"))
        has_sup = any(c.get(k) for k in ("supplier", "author", "publisher", "manufacturer"))
        crate_name = c.get("name", "")
        if not has_lic or not has_sup:
            meta = _fetch_cargo_meta(crate_name)
            if not has_lic:
                lid = meta.get("license_id") or "NOASSERTION"
                c["licenses"] = [{"license": {"id": lid}}]
            if not has_sup:
                author = _CARGO_KNOWN_AUTHORS.get(crate_name, meta.get("author", ""))
                if author:
                    c["supplier"] = {"name": author}

    # Pass 4c: generic and Nix package licence + supplier from static table
    for c in comps:
        purl = c.get("purl", "")
        if not (purl.startswith("pkg:generic/") or purl.startswith("pkg:nix/")):
            continue
        name_c = c.get("name", "")
        info = _GENERIC_PKG_TABLE.get(name_c)
        if not c.get("licenses"):
            lid = info[1] if info else "NOASSERTION"
            c["licenses"] = [{"license": {"id": lid}}]
        if not any(c.get(k) for k in ("supplier", "author", "publisher", "manufacturer")):
            if info:
                c["supplier"] = {"name": info[0]}

    # Pass 4d: migrate legacy publisher → supplier for any component still using
    # the non-standard publisher field (e.g. from older cdxgen output cached in BOMs).
    for c in comps:
        pub = c.pop("publisher", None)
        if pub and not c.get("supplier"):
            c["supplier"] = {"name": pub}

    # Pass 5: ensure all bom-refs are in dependencies[]
    existing_deps = bom.get("dependencies", [])
    existing_refs = {d.get("ref") for d in existing_deps}
    root_ref = (bom.get("metadata", {}).get("component") or {}).get("bom-ref", "")
    for c in comps:
        bref = c.get("bom-ref", "")
        if bref and bref not in existing_refs and bref != root_ref:
            existing_deps.append({"ref": bref, "dependsOn": []})
    bom["dependencies"] = existing_deps
    return bom


def build_cyclonedx_node(project_path: Path, repo_root: Path, out_dir: Path, path_str: str, package_manager: str) -> dict | None:
    """Run cdxgen to produce CycloneDX 1.5 BOM. Returns None on failure."""
    work_dir = repo_root / project_path
    if not work_dir.is_dir():
        return None
    # cdxgen writes relative to cwd; use a file inside project then move to out_dir
    local_bom = work_dir / "bom.cyclonedx.json"
    out_file = out_dir / f"{slug(path_str)}.cyclonedx.json"
    try:
        r = subprocess.run(
            ["npx", "--yes", "@cyclonedx/cdxgen", "-o", str(local_bom), "--spec-version", "1.5"],
            cwd=str(work_dir),
            capture_output=True,
            text=True,
            timeout=300,
        )
        if local_bom.exists():
            with open(local_bom, encoding="utf-8") as f:
                bom = json.load(f)
            local_bom.unlink()
            # Post-process: fix malformed purls and orphaned bom-refs
            bom = _fix_cdxgen_bom(bom)
            out_dir.mkdir(parents=True, exist_ok=True)
            with open(out_file, "w", encoding="utf-8") as f:
                json.dump(bom, f, indent=2, ensure_ascii=False)
            return bom
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError, OSError):
        if local_bom.exists():
            try:
                local_bom.unlink()
            except OSError:
                pass
    return None


def _parse_go_mod(project_path: Path) -> list[tuple[str, str]]:
    """Parse require directives from go.mod, ignoring indirect deps and stdlib."""
    out: list[tuple[str, str]] = []
    gomod = project_path / "go.mod"
    if not gomod.exists():
        return out
    try:
        content = gomod.read_text(encoding="utf-8")
    except OSError:
        return out
    in_require = False
    for line in content.splitlines():
        s = line.strip()
        if s.startswith("require ("):
            in_require = True
            continue
        if in_require and s == ")":
            in_require = False
            continue
        # Single-line: require foo/bar v1.2.3
        single = re.match(r"^require\s+(\S+)\s+(\S+)", s)
        if single:
            name, ver = single.group(1), single.group(2)
            if "// indirect" not in s:
                out.append((name, ver))
            continue
        if in_require and s and not s.startswith("//"):
            m = re.match(r"^(\S+)\s+(\S+)", s)
            if m:
                name, ver = m.group(1), m.group(2)
                if "// indirect" not in s:
                    out.append((name, ver))
    return out


def _read_go_sum_hashes(project_path: Path) -> dict[str, str]:
    """
    Parse go.sum and return {module@version: sha256-hash}.
    go.sum lines look like:
      github.com/foo/bar v1.2.3 h1:<base64>=
      github.com/foo/bar v1.2.3/go.mod h1:<base64>=
    We keep only the module (non-go.mod) line hash.
    """
    hashes: dict[str, str] = {}
    gosum = project_path / "go.sum"
    if not gosum.exists():
        return hashes
    for line in gosum.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) == 3 and not parts[1].endswith("/go.mod"):
            module, version, h1 = parts
            clean_ver = version.lstrip("v")
            hashes[f"{module}@{clean_ver}"] = h1  # h1:xxx= format
    return hashes


def _go_module_version(project_path: Path) -> str:
    """Try to read the module version from go.mod or git tag."""
    gomod = project_path / "go.mod"
    if gomod.exists():
        for line in gomod.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^module\s+\S+\s+//\s+v(\S+)", line)
            if m:
                return m.group(1)
    try:
        result = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0"],
            cwd=str(project_path),
            capture_output=True, text=True, timeout=10,
        )
        tag = result.stdout.strip().lstrip("v")
        if tag:
            return tag
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return "0.0.0"


def _enrich_bom_components_pypi(bom: dict) -> dict:
    """
    Enrich a CycloneDX BOM in-place: add PyPI licence + sha256 for every
    component that looks like a Python package (no existing license and no hash).
    Returns the same dict for chaining.
    """
    for comp in bom.get("components", []):
        has_lic = bool(comp.get("licenses"))
        has_hash = bool(comp.get("hashes"))

        # Always normalise existing licence IDs (cdxgen may emit raw strings)
        if has_lic:
            for le in comp["licenses"]:
                if le.get("expression"):
                    # Compound expression: split on AND/OR and re-emit if it
                    # looks like a short compound of known identifiers
                    pass  # leave expression entries unchanged
                elif le.get("license", {}).get("id"):
                    raw_id = le["license"]["id"]
                    normed = _normalize_spdx(raw_id)
                    if normed != raw_id:
                        le["license"]["id"] = normed
                elif le.get("license", {}).get("name"):
                    # cdxgen sometimes puts the string in "name" not "id"
                    raw_name = le["license"]["name"]
                    normed = _normalize_spdx(raw_name)
                    if normed:
                        le["license"]["id"] = normed
                        del le["license"]["name"]

        # Handle compound SPDX expressions stored in the license field by cdxgen
        # e.g. {"license": {"id": "MIT AND Python-2.0"}}
        if has_lic:
            new_lics = []
            for le in comp["licenses"]:
                if le.get("expression"):
                    new_lics.append(le)
                    continue
                lid = le.get("license", {}).get("id", "")
                if lid and (" AND " in lid or " OR " in lid):
                    # Convert inline compound to CycloneDX expression format
                    new_lics.append({"expression": lid})
                else:
                    new_lics.append(le)
            comp["licenses"] = new_lics

        if has_lic and has_hash:
            continue
        purl = comp.get("purl", "")
        name_c = comp.get("name", "")
        ver_c = comp.get("version", "")
        # Only enrich PyPI components
        if purl and not purl.startswith("pkg:pypi"):
            continue
        meta = _fetch_pypi_meta(name_c, ver_c)
        if not has_lic:
            if meta.get("license_expression"):
                comp["licenses"] = [{"expression": meta["license_expression"]}]
            elif meta.get("license_id"):
                comp["licenses"] = [{"license": {"id": meta["license_id"]}}]
            else:
                # Not on public PyPI or no licence declared — use NOASSERTION
                comp["licenses"] = [{"license": {"id": "NOASSERTION"}}]
        if not has_hash and meta.get("sha256"):
            comp["hashes"] = [{"alg": "SHA-256", "content": meta["sha256"]}]
        if meta.get("author") and not comp.get("author"):
            comp["author"] = meta["author"]
    return bom


def build_cyclonedx_go(
    project_path: Path,
    project_name: str,
    manifest_version: str = "",
) -> dict:
    """
    Build CycloneDX 1.5 BOM for a Go module.

    - Direct deps from go.mod (indirect excluded)
    - SHA-256 hashes from go.sum (supply-chain best practice)
    - Supplier inferred from module host
    - Licence from GO_LICENSE_TABLE (static, no network call needed)
    - manifest_version overrides detected root version when supplied
    """
    deps = _parse_go_mod(project_path)
    hashes = _read_go_sum_hashes(project_path)
    root_version = manifest_version or _go_module_version(project_path)

    # Infer Go module name from go.mod
    root_module = project_name
    gomod = project_path / "go.mod"
    if gomod.exists():
        for line in gomod.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^module\s+(\S+)", line)
            if m:
                root_module = m.group(1)
                break
    root_purl = f"pkg:golang/{root_module}@{root_version}"

    components: list[dict] = []
    dep_refs: list[str] = []

    for module, version in deps:
        clean_ver = version.lstrip("v")
        purl = f"pkg:golang/{module}@{clean_ver}"
        comp: dict = {
            "type": "library",
            "bom-ref": purl,
            "name": module,
            "version": clean_ver,
            "purl": purl,
        }
        supplier = _supplier_from_module(module)
        if supplier:
            comp["supplier"] = supplier
        lic = _go_license(module)
        if lic:
            comp["licenses"] = [{"license": {"id": lic}}]
        h1 = hashes.get(f"{module}@{clean_ver}")
        if h1:
            comp["hashes"] = [{"alg": "SHA-256", "content": h1}]
        components.append(comp)
        dep_refs.append(purl)

    metadata = _bom_metadata(project_name, root_version, root_purl)
    dependencies = _make_full_dependencies("root-component", dep_refs)
    return _make_bom(metadata, components, dependencies)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build CycloneDX SBOMs per project")
    parser.add_argument("--repo", type=Path, default=REPO_ROOT)
    parser.add_argument("--manifest", type=Path, default=MANIFEST_PATH)
    parser.add_argument("--out-dir", type=Path, default=BOMS_DIR)
    args = parser.parse_args()
    repo_root = args.repo.resolve()
    manifest = load_manifest(args.manifest)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for svc in manifest:
        path_str = svc.get("path") or ""
        name = svc.get("name") or path_str
        pm = (svc.get("package_manager") or "npm").lower()
        manifest_version: str = svc.get("version") or ""
        project_path = repo_root / path_str
        if not project_path.is_dir():
            print(f"Skip (not a dir): {path_str}")
            continue
        bom = None
        out_path = args.out_dir / f"{slug(path_str)}.cyclonedx.json"
        if pm == "python":
            bom = build_cyclonedx_python(project_path, name, repo_root,
                                         manifest_version=manifest_version)
            # If an existing BOM on disk has more components (e.g. cdxgen full
            # transitive graph), preserve those components and only enrich
            # licenses + update root metadata.
            if out_path.exists():
                try:
                    existing = json.loads(out_path.read_text(encoding="utf-8"))
                    fresh_count = len(bom.get("components", [])) if bom else 0
                    existing_count = len(existing.get("components", []))
                    if existing_count > fresh_count:
                        # Keep the richer component list; update root metadata
                        existing["metadata"] = bom["metadata"] if bom else existing["metadata"]
                        _enrich_bom_components_pypi(existing)
                        bom = existing
                        print(f"Enriched existing BOM ({existing_count} comps) for {path_str}")
                except Exception:
                    pass  # fall through to write fresh BOM
            if bom:
                with open(out_path, "w", encoding="utf-8") as f:
                    json.dump(bom, f, indent=2, ensure_ascii=False)
                print(f"Wrote {out_path}")
        elif pm == "go":
            bom = build_cyclonedx_go(project_path, name,
                                     manifest_version=manifest_version)
            if bom:
                with open(out_path, "w", encoding="utf-8") as f:
                    json.dump(bom, f, indent=2, ensure_ascii=False)
                print(f"Wrote {out_path}")
        elif pm in ("java", "zig"):
            # Emit a compliant stub BOM; auto-detect version from descriptor files.
            detected = _detect_java_version(project_path) if pm == "java" else "0.0.0"
            root_version = manifest_version or detected
            norm_name = re.sub(r"[-_.]+", "-", name).lower()
            root_purl = f"pkg:generic/{norm_name}@{root_version}"
            metadata = _bom_metadata(name, root_version, root_purl)
            metadata["properties"] = [
                {
                    "name": "sap-oss:sbom-note",
                    "value": (
                        f"Stub BOM — full {pm.upper()} SBOM generation requires external tooling. "
                        f"For Java: run 'gradle cyclonedxBom'. "
                        f"For Zig: dependencies are vendored; update manually when zig.zon is introduced."
                    ),
                }
            ]
            bom = _make_bom(metadata, [], [{"ref": "root-component", "dependsOn": []}])
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(bom, f, indent=2, ensure_ascii=False)
            print(f"Wrote stub BOM for {path_str} ({pm}): {out_path}")
        else:
            bom = build_cyclonedx_node(project_path, repo_root, args.out_dir, path_str, pm)
            if bom:
                # Re-apply post-processor in case the existing on-disk BOM predates it
                bom = _fix_cdxgen_bom(bom)
                with open(out_path, "w", encoding="utf-8") as f:
                    json.dump(bom, f, indent=2, ensure_ascii=False)
                print(f"Wrote {out_path}")
        if not bom:
            print(f"No BOM for {path_str} ({pm})")


if __name__ == "__main__":
    main()
