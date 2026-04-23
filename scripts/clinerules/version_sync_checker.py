#!/usr/bin/env python3
"""
Version Synchronization Checker for .clinerules Files

This script addresses the versioning synchronization gap by:
1. Extracting version information from all .clinerules files
2. Comparing versions across related artifacts
3. Detecting version drift between specs, schemas, and rule packs
4. Generating synchronization reports

Usage:
    python scripts/clinerules/version_sync_checker.py --mode check
    python scripts/clinerules/version_sync_checker.py --mode report
    python scripts/clinerules/version_sync_checker.py --mode fix --dry-run
"""

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional


@dataclass
class VersionInfo:
    """Version information extracted from a file."""
    file_path: str
    version: Optional[str] = None
    date: Optional[str] = None
    last_modified: Optional[str] = None
    source_line: Optional[int] = None
    
    def to_dict(self) -> dict:
        return {
            "file_path": self.file_path,
            "version": self.version,
            "date": self.date,
            "last_modified": self.last_modified,
            "source_line": self.source_line
        }


@dataclass
class VersionDrift:
    """Detected version drift between related files."""
    drift_id: str
    severity: str  # CRITICAL, HIGH, MEDIUM, LOW
    source_file: str
    related_file: str
    source_version: Optional[str]
    related_version: Optional[str]
    description: str
    remediation: str
    
    def to_dict(self) -> dict:
        return {
            "drift_id": self.drift_id,
            "severity": self.severity,
            "source_file": self.source_file,
            "related_file": self.related_file,
            "source_version": self.source_version,
            "related_version": self.related_version,
            "description": self.description,
            "remediation": self.remediation
        }


@dataclass
class SyncReport:
    """Version synchronization report."""
    timestamp: str
    total_files: int
    files_with_versions: int
    drift_findings: list = field(default_factory=list)
    version_map: dict = field(default_factory=dict)
    
    def to_dict(self) -> dict:
        return {
            "timestamp": self.timestamp,
            "total_files": self.total_files,
            "files_with_versions": self.files_with_versions,
            "drift_findings": [d.to_dict() for d in self.drift_findings],
            "version_map": self.version_map,
            "summary": {
                "critical": sum(1 for d in self.drift_findings if d.severity == "CRITICAL"),
                "high": sum(1 for d in self.drift_findings if d.severity == "HIGH"),
                "medium": sum(1 for d in self.drift_findings if d.severity == "MEDIUM"),
                "low": sum(1 for d in self.drift_findings if d.severity == "LOW"),
            }
        }


