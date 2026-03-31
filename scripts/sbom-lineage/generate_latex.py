#!/usr/bin/env python3
"""
Generate LaTeX report from CycloneDX BOMs and lineage JSON.
Details everything: metadata, components (purl, type, license, description), dependencies, lineage.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BOMS_DIR = REPO_ROOT / "scripts" / "sbom-lineage" / "boms"
LINEAGE_PATH = REPO_ROOT / "scripts" / "sbom-lineage" / "lineage.json"
OUTPUT_TEX = REPO_ROOT / "docs" / "sbom-lineage.tex"


def slug(p: str) -> str:
    return p.replace("/", "-").strip()


def escape_tex(s: str) -> str:
    """Escape a string for use in LaTeX running text (section titles, etc.)."""
    if not s:
        return ""
    # Backslash must be first to avoid double-escaping
    s = s.replace("\\", "\\textbackslash{}")
    # Standard LaTeX special characters
    for c in "&%$#_{}":
        s = s.replace(c, "\\" + c)
    # Characters with named commands
    s = s.replace("~", "\\textasciitilde{}")
    s = s.replace("^", "\\textasciicircum{}")
    s = s.replace("<", "\\textless{}")
    s = s.replace(">", "\\textgreater{}")
    return s


def escape_table(s: str) -> str:
    """Escape a string for use inside a LaTeX table cell."""
    if not s:
        return "—"
    # Backslash first
    s = s.replace("\\", "\\textbackslash{}")
    s = s.replace("&", "\\&")
    s = s.replace("%", "\\%")
    s = s.replace("#", "\\#")
    s = s.replace("_", "\\_")
    s = s.replace("{", "\\{")
    s = s.replace("}", "\\}")
    s = s.replace("~", "\\textasciitilde{}")
    s = s.replace("^", "\\textasciicircum{}")
    s = s.replace("<", "\\textless{}")
    s = s.replace(">", "\\textgreater{}")
    return s


def license_str(comp: dict) -> str:
    lic = comp.get("licenses")
    if not lic:
        return "—"
    if isinstance(lic, list) and lic:
        first = lic[0]
        if isinstance(first, dict) and "license" in first:
            id_or_name = first["license"].get("id") or first["license"].get("name")
            return escape_table(id_or_name or "—")
        if isinstance(first, dict) and "id" in first:
            return escape_table(first.get("id") or "—")
    return "—"


def component_type(comp: dict) -> str:
    return escape_table(comp.get("type") or "library")


def sbom_section_from_cyclonedx(bom_path: Path, project_name: str) -> str:
    """Generate LaTeX subsection for one CycloneDX BOM."""
    with open(bom_path, encoding="utf-8") as f:
        bom = json.load(f)
    lines = []
    meta = bom.get("metadata") or {}
    ts = meta.get("timestamp") or ""
    tools = meta.get("tools") or []
    def tool_name(t):
        return t.get("name", "") if isinstance(t, dict) else str(t)
    tool_str = ", ".join(tool_name(t) for t in tools) if tools else ""
    spec = bom.get("specVersion") or "1.5"
    serial = bom.get("serialNumber") or ""

    lines.append(f"\\subsection{{{escape_tex(project_name)}}}")
    lines.append(f"\\textbf{{Path:}} \\texttt{{{escape_tex(bom_path.stem.replace('.cyclonedx', ''))}}}")
    lines.append(f"\\\\ \\textbf{{CycloneDX:}} spec {escape_tex(spec)}, serial \\texttt{{{escape_table(serial[:60])}...}}")
    if ts:
        lines.append(f"\\\\ \\textbf{{Generated:}} {escape_table(ts)}")
    if tool_str:
        lines.append(f"\\\\ \\textbf{{Tool:}} {escape_table(tool_str)}")
    lines.append("")
    # --- component table -------------------------------------------------------
    # Column spec: Name(p4cm) | Version(p2cm) | Type(p1.6cm) | purl(p5cm) | Lic(p1.5cm) | Desc(p3.5cm)
    COL_SPEC = "|p{4cm}|p{2cm}|p{1.6cm}|p{5cm}|p{1.5cm}|p{3.5cm}|"
    HDR = (
        "\\rowcolor{sbomhdr}\\textbf{Name} & \\textbf{Version} & "
        "\\textbf{Type} & \\textbf{purl} & \\textbf{License} & \\textbf{Description} \\\\"
    )
    lines.append("\\subsubsection*{Components}")
    lines.append(f"\\begin{{longtable}}{{{COL_SPEC}}}")
    lines.append("\\toprule")
    lines.append(HDR)
    lines.append("\\midrule")
    lines.append("\\endfirsthead")
    lines.append(f"\\multicolumn{{6}}{{l}}{{\\small\\itshape (continued from previous page)}} \\\\")
    lines.append("\\toprule")
    lines.append(HDR)
    lines.append("\\midrule")
    lines.append("\\endhead")
    lines.append("\\midrule")
    lines.append(f"\\multicolumn{{6}}{{r}}{{\\small\\itshape (continued on next page)}} \\\\")
    lines.append("\\endfoot")
    lines.append("\\bottomrule")
    lines.append("\\endlastfoot")
    components = bom.get("components") or []
    for c in components:
        bref = (c.get("bom-ref") or "").lower()
        if bref == "root-component" or "root" in bref:
            continue
        name = escape_table(c.get("name") or "")
        version = escape_table(c.get("version") or "—")
        ctype = component_type(c)
        # Decode %40 → @ and %2F → / for readability, then escape
        raw_purl = (c.get("purl") or "—")
        try:
            from urllib.parse import unquote
            raw_purl = unquote(raw_purl)
        except Exception:
            pass
        purl = escape_table(raw_purl[:80])
        lic = license_str(c)
        desc = escape_table((c.get("description") or "—")[:65])
        lines.append(f"\\raggedright {name} & {version} & {ctype} & \\small\\texttt{{{purl}}} & {lic} & \\small {desc} \\\\")
    lines.append("\\end{longtable}")
    # --- dependency graph -------------------------------------------------------
    deps = bom.get("dependencies") or []
    if deps:
        lines.append("")
        lines.append("\\subsubsection*{Dependency graph (top-level refs)}")
        lines.append("\\begin{lstlisting}[style=depgraph]")
        for d in deps[:30]:
            ref = d.get("ref", "")
            dep_on = d.get("dependsOn") or []
            suffix = "..." if len(dep_on) > 5 else ""
            lines.append(f"  {ref}")
            lines.append(f"    -> {', '.join(dep_on[:5])}{suffix}")
        lines.append("\\end{lstlisting}")
    lines.append("")
    return "\n".join(lines)


def lineage_section(lineage_data: dict, max_commits: int) -> str:
    services = (lineage_data.get("lineage") or {}).get("services") or []
    lines = ["\\section{Change Lineage from Original Software}", ""]
    for svc in services:
        name = escape_tex(svc.get("name") or svc.get("path", ""))
        path = escape_tex(svc.get("path", ""))
        upstream = (svc.get("upstream") or "").strip()
        commits = svc.get("commits") or []
        lines.append(f"\\subsection{{{name}}}")
        lines.append(f"\\textbf{{Path:}} \\texttt{{{path}}}")
        if upstream:
            url_safe = upstream.replace("\\", "/").replace("#", "\\#")
            lines.append(f"\\\\ \\textbf{{Upstream:}} \\url{{{url_safe}}}")
        lines.append("")
        lines.append("\\textbf{Changes (from git history):}")
        lines.append("\\begin{longtable}{|p{2.2cm}|p{3.2cm}|l|p{6cm}|}")
        lines.append("\\hline \\textbf{Hash} & \\textbf{Date} & \\textbf{Author} & \\textbf{Subject} \\\\ \\hline \\endfirsthead")
        lines.append("\\hline \\textbf{Hash} & \\textbf{Date} & \\textbf{Author} & \\textbf{Subject} \\\\ \\hline \\endhead")
        for c in commits[:max_commits]:
            h = escape_table(c.get("hash") or "")
            d = escape_table(c.get("date") or "")
            a = escape_table(c.get("author") or "")
            subj = escape_table((c.get("subject") or "")[:70])
            lines.append(f"\\texttt{{{h}}} & {d} & {a} & {subj} \\\\")
        lines.append("\\hline")
        if len(commits) > max_commits:
            lines.append(f"\\multicolumn{{4}}{{r}}{{... and {len(commits) - max_commits} more.}} \\\\ \\hline")
        lines.append("\\end{longtable}")
        lines.append("\\textit{Full:} \\texttt{git log --follow -- " + path + "}")
        lines.append("")
    return "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--boms-dir", type=Path, default=BOMS_DIR)
    p.add_argument("--lineage", type=Path, default=LINEAGE_PATH)
    p.add_argument("--output", type=Path, default=OUTPUT_TEX)
    p.add_argument("--title", default="Software Bill of Materials (CycloneDX) and Change Lineage")
    p.add_argument("--max-commits", type=int, default=50)
    p.add_argument("--service", help="Service path (as in manifest) to generate a single-service report for")
    args = p.parse_args()
    # Map BOM file stem (e.g. training-console) to display name from lineage
    lineage_data = {}
    if args.lineage.exists():
        with open(args.lineage, encoding="utf-8") as f:
            lineage_data = json.load(f)
    if args.service:
        svc_path = args.service
        services = (lineage_data.get("lineage") or {}).get("services") or []
        services = [s for s in services if s.get("path") == svc_path]
        lineage_data = {"lineage": {"services": services}}
    name_by_path = {}
    for svc in (lineage_data.get("lineage") or {}).get("services") or []:
        name_by_path[svc.get("path", "")] = svc.get("name") or svc.get("path", "")
    doc = [
        "\\documentclass[11pt,a4paper]{article}",
        "\\usepackage[utf8]{inputenc}",
        "\\usepackage[T1]{fontenc}",
        "\\usepackage{lmodern}",
        "\\usepackage{microtype}",           # better text justification / hyphenation
        "\\usepackage{url}",
        "\\usepackage{longtable}",
        "\\usepackage{booktabs}",            # \\toprule, \\midrule, \\bottomrule
        "\\usepackage{array}",               # extended column specs
        "\\usepackage{xcolor}",              # \\rowcolor
        "\\usepackage{listings}",            # code/dep-graph blocks
        "\\usepackage{hyperref}",
        "\\usepackage{geometry}",
        "\\usepackage{fancyhdr}",
        "\\geometry{margin=2cm,top=2.5cm,bottom=2.5cm}",
        # Table colour
        "\\definecolor{sbomhdr}{RGB}{220,230,242}",
        "\\definecolor{depgraphbg}{RGB}{248,248,248}",
        # longtable width helper
        "\\setlength{\\LTcapwidth}{\\textwidth}",
        # listings style for dependency graphs
        "\\lstdefinestyle{depgraph}{",
        "  backgroundcolor=\\color{depgraphbg},",
        "  basicstyle=\\ttfamily\\small,",
        "  breaklines=true,",
        "  breakatwhitespace=true,",
        "  breakindent=2em,",
        "  columns=fullflexible,",
        "  keepspaces=true,",
        "  frame=single,",
        "  rulecolor=\\color{gray!40},",
        "  xleftmargin=0.5em,",
        "  xrightmargin=0.5em,",
        "}",
        # hyperref config
        "\\hypersetup{colorlinks=true,linkcolor=blue!60!black,urlcolor=blue!70!black}",
        f"\\title{{\\textbf{{{escape_tex(args.title)}}}}}",
        "\\author{Generated from CycloneDX SBOM and git lineage}",
        "\\date{\\today}",
        "\\pagestyle{fancy}",
        "\\fancyhf{}",
        "\\fancyhead[L]{\\small\\textit{SAP OSS — SBOM \\& Lineage Report}}",
        "\\fancyhead[R]{\\small\\today}",
        "\\fancyfoot[C]{\\thepage}",
        "\\renewcommand{\\headrulewidth}{0.4pt}",
        "\\begin{document}",
        "\\maketitle",
        "\\tableofcontents",
        "\\newpage",
        "\\section{Software Bill of Materials (CycloneDX)}",
        "Each subsection is generated from a CycloneDX~1.5 BOM "
        "(components, purl, license, dependency graph). "
        "Package URLs (purls) follow the \\href{https://github.com/package-url/purl-spec}{PURL spec}.",
        "",
    ]
    for bom_file in sorted(args.boms_dir.glob("*.cyclonedx.json")):
        stem = bom_file.stem.replace(".cyclonedx", "")
        if args.service and stem != slug(args.service):
            continue
        project_name = name_by_path.get(stem) or stem.replace("-", " ").title()
        doc.append(sbom_section_from_cyclonedx(bom_file, project_name))
    doc.append("\\newpage")
    doc.append(lineage_section(lineage_data, args.max_commits))
    doc.append("\\end{document}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(doc), encoding="utf-8")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
