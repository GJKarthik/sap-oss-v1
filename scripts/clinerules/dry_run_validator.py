#!/usr/bin/env python3
"""
Interactive Dry-Run Validator for Cline Agents

This script provides a dry-run mode for agents to preview what they would do
without actually executing changes. It addresses the need for developers to
gain confidence before agents make modifications.

Features:
1. Parse .clinerules files and extract action rules
2. Simulate what an agent would do for a given task
3. Show file changes that would be made
4. Validate without modifying files
5. Generate detailed execution plans

Usage:
    python scripts/clinerules/dry_run_validator.py --task "Add new API endpoint"
    python scripts/clinerules/dry_run_validator.py --validate src/intelligence/.clinerules
    python scripts/clinerules/dry_run_validator.py --preview-changes --task "Fix bug"
    python scripts/clinerules/dry_run_validator.py --interactive
"""

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional


class ActionType(Enum):
    """Types of actions an agent might take."""
    READ_FILE = "read_file"
    WRITE_FILE = "write_file"
    MODIFY_FILE = "modify_file"
    DELETE_FILE = "delete_file"
    RUN_COMMAND = "run_command"
    RUN_TEST = "run_test"
    VALIDATE_SCHEMA = "validate_schema"
    CHECK_DRIFT = "check_drift"


class Severity(Enum):
    """Severity levels for validation findings."""
    ERROR = "error"
    WARNING = "warning"
    INFO = "info"


@dataclass
class ValidationFinding:
    """A finding from validation."""
    severity: Severity
    category: str
    message: str
    location: Optional[str] = None
    suggestion: Optional[str] = None
    
    def to_dict(self) -> dict:
        return {
            "severity": self.severity.value,
            "category": self.category,
            "message": self.message,
            "location": self.location,
            "suggestion": self.suggestion
        }


@dataclass
class PlannedAction:
    """An action that would be taken."""
    action_type: ActionType
    target: str
    description: str
    reason: str
    blocked_by: list = field(default_factory=list)
    requires_approval: bool = False
    
    def to_dict(self) -> dict:
        return {
            "action_type": self.action_type.value,
            "target": self.target,
            "description": self.description,
            "reason": self.reason,
            "blocked_by": self.blocked_by,
            "requires_approval": self.requires_approval
        }


@dataclass
class DryRunResult:
    """Result of a dry-run validation."""
    timestamp: str
    clinerules_path: str
    task_description: str
    planned_actions: list = field(default_factory=list)
    validation_findings: list = field(default_factory=list)
    pre_change_checklist: list = field(default_factory=list)
    post_change_smoke_tests: list = field(default_factory=list)
    would_proceed: bool = True
    blocking_reason: Optional[str] = None
    
    def to_dict(self) -> dict:
        return {
            "timestamp": self.timestamp,
            "clinerules_path": self.clinerules_path,
            "task_description": self.task_description,
            "planned_actions": [a.to_dict() for a in self.planned_actions],
            "validation_findings": [f.to_dict() for f in self.validation_findings],
            "pre_change_checklist": self.pre_change_checklist,
            "post_change_smoke_tests": self.post_change_smoke_tests,
            "would_proceed": self.would_proceed,
            "blocking_reason": self.blocking_reason,
            "summary": {
                "total_actions": len(self.planned_actions),
                "requires_approval": sum(1 for a in self.planned_actions if a.requires_approval),
                "errors": sum(1 for f in self.validation_findings if f.severity == Severity.ERROR),
                "warnings": sum(1 for f in self.validation_findings if f.severity == Severity.WARNING),
            }
        }


