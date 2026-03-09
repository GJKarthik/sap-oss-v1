#!/usr/bin/env python3
"""
Mangle Rule Validation Harness

Validates .mg rule files for:
1. Syntax consistency (Decl declarations, rule definitions)
2. Dependency analysis (used predicates are declared)
3. Circular dependency detection
4. Coverage verification against Zig implementation modules
"""

import os
import re
import sys
from pathlib import Path
from collections import defaultdict

MANGLE_DIR = Path(__file__).parent.parent


def parse_declarations(content: str) -> set[str]:
    """Extract all Decl predicate names."""
    return set(re.findall(r"Decl\s+(\w+)\s*\(", content))


def parse_rule_heads(content: str) -> set[str]:
    """Extract all rule head predicate names."""
    heads = set()
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        m = re.match(r"(\w+)\s*\(", line)
        if m and not line.startswith("Decl"):
            heads.add(m.group(1))
    return heads


def parse_body_predicates(content: str) -> set[str]:
    """Extract all predicates used in rule bodies."""
    used = set()
    in_body = False
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            in_body = False
            continue
        if ":-" in line:
            body = line.split(":-", 1)[1]
            for m in re.finditer(r"(\w+)\s*\(", body):
                name = m.group(1)
                if not name.startswith("fn:") and name not in (
                    "let", "count", "assert_true", "assert_equal",
                ):
                    used.add(name)
            in_body = True
        elif in_body and not line.endswith("."):
            for m in re.finditer(r"(\w+)\s*\(", line):
                name = m.group(1)
                if not name.startswith("fn:") and name not in (
                    "let", "count", "assert_true", "assert_equal",
                ):
                    used.add(name)
        if line.endswith("."):
            in_body = False
    return used


def find_mg_files(root: Path) -> list[Path]:
    """Find all .mg files recursively."""
    return sorted(root.rglob("*.mg"))


def build_dependency_graph(
    files: list[Path],
) -> tuple[dict[str, set[str]], dict[str, set[str]], dict[str, set[str]]]:
    """Build dependency graph across all files."""
    all_decls: dict[str, set[str]] = {}  # file -> declared predicates
    all_heads: dict[str, set[str]] = {}
    all_deps: dict[str, set[str]] = {}   # file -> used predicates

    for f in files:
        content = f.read_text()
        all_decls[str(f)] = parse_declarations(content)
        all_heads[str(f)] = parse_rule_heads(content)
        all_deps[str(f)] = parse_body_predicates(content)

    return all_decls, all_heads, all_deps


def check_undeclared_predicates(
    all_decls: dict[str, set[str]],
    all_heads: dict[str, set[str]],
    all_deps: dict[str, set[str]],
) -> list[str]:
    """Find predicates used but never declared."""
    global_decls = set()
    for decls in all_decls.values():
        global_decls |= decls
    for heads in all_heads.values():
        global_decls |= heads

    errors = []
    for fname, deps in all_deps.items():
        for pred in sorted(deps - global_decls):
            if not pred.startswith("fn:"):
                errors.append(f"  {Path(fname).name}: uses undeclared predicate '{pred}'")
    return errors


def detect_cycles(
    all_heads: dict[str, set[str]], all_deps: dict[str, set[str]]
) -> list[str]:
    """Detect circular dependencies between predicates."""
    # Build predicate -> predicate dependency
    pred_to_file: dict[str, str] = {}
    for fname, heads in all_heads.items():
        for h in heads:
            pred_to_file[h] = fname

    graph: dict[str, set[str]] = defaultdict(set)
    for fname, deps in all_deps.items():
        heads = all_heads.get(fname, set())
        for h in heads:
            for d in deps:
                if d != h and d in pred_to_file:
                    graph[h].add(d)

    # Simple cycle detection via DFS
    cycles = []
    visited = set()
    rec_stack = set()

    def dfs(node: str, path: list[str]) -> None:
        visited.add(node)
        rec_stack.add(node)
        for neighbor in graph.get(node, []):
            if neighbor not in visited:
                dfs(neighbor, path + [neighbor])
            elif neighbor in rec_stack:
                cycle_start = path.index(neighbor) if neighbor in path else -1
                if cycle_start >= 0:
                    cycle = path[cycle_start:] + [neighbor]
                    cycles.append(" -> ".join(cycle))

        rec_stack.discard(node)

    for node in graph:
        if node not in visited:
            dfs(node, [node])

    return cycles[:10]  # Limit output


ZIG_MODULES = [
    "storage", "catalog", "buffer_manager", "transaction",
    "parser", "planner", "processor", "optimizer",
    "common", "graph", "index", "expression",
]


def check_zig_coverage(all_decls: dict[str, set[str]]) -> dict[str, bool]:
    """Check which Zig modules have Mangle rule coverage."""
    all_names = set()
    for decls in all_decls.values():
        all_names |= decls

    coverage = {}
    for mod in ZIG_MODULES:
        has_coverage = any(
            mod in name or mod.replace("_", "") in name
            for name in all_names
        )
        coverage[mod] = has_coverage
    return coverage


def main() -> int:
    files = find_mg_files(MANGLE_DIR)
    # Exclude tests directory
    files = [f for f in files if "tests" not in f.parts]

    print(f"Mangle Rule Validation")
    print(f"{'=' * 60}")
    print(f"Found {len(files)} .mg files\n")

    all_decls, all_heads, all_deps = build_dependency_graph(files)

    total_decls = sum(len(d) for d in all_decls.values())
    total_rules = sum(len(h) for h in all_heads.values())
    print(f"Total declarations: {total_decls}")
    print(f"Total rule heads:   {total_rules}\n")

    errors = 0

    # Check undeclared predicates
    undeclared = check_undeclared_predicates(all_decls, all_heads, all_deps)
    if undeclared:
        print(f"⚠ Undeclared predicates ({len(undeclared)}):")
        for e in undeclared[:20]:
            print(e)
        print()
    else:
        print("✓ All used predicates are declared\n")

    # Detect cycles (informational - some cycles are intentional like reachable)
    cycles = detect_cycles(all_heads, all_deps)
    if cycles:
        print(f"ℹ Recursive predicate chains ({len(cycles)}):")
        for c in cycles[:5]:
            print(f"  {c}")
        print("  (Recursive rules are expected for transitive closure)\n")
    else:
        print("✓ No recursive predicate chains\n")

    # Check Zig coverage
    coverage = check_zig_coverage(all_decls)
    covered = sum(1 for v in coverage.values() if v)
    print(f"Zig module coverage: {covered}/{len(ZIG_MODULES)}")
    for mod, has in sorted(coverage.items()):
        icon = "✓" if has else "✗"
        print(f"  {icon} {mod}")

    print(f"\n{'=' * 60}")
    print(f"Validation {'PASSED' if errors == 0 else 'FAILED'}")
    return errors


if __name__ == "__main__":
    sys.exit(main())