class VersionSyncChecker:
    """Main version synchronization checker."""
    
    # Patterns for extracting version information
    VERSION_PATTERNS = [
        # Markdown table: | 1.0.0 | 2026-04-21 | ...
        r'\|\s*(\d+\.\d+\.\d+)\s*\|\s*(\d{4}-\d{2}-\d{2})\s*\|',
        # YAML frontmatter: version: 1.0.0
        r'^version:\s*["\']?(\d+\.\d+\.\d+)["\']?',
        # Comment: Version: 1.0.0
        r'#?\s*[Vv]ersion:?\s*(\d+\.\d+\.\d+)',
        # LaTeX: Ref: \texttt{...-v1.0.0}
        r'Ref:.*v(\d+\.\d+\.\d+)',
        # JSON Schema $id with version
        r'\$id.*v(\d+\.\d+\.\d+)',
    ]
    
    DATE_PATTERNS = [
        r'(\d{4}-\d{2}-\d{2})',
        r'(\w+\s+\d{4})',  # "April 2026"
    ]
    
    # Related file mappings
    RELATED_FILES = {
        ".clinerules": [
            ".clinerules.runtime-monitor",
        ],
        "src/intelligence/.clinerules": [
            "docs/latex/specs/regulations/regulations-spec.tex",
            "docs/schema/regulations/requirement.schema.json",
        ],
        "src/training/.clinerules": [
            "docs/latex/specs/simula/simula-training-spec.tex",
            "docs/schema/simula/training-scenario.schema.json",
        ],
        "src/generativeUI/.clinerules": [
            "docs/latex/specs/clinerules-agents/chapters/03-agent-rule-pack-architecture.tex",
        ],
    }
    
    def __init__(self, repo_root: str = "."):
        self.repo_root = Path(repo_root)
        self.clinerules_files: list[Path] = []
        self.version_info: dict[str, VersionInfo] = {}
        
    def discover_clinerules_files(self) -> list[Path]:
        """Find all .clinerules files in the repository."""
        patterns = [
            "**/.clinerules",
            "**/.clinerules.*",
        ]
        
        files = []
        for pattern in patterns:
            files.extend(self.repo_root.glob(pattern))
        
        # Filter out .git directory
        self.clinerules_files = [
            f for f in files 
            if ".git" not in str(f) and f.is_file()
        ]
        return self.clinerules_files
    
    def extract_version(self, file_path: Path) -> VersionInfo:
        """Extract version information from a file."""
        info = VersionInfo(file_path=str(file_path.relative_to(self.repo_root)))
        
        try:
            content = file_path.read_text(encoding="utf-8")
            lines = content.split("\n")
            
            # Try each version pattern
            for i, line in enumerate(lines):
                for pattern in self.VERSION_PATTERNS:
                    match = re.search(pattern, line, re.IGNORECASE)
                    if match:
                        info.version = match.group(1)
                        info.source_line = i + 1
                        
                        # Try to extract date from same line or table row
                        for date_pattern in self.DATE_PATTERNS:
                            date_match = re.search(date_pattern, line)
                            if date_match:
                                info.date = date_match.group(1)
                                break
                        break
                if info.version:
                    break
            
            # Get file modification time
            stat = file_path.stat()
            info.last_modified = datetime.fromtimestamp(stat.st_mtime).isoformat()
            
        except Exception as e:
            print(f"Warning: Could not read {file_path}: {e}", file=sys.stderr)
        
        return info
    
    def check_version_drift(self) -> list[VersionDrift]:
        """Check for version drift between related files."""
        drifts = []
        drift_counter = 0
        
        for file_path, info in self.version_info.items():
            # Find related files
            for pattern, related_list in self.RELATED_FILES.items():
                if pattern in file_path or file_path.endswith(pattern):
                    for related_pattern in related_list:
                        related_path = self.repo_root / related_pattern
                        
                        # Check if related file exists
                        if not related_path.exists():
                            # Try pattern matching
                            related_path = Path(file_path).parent / related_pattern
                        
                        if related_path.exists():
                            related_info = self.extract_version(related_path)
                            
                            # Compare versions
                            if info.version and related_info.version:
                                if info.version != related_info.version:
                                    drift_counter += 1
                                    severity = self._determine_severity(
                                        info.version, related_info.version
                                    )
                                    drifts.append(VersionDrift(
                                        drift_id=f"VSYNC-{drift_counter:04d}",
                                        severity=severity,
                                        source_file=file_path,
                                        related_file=str(related_path.relative_to(self.repo_root)),
                                        source_version=info.version,
                                        related_version=related_info.version,
                                        description=f"Version mismatch: {info.version} vs {related_info.version}",
                                        remediation="Synchronize versions across related files"
                                    ))
                            elif info.version and not related_info.version:
                                drift_counter += 1
                                drifts.append(VersionDrift(
                                    drift_id=f"VSYNC-{drift_counter:04d}",
                                    severity="MEDIUM",
                                    source_file=file_path,
                                    related_file=str(related_path.relative_to(self.repo_root)),
                                    source_version=info.version,
                                    related_version=None,
                                    description="Related file missing version information",
                                    remediation="Add VERSION HISTORY section to related file"
                                ))
        
        # Check for stale versions based on file modification time
        for file_path, info in self.version_info.items():
            if info.version and info.date and info.last_modified:
                try:
                    version_date = datetime.fromisoformat(info.date) if "-" in info.date else None
                    modified_date = datetime.fromisoformat(info.last_modified)
                    
                    if version_date:
                        days_since_version = (modified_date - version_date).days
                        if days_since_version > 30:
                            drift_counter += 1
                            drifts.append(VersionDrift(
                                drift_id=f"VSYNC-{drift_counter:04d}",
                                severity="LOW",
                                source_file=file_path,
                                related_file=file_path,
                                source_version=info.version,
                                related_version=None,
                                description=f"Version date ({info.date}) is {days_since_version} days older than last modification",
                                remediation="Update version history if changes were made"
                            ))
                except (ValueError, TypeError):
                    pass
        
        return drifts
    
    def _determine_severity(self, version1: str, version2: str) -> str:
        """Determine drift severity based on version difference."""
        try:
            parts1 = [int(x) for x in version1.split(".")]
            parts2 = [int(x) for x in version2.split(".")]
            
            # Major version difference
            if parts1[0] != parts2[0]:
                return "CRITICAL"
            # Minor version difference
            if len(parts1) > 1 and len(parts2) > 1 and parts1[1] != parts2[1]:
                return "HIGH"
            # Patch version difference
            return "MEDIUM"
        except (ValueError, IndexError):
            return "MEDIUM"
    
    def run_check(self) -> SyncReport:
        """Run the full version synchronization check."""
        # Discover files
        self.discover_clinerules_files()
        
        # Extract versions
        for file_path in self.clinerules_files:
            info = self.extract_version(file_path)
            self.version_info[info.file_path] = info
        
        # Check for drift
        drifts = self.check_version_drift()
        
        # Build report
        report = SyncReport(
            timestamp=datetime.now().isoformat(),
            total_files=len(self.clinerules_files),
            files_with_versions=sum(1 for v in self.version_info.values() if v.version),
            drift_findings=drifts,
            version_map={
                k: v.to_dict() for k, v in self.version_info.items()
            }
        )
        
        return report
    
    def generate_fix_suggestions(self, report: SyncReport) -> list[dict]:
        """Generate fix suggestions for detected drift."""
        suggestions = []
        
        for drift in report.drift_findings:
            suggestion = {
                "drift_id": drift.drift_id,
                "files_to_update": [],
                "suggested_version": None,
                "commands": []
            }
            
            # Determine which file should be updated
            if drift.source_version and drift.related_version:
                # Use the higher version as the target
                try:
                    v1 = [int(x) for x in drift.source_version.split(".")]
                    v2 = [int(x) for x in drift.related_version.split(".")]
                    if v1 > v2:
                        suggestion["suggested_version"] = drift.source_version
                        suggestion["files_to_update"].append(drift.related_file)
                    else:
                        suggestion["suggested_version"] = drift.related_version
                        suggestion["files_to_update"].append(drift.source_file)
                except (ValueError, IndexError):
                    pass
            elif drift.source_version and not drift.related_version:
                suggestion["suggested_version"] = drift.source_version
                suggestion["files_to_update"].append(drift.related_file)
                suggestion["commands"].append(
                    f"# Add version history to {drift.related_file}"
                )
            
            suggestions.append(suggestion)
        
        return suggestions