class ClinerulesPack:
    """Parsed .clinerules file."""
    
    def __init__(self, path: Path):
        self.path = path
        self.content = ""
        self.sections: dict[str, str] = {}
        self.source_of_truth: list[str] = []
        self.read_first_files: list[str] = []
        self.known_issues: list[dict] = []
        self.engineering_rules: list[str] = []
        self.pre_change_checklist: list[str] = []
        self.post_change_smoke_tests: list[str] = []
        self.definition_of_done: list[str] = []
        
    def parse(self) -> bool:
        """Parse the .clinerules file."""
        try:
            self.content = self.path.read_text(encoding="utf-8")
            self._extract_sections()
            self._parse_source_of_truth()
            self._parse_read_first()
            self._parse_known_issues()
            self._parse_engineering_rules()
            self._parse_checklists()
            self._parse_definition_of_done()
            return True
        except Exception as e:
            print(f"Error parsing {self.path}: {e}", file=sys.stderr)
            return False
    
    def _extract_sections(self):
        """Extract sections from the file."""
        current_section = "header"
        current_content = []
        
        for line in self.content.split("\n"):
            # Check for section header (multiple dashes or equals)
            if re.match(r'^#\s*-{10,}|^#\s*={10,}', line):
                if current_content:
                    self.sections[current_section] = "\n".join(current_content)
                current_content = []
                continue
            
            # Check for section title
            title_match = re.match(r'^#+\s*(.+?)\s*$', line)
            if title_match and not line.startswith("# NOTE"):
                section_name = title_match.group(1).strip().lower().replace(" ", "_")
                if current_content:
                    self.sections[current_section] = "\n".join(current_content)
                current_section = section_name
                current_content = []
            else:
                current_content.append(line)
        
        if current_content:
            self.sections[current_section] = "\n".join(current_content)
    
    def _parse_source_of_truth(self):
        """Parse source of truth section."""
        content = self.sections.get("source_of_truth", "")
        # Extract file paths (backtick-enclosed or after dash)
        paths = re.findall(r'`([^`]+)`', content)
        paths += re.findall(r'^\s*-\s*(\S+\.(?:tex|json|yaml|py|ts))', content, re.MULTILINE)
        self.source_of_truth = list(set(paths))
    
    def _parse_read_first(self):
        """Parse read-first files section."""
        for key in ["read_first_on_every_task", "read_first"]:
            content = self.sections.get(key, "")
            if content:
                # Extract numbered items
                items = re.findall(r'^\d+\.\s*(.+?)$', content, re.MULTILINE)
                self.read_first_files = items
                break
    
    def _parse_known_issues(self):
        """Parse known issues section."""
        content = self.sections.get("known_issue_registry", "") or self.sections.get("known_issues", "")
        # Extract issue patterns: - DOMAIN-KI-001 description:
        issues = re.findall(
            r'-\s*(\w+-KI-\d+)\s+([^:]+):\s*\n\s*-\s*symptom:\s*(.+?)\n\s*-\s*impact:\s*(.+?)\n\s*-\s*prevention:\s*(.+?)(?=\n-\s*\w+-KI|\n\n|\Z)',
            content,
            re.DOTALL
        )
        for issue in issues:
            self.known_issues.append({
                "id": issue[0],
                "description": issue[1].strip(),
                "symptom": issue[2].strip(),
                "impact": issue[3].strip(),
                "prevention": issue[4].strip()
            })
    
    def _parse_engineering_rules(self):
        """Parse non-negotiable engineering rules."""
        content = self.sections.get("non-negotiable_engineering_rules", "") or self.sections.get("engineering_rules", "")
        rules = re.findall(r'^\d+\.\s*(.+?)$', content, re.MULTILINE)
        self.engineering_rules = rules
    
    def _parse_checklists(self):
        """Parse pre-change and post-change checklists."""
        pre_content = self.sections.get("pre-change_checklist", "") or self.sections.get("pre_change_checklist", "")
        post_content = self.sections.get("post-change_smoke_tests", "") or self.sections.get("post_change_smoke_tests", "")
        
        # Extract checklist items
        self.pre_change_checklist = re.findall(r'-\s*\[[ x]\]\s*(.+?)$', pre_content, re.MULTILINE)
        if not self.pre_change_checklist:
            self.pre_change_checklist = re.findall(r'-\s*(.+?)$', pre_content, re.MULTILINE)
        
        # Extract smoke test commands
        self.post_change_smoke_tests = re.findall(r'-\s*(.+?):\s*`(.+?)`', post_content)
        if not self.post_change_smoke_tests:
            self.post_change_smoke_tests = re.findall(r'`([^`]+)`', post_content)
    
    def _parse_definition_of_done(self):
        """Parse definition of done."""
        content = self.sections.get("definition_of_done", "") or self.sections.get("10/10_definition_of_done", "")
        items = re.findall(r'-\s*(.+?)$', content, re.MULTILINE)
        self.definition_of_done = items


