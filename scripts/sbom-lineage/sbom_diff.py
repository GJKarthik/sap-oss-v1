#!/usr/bin/env python3
"""
sbom_diff.py — SBOM delta / diff tracking for CycloneDX 1.5 BOMs.

Compares two snapshots of the boms/ directory (or two single BOM files)
and reports added, removed, and version-changed components per project.

Use cases:
  - Gate a CI pipeline: fail if a high-risk license or copyleft dep is introduced
  - Weekly compliance tracking: know what new OSS entered the supply chain
  - Release notes: auto-generate dependency changelog

Exit codes:
  0  — no changes (or diff is clean against policy)
  1  — policy-violating changes detected (use --fail-on-new-copyleft / --fail-on-new-dep)
  2  — no BOM files found in one of the directories

Usage:
  # Compare two saved snapshot directories
  python3 scripts/sbom-lineage/sbom_diff.py --old boms-v1/ --new boms-v2/

  # Compare a single BOM pair
  python3 scripts/sbom-lineage/sbom_diff.py --old old.cdx.json --new new.cdx.json

  # CI gate: fail if any new copyleft component is introduced
  python3 scripts/sbom-lineage/sbom_diff.py --old boms-v1/ --new boms/ --fail-on-new-copyleft
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

COPYLEFT_LICENSES = {
    "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later",
    "AGPL-3.0-only", "AGPL-3.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later",
    "LGPL-3.0-only", "LGPL-3.0-or-later", "MPL-2.0", "EPL-1.0", "EPL-2.0",
    "EUPL-1.2", "OSL-3.0",
}


@dataclass
class ComponentSnapshot:
    name: str
    version: str
    purl: str
    licenses: list[str]
    supplier: str

    @property
    def key(self) -> str:
        """Canonical identity key (purl without version for cross-version tracking)."""
        base = self.purl.split("@")[0] if "@" in self.purl else self.purl
        return base or f"{self.name}"

    @property
    def has_copyleft(self) -> bool:
        for lic in self.licenses:
            for cl in COPYLEFT_LICENSES:
                if cl.lower() in lic.lower():
                    return True
        return False


@dataclass
class BomDiff:
    bom_name: str
    added: list[ComponentSnapshot]   = field(default_factory=list)
    removed: list[ComponentSnapshot] = field(default_factory=list)
    upgraded: list[tuple[ComponentSnapshot, ComponentSnapshot]] = field(default_factory=list)
    downgraded: list[tuple[ComponentSnapshot, ComponentSnapshot]] = field(default_factory=list)
    license_changed: list[tuple[ComponentSnapshot, ComponentSnapshot]] = field(default_factory=list)

    @property
    def total_changes(self) -> int:
        return len(self.added) + len(self.removed) + len(self.upgraded) + len(self.downgraded) + len(self.license_changed)

    @property
    def new_copyleft(self) -> list[ComponentSnapshot]:
        return [c for c in self.added if c.has_copyleft]


def _extract_licenses(comp: dict) -> list[str]:
    ids: list[str] = []
    for le in comp.get("licenses", []):
        if le.get("expression"):
            ids.append(le["expression"])
        lid = le.get("license", {}).get("id", "")
        if lid:
            ids.append(lid)
    return ids or ["NOASSERTION"]


def _extract_supplier(comp: dict) -> str:
    for k in ("supplier", "manufacturer", "publisher", "author"):
        v = comp.get(k)
        if isinstance(v, dict):
            n = v.get("name", "")
        else:
            n = str(v) if v else ""
        if n:
            return n
    return ""


def snapshot_bom(bom: dict) -> dict[str, ComponentSnapshot]:
    """Return {key → ComponentSnapshot} for every non-root component in a BOM."""
    meta     = bom.get("metadata", {})
    root_ref = (meta.get("component") or {}).get("bom-ref", "")
    snaps: dict[str, ComponentSnapshot] = {}
    for c in bom.get("components", []):
        if c.get("bom-ref") == root_ref:
            continue
        snap = ComponentSnapshot(
            name     = c.get("name", ""),
            version  = str(c.get("version", "")),
            purl     = c.get("purl", ""),
            licenses = _extract_licenses(c),
            supplier = _extract_supplier(c),
        )
        snaps[snap.key] = snap
    return snaps


def diff_boms(name: str, old_bom: dict, new_bom: dict) -> BomDiff:
    old_snap = snapshot_bom(old_bom)
    new_snap = snapshot_bom(new_bom)
    result   = BomDiff(bom_name=name)

    old_keys = set(old_snap)
    new_keys = set(new_snap)

    for key in new_keys - old_keys:
        result.added.append(new_snap[key])

    for key in old_keys - new_keys:
        result.removed.append(old_snap[key])

    for key in old_keys & new_keys:
        o = old_snap[key]
        n = new_snap[key]
        if o.version != n.version:
            if o.version < n.version:
                result.upgraded.append((o, n))
            else:
                result.downgraded.append((o, n))
        elif set(o.licenses) != set(n.licenses):
            result.license_changed.append((o, n))

    return result


def load_bom_dir(path: Path) -> dict[str, dict]:
    """Load all *.cyclonedx.json from a directory."""
    boms: dict[str, dict] = {}
    for f in sorted(path.glob("*.cyclonedx.json")):
        name = f.stem.replace(".cyclonedx", "")
        boms[name] = json.loads(f.read_text(encoding="utf-8"))
    return boms


def main() -> None:
    parser = argparse.ArgumentParser(description="Diff two SBOM snapshots (CycloneDX 1.5)")
    parser.add_argument("--old",                  required=True, type=Path,
                        help="Old BOM directory or single .cyclonedx.json")
    parser.add_argument("--new",                  required=True, type=Path,
                        help="New BOM directory or single .cyclonedx.json")
    parser.add_argument("--json",                 action="store_true")
    parser.add_argument("--fail-on-new-dep",      action="store_true",
                        help="Exit 1 if any new dependency is added")
    parser.add_argument("--fail-on-new-copyleft", action="store_true",
                        help="Exit 1 if any newly added component is copyleft-licensed")
    parser.add_argument("--fail-on-any-change",   action="store_true",
                        help="Exit 1 if there are any changes at all")
    args = parser.parse_args()

    # Load old and new snapshot
    def _load(p: Path) -> dict[str, dict]:
        if p.is_dir():
            return load_bom_dir(p)
        if p.suffix == ".json":
            name = p.stem.replace(".cyclonedx", "")
            return {name: json.loads(p.read_text(encoding="utf-8"))}
        print(f"Unknown path: {p}", file=sys.stderr)
        sys.exit(2)

    old_boms = _load(args.old)
    new_boms = _load(args.new)

    if not old_boms and not new_boms:
        print("No BOM files found.", file=sys.stderr)
        sys.exit(2)

    all_names = sorted(set(old_boms) | set(new_boms))
    diffs: list[BomDiff] = []
    for name in all_names:
        if name not in old_boms:
            # Entirely new BOM
            d = BomDiff(bom_name=name, added=list(snapshot_bom(new_boms[name]).values()))
        elif name not in new_boms:
            # Removed BOM
            d = BomDiff(bom_name=name, removed=list(snapshot_bom(old_boms[name]).values()))
        else:
            d = diff_boms(name, old_boms[name], new_boms[name])
        diffs.append(d)

    if args.json:
        out = []
        for d in diffs:
            out.append({
                "bom": d.bom_name,
                "added":   [{"name": c.name, "version": c.version, "purl": c.purl,
                              "licenses": c.licenses, "copyleft": c.has_copyleft} for c in d.added],
                "removed": [{"name": c.name, "version": c.version, "purl": c.purl} for c in d.removed],
                "upgraded": [{"name": o.name, "old": o.version, "new": n.version} for o, n in d.upgraded],
                "downgraded": [{"name": o.name, "old": o.version, "new": n.version} for o, n in d.downgraded],
                "license_changed": [{"name": o.name, "old": o.licenses, "new": n.licenses}
                                     for o, n in d.license_changed],
            })
        print(json.dumps(out, indent=2))
    else:
        print("=" * 72)
        print("  SBOM DIFF REPORT")
        print(f"  old: {args.old}")
        print(f"  new: {args.new}")
        print("=" * 72)
        total_added = total_removed = total_changed = 0
        new_copyleft_count = 0
        for d in diffs:
            if d.total_changes == 0:
                continue
            print(f"\n  {d.bom_name}")
            if d.added:
                print(f"    + {len(d.added)} added:")
                for c in d.added[:10]:
                    copyleft_flag = " [COPYLEFT]" if c.has_copyleft else ""
                    print(f"        {c.name}@{c.version}{copyleft_flag}")
                if len(d.added) > 10:
                    print(f"        ... and {len(d.added)-10} more")
            if d.removed:
                print(f"    - {len(d.removed)} removed:")
                for c in d.removed[:10]:
                    print(f"        {c.name}@{c.version}")
            if d.upgraded:
                print(f"    ↑ {len(d.upgraded)} upgraded:")
                for o, n in d.upgraded[:10]:
                    print(f"        {o.name}: {o.version} → {n.version}")
            if d.downgraded:
                print(f"    ↓ {len(d.downgraded)} downgraded:")
                for o, n in d.downgraded[:5]:
                    print(f"        {o.name}: {o.version} → {n.version}")
            if d.license_changed:
                print(f"    ~ {len(d.license_changed)} license change(s):")
                for o, n in d.license_changed[:5]:
                    print(f"        {o.name}: {o.licenses} → {n.licenses}")
            total_added   += len(d.added)
            total_removed += len(d.removed)
            total_changed += len(d.upgraded) + len(d.downgraded) + len(d.license_changed)
            new_copyleft_count += len(d.new_copyleft)

        print(f"\n{'='*72}")
        print(f"  TOTALS: +{total_added} added  -{total_removed} removed  ~{total_changed} changed")
        if new_copyleft_count:
            print(f"  ⚠  {new_copyleft_count} newly introduced copyleft component(s) — review required")
        print("=" * 72)

    # Policy exit codes
    if args.fail_on_any_change and any(d.total_changes > 0 for d in diffs):
        sys.exit(1)
    if args.fail_on_new_dep and total_added > 0:
        sys.exit(1)
    if args.fail_on_new_copyleft and new_copyleft_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()