def main():
    parser = argparse.ArgumentParser(
        description="Check version synchronization across .clinerules files"
    )
    parser.add_argument(
        "--mode",
        choices=["check", "report", "fix"],
        default="check",
        help="Operation mode"
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root directory"
    )
    parser.add_argument(
        "--output",
        choices=["console", "json", "github-actions"],
        default="console",
        help="Output format"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes"
    )
    parser.add_argument(
        "--fail-on-drift",
        action="store_true",
        help="Exit with non-zero status if drift is detected"
    )
    
    args = parser.parse_args()
    
    checker = VersionSyncChecker(args.repo_root)
    report = checker.run_check()
    
    if args.output == "json":
        print(json.dumps(report.to_dict(), indent=2))
    elif args.output == "github-actions":
        # GitHub Actions annotation format
        for drift in report.drift_findings:
            level = "error" if drift.severity in ["CRITICAL", "HIGH"] else "warning"
            print(f"::{level} file={drift.source_file}::{drift.drift_id}: {drift.description}")
        
        if report.drift_findings:
            print(f"\n::group::Version Sync Summary")
            print(f"Total files checked: {report.total_files}")
            print(f"Files with versions: {report.files_with_versions}")
            print(f"Drift findings: {len(report.drift_findings)}")
            print(f"::endgroup::")
    else:
        # Console output
        print("=" * 60)
        print("Version Synchronization Report")
        print("=" * 60)
        print(f"Timestamp: {report.timestamp}")
        print(f"Total .clinerules files: {report.total_files}")
        print(f"Files with version info: {report.files_with_versions}")
        print()
        
        if report.drift_findings:
            print("DRIFT FINDINGS:")
            print("-" * 40)
            for drift in report.drift_findings:
                severity_icon = {
                    "CRITICAL": "🔴",
                    "HIGH": "🟠",
                    "MEDIUM": "🟡",
                    "LOW": "🔵"
                }.get(drift.severity, "⚪")
                
                print(f"\n{severity_icon} [{drift.severity}] {drift.drift_id}")
                print(f"   Source: {drift.source_file} (v{drift.source_version})")
                print(f"   Related: {drift.related_file} (v{drift.related_version})")
                print(f"   Issue: {drift.description}")
                print(f"   Fix: {drift.remediation}")
        else:
            print("✅ No version drift detected!")
        
        print()
        print("=" * 60)
        summary = report.to_dict()["summary"]
        print(f"Summary: {summary['critical']} critical, {summary['high']} high, "
              f"{summary['medium']} medium, {summary['low']} low")
        print("=" * 60)
    
    if args.mode == "fix" and args.dry_run:
        suggestions = checker.generate_fix_suggestions(report)
        print("\nFix Suggestions (dry-run):")
        print("-" * 40)
        for suggestion in suggestions:
            print(f"\n{suggestion['drift_id']}:")
            print(f"  Suggested version: {suggestion['suggested_version']}")
            print(f"  Files to update: {suggestion['files_to_update']}")
            for cmd in suggestion['commands']:
                print(f"  {cmd}")
    
    # Exit with error if drift detected and flag is set
    if args.fail_on_drift and report.drift_findings:
        critical_high = sum(
            1 for d in report.drift_findings 
            if d.severity in ["CRITICAL", "HIGH"]
        )
        if critical_high > 0:
            sys.exit(1)
    
    sys.exit(0)


if __name__ == "__main__":
    main()