class DryRunValidator:
    """Main dry-run validator."""
    
    def __init__(self, repo_root: str = "."):
        self.repo_root = Path(repo_root)
        self.pack: Optional[ClinerulesPack] = None
        
    def load_clinerules(self, path: str) -> bool:
        """Load and parse a .clinerules file."""
        full_path = self.repo_root / path
        if not full_path.exists():
            print(f"Error: {path} does not exist", file=sys.stderr)
            return False
        
        self.pack = ClinerulesPack(full_path)
        return self.pack.parse()
    
    def validate_structure(self) -> list[ValidationFinding]:
        """Validate the structure of the loaded .clinerules file."""
        findings = []
        
        if not self.pack:
            findings.append(ValidationFinding(
                severity=Severity.ERROR,
                category="structure",
                message="No .clinerules file loaded"
            ))
            return findings
        
        # Required sections
        required_sections = [
            ("purpose", "Purpose section is required"),
            ("mission", "Mission section is required"),
            ("source_of_truth", "Source of Truth section is required"),
        ]
        
        for section, message in required_sections:
            if section not in self.pack.sections:
                findings.append(ValidationFinding(
                    severity=Severity.ERROR,
                    category="structure",
                    message=message,
                    suggestion=f"Add a '{section.replace('_', ' ').title()}' section"
                ))
        
        # Recommended sections
        recommended_sections = [
            ("known_issue_registry", "Known Issue Registry helps prevent repeated mistakes"),
            ("pre-change_checklist", "Pre-change checklist improves task quality"),
            ("post-change_smoke_tests", "Smoke tests verify changes work"),
        ]
        
        for section, message in recommended_sections:
            section_variants = [section, section.replace("-", "_")]
            if not any(s in self.pack.sections for s in section_variants):
                findings.append(ValidationFinding(
                    severity=Severity.WARNING,
                    category="structure",
                    message=message,
                    suggestion=f"Consider adding a '{section.replace('_', ' ').title()}' section"
                ))
        
        # Check minimum content
        if len(self.pack.source_of_truth) < 2:
            findings.append(ValidationFinding(
                severity=Severity.WARNING,
                category="content",
                message="Source of Truth should reference at least 2 files",
                suggestion="Add spec and schema references"
            ))
        
        if len(self.pack.known_issues) < 3:
            findings.append(ValidationFinding(
                severity=Severity.WARNING,
                category="content",
                message=f"Only {len(self.pack.known_issues)} known issues documented (recommend >= 3)",
                suggestion="Document known issues to prevent repeated mistakes"
            ))
        
        if len(self.pack.engineering_rules) < 3:
            findings.append(ValidationFinding(
                severity=Severity.WARNING,
                category="content",
                message=f"Only {len(self.pack.engineering_rules)} engineering rules (recommend >= 3)",
                suggestion="Add more specific engineering rules"
            ))
        
        return findings
    
    def validate_paths(self) -> list[ValidationFinding]:
        """Validate that referenced paths exist."""
        findings = []
        
        if not self.pack:
            return findings
        
        for path in self.pack.source_of_truth:
            # Clean up the path
            clean_path = path.strip("`").strip()
            if clean_path.startswith("<") or "*" in clean_path:
                continue  # Skip placeholders and globs
            
            full_path = self.repo_root / clean_path
            if not full_path.exists():
                findings.append(ValidationFinding(
                    severity=Severity.WARNING,
                    category="paths",
                    message=f"Referenced path does not exist: {clean_path}",
                    location=clean_path,
                    suggestion="Verify path is correct or update .clinerules"
                ))
        
        return findings
    
    def simulate_task(self, task_description: str) -> DryRunResult:
        """Simulate what would happen for a given task."""
        result = DryRunResult(
            timestamp=datetime.now().isoformat(),
            clinerules_path=str(self.pack.path) if self.pack else "unknown",
            task_description=task_description
        )
        
        if not self.pack:
            result.would_proceed = False
            result.blocking_reason = "No .clinerules file loaded"
            return result
        
        # Add validation findings
        result.validation_findings = self.validate_structure() + self.validate_paths()
        
        # Add pre-change checklist
        result.pre_change_checklist = list(self.pack.pre_change_checklist)
        
        # Add post-change smoke tests
        result.post_change_smoke_tests = [
            str(t) for t in self.pack.post_change_smoke_tests
        ]
        
        # Simulate planned actions based on task
        result.planned_actions = self._plan_actions(task_description)
        
        # Check for blocking conditions
        errors = [f for f in result.validation_findings if f.severity == Severity.ERROR]
        if errors:
            result.would_proceed = False
            result.blocking_reason = f"{len(errors)} validation error(s) must be resolved"
        
        return result
    
    def _plan_actions(self, task_description: str) -> list[PlannedAction]:
        """Plan actions based on task description and rules."""
        actions = []
        
        if not self.pack:
            return actions
        
        # Always start by reading the clinerules
        actions.append(PlannedAction(
            action_type=ActionType.READ_FILE,
            target=str(self.pack.path),
            description="Read agent rules file",
            reason="Required by read-first protocol"
        ))
        
        # Add read-first files
        for i, item in enumerate(self.pack.read_first_files[:5]):  # Limit to 5
            actions.append(PlannedAction(
                action_type=ActionType.READ_FILE,
                target=f"(Step {i+1}) {item}",
                description=item,
                reason="Listed in Read First section"
            ))
        
        # Add source of truth reads
        for path in self.pack.source_of_truth[:3]:  # Limit to 3
            actions.append(PlannedAction(
                action_type=ActionType.READ_FILE,
                target=path,
                description=f"Read source of truth: {path}",
                reason="Referenced in Source of Truth section"
            ))
        
        # Determine likely file modifications based on task keywords
        task_lower = task_description.lower()
        
        if any(kw in task_lower for kw in ["add", "create", "new"]):
            actions.append(PlannedAction(
                action_type=ActionType.WRITE_FILE,
                target="<new-file>",
                description="Create new file based on task",
                reason="Task involves adding new functionality",
                requires_approval=True
            ))
        
        if any(kw in task_lower for kw in ["fix", "update", "modify", "change"]):
            actions.append(PlannedAction(
                action_type=ActionType.MODIFY_FILE,
                target="<existing-file>",
                description="Modify existing file",
                reason="Task involves changing existing code",
                requires_approval=True
            ))
        
        if any(kw in task_lower for kw in ["schema", "contract", "api"]):
            actions.append(PlannedAction(
                action_type=ActionType.VALIDATE_SCHEMA,
                target="<schema-file>",
                description="Validate against schema",
                reason="Task involves schema-backed data"
            ))
            actions.append(PlannedAction(
                action_type=ActionType.CHECK_DRIFT,
                target="spec-code-mapping",
                description="Check for spec drift",
                reason="Schema changes require drift check"
            ))
        
        # Always end with tests
        actions.append(PlannedAction(
            action_type=ActionType.RUN_TEST,
            target="make test",
            description="Run test suite",
            reason="Required by definition of done"
        ))
        
        return actions
    
    def run_interactive(self):
        """Run in interactive mode."""
        print("=" * 60)
        print("Cline Agent Dry-Run Validator - Interactive Mode")
        print("=" * 60)
        print()
        
        # Find available .clinerules files
        clinerules_files = list(self.repo_root.glob("**/.clinerules"))
        clinerules_files = [f for f in clinerules_files if ".git" not in str(f)]
        
        if not clinerules_files:
            print("No .clinerules files found in repository.")
            return
        
        print("Available .clinerules files:")
        for i, f in enumerate(clinerules_files[:10], 1):
            print(f"  {i}. {f.relative_to(self.repo_root)}")
        
        print()
        choice = input("Select a file (number) or enter path: ").strip()
        
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(clinerules_files):
                selected = clinerules_files[idx]
            else:
                print("Invalid selection")
                return
        except ValueError:
            selected = self.repo_root / choice
        
        if not self.load_clinerules(str(selected.relative_to(self.repo_root))):
            print("Failed to load file")
            return
        
        print(f"\nLoaded: {selected.relative_to(self.repo_root)}")
        print()
        
        # Show structure validation
        print("Structure Validation:")
        print("-" * 40)
        findings = self.validate_structure()
        for f in findings:
            icon = {"error": "❌", "warning": "⚠️", "info": "ℹ️"}[f.severity.value]
            print(f"  {icon} [{f.severity.value.upper()}] {f.message}")
            if f.suggestion:
                print(f"      💡 {f.suggestion}")
        
        if not findings:
            print("  ✅ No issues found")
        
        print()
        
        # Get task description
        task = input("Enter task description (or 'q' to quit): ").strip()
        if task.lower() == 'q':
            return
        
        # Simulate
        result = self.simulate_task(task)
        
        print()
        print("=" * 60)
        print("DRY-RUN SIMULATION RESULT")
        print("=" * 60)
        print()
        
        print(f"Task: {task}")
        print(f"Would proceed: {'✅ Yes' if result.would_proceed else '❌ No'}")
        if result.blocking_reason:
            print(f"Blocking reason: {result.blocking_reason}")
        
        print()
        print("Planned Actions:")
        print("-" * 40)
        for i, action in enumerate(result.planned_actions, 1):
            approval = "🔒" if action.requires_approval else "✓"
            print(f"  {i}. [{approval}] {action.action_type.value}: {action.description}")
            print(f"      Target: {action.target}")
            print(f"      Reason: {action.reason}")
        
        print()
        print("Pre-Change Checklist:")
        print("-" * 40)
        for item in result.pre_change_checklist:
            print(f"  [ ] {item}")
        
        print()
        print("Post-Change Smoke Tests:")
        print("-" * 40)
        for test in result.post_change_smoke_tests:
            print(f"  - {test}")


