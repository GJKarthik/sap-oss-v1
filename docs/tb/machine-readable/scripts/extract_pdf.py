#!/usr/bin/env python3
"""
Extract text and BPMN structure from the TB review PDF.

Uses pdfplumber for text extraction with coordinate-based parsing
to identify BPMN elements (tasks, gateways, events, data objects).
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import pdfplumber

TB_DIR = Path(__file__).resolve().parent.parent.parent  # docs/tb/
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "extracted"

PDF_FILE = "Operation of Month End Close Controls  - Trial Balance Review - GLO (1).pdf"


def extract_pdf_text(filepath: Path) -> list:
    """Extract text blocks with coordinates from each page."""
    pages = []
    with pdfplumber.open(str(filepath)) as pdf:
        for i, page in enumerate(pdf.pages):
            text = page.extract_text() or ""
            words = page.extract_words() or []
            tables = page.extract_tables() or []
            pages.append({
                "page_number": i + 1,
                "width": page.width,
                "height": page.height,
                "text": text,
                "word_count": len(text.split()),
                "tables": tables,
                "word_positions": [
                    {"text": w["text"], "x0": w["x0"], "y0": w["top"], "x1": w["x1"], "y1": w["bottom"]}
                    for w in words[:500]  # cap for large pages
                ]
            })
    return pages


def parse_bpmn_elements(full_text: str) -> dict:
    """Parse BPMN elements from extracted text using keyword patterns."""
    lines = [l.strip() for l in full_text.split("\n") if l.strip()]

    elements = {
        "tasks": [],
        "gateways": [],
        "events": [],
        "data_objects": [],
        "participants": [],
        "systems": set(),
    }

    # Known BPMN task keywords from TB review process
    task_keywords = [
        "Roll Forward", "Download PSGL", "Update Accounts Master",
        "Update Parameters", "Extract Trial Balance", "Update TB Details",
        "Calculate Variance", "Filter Variances", "Seek Commentaries",
        "Receive Commentaries", "Update Commentaries", "Update Variance",
        "Send Request to Post Journal", "Check with Respective Team",
        "Track Entries", "Update Risk", "Categorize Unexplained",
        "Prepare Summary", "Send For Internal Review", "Review Internally",
        "Send Summary for Inclusion", "Check for Material", "Check for Unexplained",
        "Is the Journal Posted", "Check if Further Investigation",
        "Check if Confirmation"
    ]

    gateway_keywords = [
        "Material", "Unexplained", "Journal Posted", "Further Investigation",
        "Confirmation", "Entries Status"
    ]

    system_keywords = [
        "MS Excel", "MS Outlook", "Shared Drive", "SC Bridge", "PSGL",
        "MS-E-xcel", "MS-Outlook"
    ]

    event_keywords = [
        "Prepare Schedule", "work day", "FORTM Pack", "Summary Sent"
    ]

    for line in lines:
        # Detect systems
        for sys_kw in system_keywords:
            if sys_kw.lower() in line.lower():
                clean_name = sys_kw.replace("MS-E-xcel", "MS Excel").replace("MS-Outlook", "MS Outlook")
                elements["systems"].add(clean_name)

        # Detect tasks
        for kw in task_keywords:
            if kw.lower() in line.lower():
                elements["tasks"].append(line)
                break

        # Detect gateways
        for kw in gateway_keywords:
            if kw.lower() in line.lower() and ("?" in line or "check" in line.lower()):
                elements["gateways"].append(line)
                break

        # Detect events
        for kw in event_keywords:
            if kw.lower() in line.lower():
                elements["events"].append(line)
                break

    elements["systems"] = sorted(elements["systems"])

    # Deduplicate
    elements["tasks"] = list(dict.fromkeys(elements["tasks"]))
    elements["gateways"] = list(dict.fromkeys(elements["gateways"]))
    elements["events"] = list(dict.fromkeys(elements["events"]))

    return elements


def build_markdown(pages: list, bpmn_elements: dict) -> str:
    """Build Markdown from extracted content."""
    md = []
    md.append("# Trial Balance Review - Month End Close Controls (GLO)")
    md.append("")
    md.append("## Document Metadata")
    md.append("")
    md.append("- **Process**: Operation of Month End Close Controls - Trial Balance Review")
    md.append("- **Scope**: GLO (Global)")
    md.append("- **Type**: BPMN Process Diagram")
    md.append(f"- **Pages**: {len(pages)}")
    md.append("")

    # Full text
    md.append("## Extracted Text")
    md.append("")
    for page in pages:
        md.append(f"### Page {page['page_number']}")
        md.append("")
        md.append(page["text"])
        md.append("")

    # BPMN structure
    md.append("## BPMN Elements (Parsed)")
    md.append("")

    if bpmn_elements["tasks"]:
        md.append("### Tasks")
        md.append("")
        for task in bpmn_elements["tasks"]:
            md.append(f"- {task}")
        md.append("")

    if bpmn_elements["gateways"]:
        md.append("### Gateways (Decision Points)")
        md.append("")
        for gw in bpmn_elements["gateways"]:
            md.append(f"- {gw}")
        md.append("")

    if bpmn_elements["events"]:
        md.append("### Events")
        md.append("")
        for ev in bpmn_elements["events"]:
            md.append(f"- {ev}")
        md.append("")

    if bpmn_elements["systems"]:
        md.append("### Systems / Data Objects")
        md.append("")
        for sys in bpmn_elements["systems"]:
            md.append(f"- {sys}")
        md.append("")

    # Tables
    for page in pages:
        if page["tables"]:
            md.append(f"### Tables (Page {page['page_number']})")
            md.append("")
            for ti, table in enumerate(page["tables"]):
                md.append(f"**Table {ti + 1}:**")
                md.append("")
                for row in table:
                    cells = [str(c or "").strip() for c in row]
                    md.append("| " + " | ".join(cells) + " |")
                md.append("")

    return "\n".join(md)


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    src_path = TB_DIR / PDF_FILE

    if not src_path.exists():
        print(f"[ERROR] PDF not found: {src_path}")
        return

    print("=" * 60)
    print("PDF BPMN Extraction")
    print("=" * 60)
    print(f"\nProcessing: {PDF_FILE}")

    pages = extract_pdf_text(src_path)
    total_words = sum(p["word_count"] for p in pages)
    print(f"  Pages: {len(pages)}, Words: {total_words}")

    full_text = "\n".join(p["text"] for p in pages)
    bpmn_elements = parse_bpmn_elements(full_text)
    print(f"  Tasks: {len(bpmn_elements['tasks'])}")
    print(f"  Gateways: {len(bpmn_elements['gateways'])}")
    print(f"  Systems: {len(bpmn_elements['systems'])}")

    md_content = build_markdown(pages, bpmn_elements)

    # Write with frontmatter
    output_path = OUTPUT_DIR / "bpmn-tb-review-glo.md"
    frontmatter = f"""---
source_file: '{PDF_FILE}'
source_type: 'pdf'
extracted_at: '{datetime.now(timezone.utc).isoformat()}'
word_count: {total_words}
page_count: {len(pages)}
bpmn_tasks: {len(bpmn_elements['tasks'])}
bpmn_gateways: {len(bpmn_elements['gateways'])}
bpmn_systems: {len(bpmn_elements['systems'])}
---

"""
    output_path.write_text(frontmatter + md_content, encoding="utf-8")
    print(f"  -> {output_path}")

    # Also save raw BPMN structure as JSON for workflow builder
    bpmn_json_path = OUTPUT_DIR / "bpmn-elements.json"
    with open(bpmn_json_path, "w") as f:
        json.dump(bpmn_elements, f, indent=2, ensure_ascii=False)
    print(f"  -> {bpmn_json_path}")

    print("\nDone.")


if __name__ == "__main__":
    main()
