#!/usr/bin/env python3
"""
sbom_to_spdx.py — Convert CycloneDX 1.5 BOMs to SPDX 2.3 JSON format.

Produces OpenChain / Linux Foundation-compliant SPDX 2.3 JSON documents
from the CycloneDX BOMs in the boms/ directory.

Output files are written to boms/spdx/<name>.spdx.json

Usage:
  python3 scripts/sbom-lineage/sbom_to_spdx.py [--boms-dir DIR] [--out-dir DIR]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

BOMS_DIR_DEFAULT  = Path(__file__).parent / "boms"
SPDX_VERSION      = "SPDX-2.3"
SPDX_DATA_LICENSE = "CC0-1.0"
SPDX_NAMESPACE    = "https://spdx.org/spdxdocs/{name}-{serial}"

_NON_ALNUM = re.compile(r"[^A-Za-z0-9\-\.]")


def _spdx_id(raw: str) -> str:
    """Convert arbitrary string to a valid SPDX element identifier."""
    cleaned = _NON_ALNUM.sub("-", raw).strip("-")
    return f"SPDXRef-{cleaned[:200]}" if cleaned else "SPDXRef-unknown"


def _license_expression(comp: dict) -> str:
    """Extract an SPDX license expression string from a CycloneDX component."""
    lics = comp.get("licenses", [])
    parts: list[str] = []
    for le in lics:
        if le.get("expression"):
            parts.append(le["expression"])
        elif le.get("license", {}).get("id"):
            parts.append(le["license"]["id"])
        elif le.get("license", {}).get("name"):
            # Non-SPDX named license
            parts.append(f"LicenseRef-{_NON_ALNUM.sub('-', le['license']['name'])[:50]}")
    if not parts:
        return "NOASSERTION"
    return " AND ".join(f"({p})" if " " in p else p for p in parts)


def _supplier_org(comp: dict) -> str:
    for key in ("supplier", "manufacturer", "publisher", "author"):
        val = comp.get(key)
        if isinstance(val, dict):
            name = val.get("name", "")
        else:
            name = str(val) if val else ""
        if name:
            return f"Organization: {name}"
    return "NOASSERTION"


def _homepage(comp: dict) -> str:
    for key in ("externalReferences",):
        for ref in comp.get(key, []):
            if ref.get("type") in ("website", "vcs", "distribution"):
                url = ref.get("url", "")
                if url:
                    return url
    return "NOASSERTION"


def cdx_to_spdx(bom: dict, doc_name: str) -> dict:
    """Convert a single CycloneDX 1.5 BOM dict to an SPDX 2.3 JSON dict."""
    meta      = bom.get("metadata", {})
    root_comp = meta.get("component", {})
    comps     = bom.get("components", [])
    deps_map: dict[str, list[str]] = {
        d["ref"]: d.get("dependsOn", []) for d in bom.get("dependencies", []) if d.get("ref")
    }

    timestamp = meta.get("timestamp") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    serial    = bom.get("serialNumber", f"urn:uuid:{uuid.uuid4()}")
    ns_serial = serial.replace("urn:uuid:", "")

    # ── Document header ───────────────────────────────────────────────────────
    doc: dict = {
        "spdxVersion":       SPDX_VERSION,
        "dataLicense":       SPDX_DATA_LICENSE,
        "SPDXID":            "SPDXRef-DOCUMENT",
        "name":              doc_name,
        "documentNamespace": SPDX_NAMESPACE.format(name=doc_name, serial=ns_serial),
        "creationInfo": {
            "created":   timestamp,
            "creators":  [
                "Tool: SAP-OSS-SBOM-Pipeline-1.0",
                "Organization: SAP SE",
            ],
            "licenseListVersion": "3.24",
        },
        "packages":       [],
        "relationships":  [],
        "documentDescribes": [],
    }

    # ── Root package ──────────────────────────────────────────────────────────
    root_spdx_id = _spdx_id(root_comp.get("bom-ref") or root_comp.get("name") or "root")
    root_pkg: dict = {
        "SPDXID":               root_spdx_id,
        "name":                 root_comp.get("name", doc_name),
        "versionInfo":          str(root_comp.get("version", "NOASSERTION")),
        "downloadLocation":     "NOASSERTION",
        "filesAnalyzed":        False,
        "licenseConcluded":     _license_expression(root_comp),
        "licenseDeclared":      _license_expression(root_comp),
        "copyrightText":        "NOASSERTION",
        "supplier":             _supplier_org(root_comp),
    }
    if root_comp.get("purl"):
        root_pkg["externalRefs"] = [
            {"referenceCategory": "PACKAGE-MANAGER",
             "referenceType": "purl",
             "referenceLocator": root_comp["purl"]}
        ]
    doc["packages"].append(root_pkg)
    doc["documentDescribes"].append(root_spdx_id)
    doc["relationships"].append({
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": root_spdx_id,
    })

    # ── Component packages ────────────────────────────────────────────────────
    bom_ref_to_spdx: dict[str, str] = {
        (root_comp.get("bom-ref") or ""): root_spdx_id
    }
    for comp in comps:
        bom_ref  = comp.get("bom-ref", "")
        spdx_eid = _spdx_id(bom_ref or comp.get("name", str(uuid.uuid4())))
        bom_ref_to_spdx[bom_ref] = spdx_eid

        lic_expr = _license_expression(comp)
        pkg: dict = {
            "SPDXID":           spdx_eid,
            "name":             comp.get("name", "NOASSERTION"),
            "versionInfo":      str(comp.get("version", "")) or "NOASSERTION",
            "downloadLocation": _homepage(comp),
            "filesAnalyzed":    False,
            "licenseConcluded": lic_expr,
            "licenseDeclared":  lic_expr,
            "copyrightText":    "NOASSERTION",
            "supplier":         _supplier_org(comp),
        }
        if comp.get("description"):
            pkg["comment"] = comp["description"]
        if comp.get("purl"):
            pkg["externalRefs"] = [
                {"referenceCategory": "PACKAGE-MANAGER",
                 "referenceType": "purl",
                 "referenceLocator": comp["purl"]}
            ]
        # Checksums
        for h in comp.get("hashes", []):
            algo_raw = h.get("alg", "").upper().replace("-", "_")
            # SPDX checksum algorithm names: SHA1, SHA256, SHA512, MD5, etc.
            algo_map = {"SHA_256": "SHA256", "SHA_512": "SHA512", "SHA_1": "SHA1", "MD_5": "MD5"}
            algo = algo_map.get(algo_raw, algo_raw)
            pkg.setdefault("checksums", []).append({"algorithm": algo, "checksumValue": h.get("content", "")})
        doc["packages"].append(pkg)

    # ── Dependency relationships ──────────────────────────────────────────────
    for ref, dep_ons in deps_map.items():
        src_id = bom_ref_to_spdx.get(ref)
        if not src_id:
            continue
        for dep_ref in dep_ons:
            tgt_id = bom_ref_to_spdx.get(dep_ref)
            if tgt_id:
                doc["relationships"].append({
                    "spdxElementId":      src_id,
                    "relationshipType":   "DEPENDS_ON",
                    "relatedSpdxElement": tgt_id,
                })

    return doc


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert CycloneDX 1.5 BOMs to SPDX 2.3 JSON"
    )
    parser.add_argument("--boms-dir", type=Path, default=BOMS_DIR_DEFAULT)
    parser.add_argument("--out-dir",  type=Path, default=None,
                        help="Output directory (default: <boms-dir>/spdx/)")
    args = parser.parse_args()

    out_dir = args.out_dir or (args.boms_dir / "spdx")
    out_dir.mkdir(parents=True, exist_ok=True)

    bom_files = sorted(args.boms_dir.glob("*.cyclonedx.json"))
    if not bom_files:
        print(f"No BOMs found in {args.boms_dir}", file=sys.stderr)
        sys.exit(2)

    ok = err = 0
    for bf in bom_files:
        name = bf.stem.replace(".cyclonedx", "")
        try:
            bom   = json.loads(bf.read_text(encoding="utf-8"))
            spdx  = cdx_to_spdx(bom, name)
            out_p = out_dir / f"{name}.spdx.json"
            out_p.write_text(json.dumps(spdx, indent=2, ensure_ascii=False), encoding="utf-8")
            n_pkgs = len(spdx["packages"])
            n_rels = len(spdx["relationships"])
            print(f"  ✓  {name}  → {out_p.name}  ({n_pkgs} packages, {n_rels} relationships)")
            ok += 1
        except Exception as exc:
            print(f"  ✗  {name}: {exc}", file=sys.stderr)
            err += 1

    print(f"\nConverted {ok}/{ok+err} BOMs to SPDX 2.3 JSON in {out_dir}/")
    if err:
        sys.exit(1)


if __name__ == "__main__":
    main()