def main():
    parser = argparse.ArgumentParser(
        description="Interactive dry-run validator for Cline agents"
    )
    parser.add_argument(
        "--validate",
        metavar="PATH",
        help="Validate a specific .clinerules file"
    )
    parser.add_argument(
        "--task",
        help="Task description to simulate"
    )
    parser.add_argument(
        "--preview-changes",
        action="store_true",
        help="Show detailed change preview"
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Run in interactive mode"
    )
    parser.add_argument(
        "--output",
        choices=["console", "json"],
        default="console",
        help="Output format"
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root directory"
    )
    
    args = parser.parse_args()
    
    validator = DryRunValidator(args.repo_root)
    
    if args.interactive:
        validator.run_interactive()
        return
    
    if args.validate:
        if not validator.load_clinerules(args.validate):
            sys.exit(1)
        
        findings = validator.validate_structure() + validator.validate_paths()
        
        if args.output == "json":
            print(json.dumps([f.to_dict() for f in findings], indent=2))
        else:
            print(f"Validating: {args.validate}")
            print("-" * 40)
            for f in findings:
                icon = {"error": "❌", "warning": "⚠️", "info": "ℹ️"}[f.severity.value]
                print(f"{icon} [{f.severity.value.upper()}] {f.message}")
                if f.location:
                    print(f"   Location: {f.location}")
                if f.suggestion:
                    print(f"   💡 {f.suggestion}")
            
            if not findings:
                print("✅ No issues found")
            
            errors = sum(1 for f in findings if f.severity == Severity.ERROR)
            if errors > 0:
                sys.exit(1)
        return
    
    if args.task:
        # Find nearest .clinerules
        clinerules_path = ".clinerules"
        if not validator.load_clinerules(clinerules_path):
            print("No .clinerules file found in current directory")
            sys.exit(1)
        
        result = validator.simulate_task(args.task)
        
        if args.output == "json":
            print(json.dumps(result.to_dict(), indent=2))
        else:
            print("=" * 60)
            print("DRY-RUN SIMULATION")
            print("=" * 60)
            print(f"Task: {args.task}")
            print(f"Would proceed: {'Yes' if result.would_proceed else 'No'}")
            print()
            
            print("Planned Actions:")
            for i, action in enumerate(result.planned_actions, 1):
                print(f"  {i}. {action.action_type.value}: {action.description}")
            
            if result.validation_findings:
                print()
                print("Findings:")
                for f in result.validation_findings:
                    print(f"  - [{f.severity.value}] {f.message}")
        return
    
    # Default: show help
    parser.print_help()


if __name__ == "__main__":
    main()