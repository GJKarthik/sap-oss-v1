#!/usr/bin/env python3
"""
Extract text from Word documents (.doc and .docx) into Markdown.

.doc files: uses antiword CLI (brew install antiword)
.docx files: uses python-docx with image extraction
"""

import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

TB_DIR = Path(__file__).resolve().parent.parent.parent  # docs/tb/
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "extracted"
IMAGE_DIR = OUTPUT_DIR / "doi-images"


def extract_doc(filepath: Path) -> str:
    """Extract text from a .doc file using antiword."""
    try:
        result = subprocess.run(
            ["antiword", str(filepath)],
            capture_output=True, text=True, check=True
        )
        return result.stdout
    except FileNotFoundError:
        print(f"[WARN] antiword not found, trying textract for {filepath.name}")
        try:
            import textract
            return textract.process(str(filepath)).decode("utf-8")
        except ImportError:
            print(f"[ERROR] Neither antiword nor textract available for .doc files")
            print(f"  Install: brew install antiword")
            sys.exit(1)


def extract_docx(filepath: Path) -> tuple:
    """Extract text and images from a .docx file using python-docx."""
    import docx
    from docx.opc.constants import RELATIONSHIP_TYPE as RT

    doc = docx.Document(str(filepath))
    lines = []
    image_count = 0

    IMAGE_DIR.mkdir(parents=True, exist_ok=True)

    for para in doc.paragraphs:
        style_name = para.style.name if para.style else ""
        text = para.text.strip()
        if not text:
            lines.append("")
            continue

        if "Heading 1" in style_name or "Title" in style_name:
            lines.append(f"# {text}")
        elif "Heading 2" in style_name:
            lines.append(f"## {text}")
        elif "Heading 3" in style_name:
            lines.append(f"### {text}")
        elif "Heading 4" in style_name:
            lines.append(f"#### {text}")
        elif style_name.startswith("List"):
            lines.append(f"- {text}")
        else:
            lines.append(text)

    # Extract images from relationships
    for rel in doc.part.rels.values():
        if "image" in rel.reltype:
            image_count += 1
            image_data = rel.target_part.blob
            ext = os.path.splitext(rel.target_ref)[1] or ".png"
            image_name = f"doi-image-{image_count:03d}{ext}"
            image_path = IMAGE_DIR / image_name
            with open(image_path, "wb") as f:
                f.write(image_data)
            # Insert image reference after first heading or at end
            lines.append(f"\n![{image_name}](doi-images/{image_name})")

    return "\n".join(lines), image_count


def text_to_markdown(raw_text: str) -> str:
    """Convert plain text to rough Markdown with heading detection."""
    lines = raw_text.split("\n")
    md_lines = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            md_lines.append("")
            continue

        # Heuristic: all-caps lines with >3 words are headings
        words = stripped.split()
        if (stripped.isupper() and len(words) >= 2 and len(stripped) < 100) or \
           (stripped.endswith(":") and len(words) <= 8 and len(stripped) < 80):
            md_lines.append(f"## {stripped}")
        else:
            md_lines.append(stripped)

    return "\n".join(md_lines)


def write_markdown(output_path: Path, content: str, source_file: str, word_count: int, extra_meta: dict = None):
    """Write Markdown file with YAML frontmatter."""
    meta = {
        "source_file": source_file,
        "source_type": "docx" if source_file.endswith(".docx") else "doc",
        "extracted_at": datetime.now(timezone.utc).isoformat(),
        "word_count": word_count,
    }
    if extra_meta:
        meta.update(extra_meta)

    frontmatter = "---\n"
    for k, v in meta.items():
        frontmatter += f"{k}: {repr(v) if isinstance(v, str) else v}\n"
    frontmatter += "---\n\n"

    output_path.write_text(frontmatter + content, encoding="utf-8")
    print(f"  -> {output_path} ({word_count} words)")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    doc_files = [
        ("Business case - Trial Balance (2).doc", "business-case-trial-balance.md"),
        ("Business case - BSS Risk Assessment (2).doc", "business-case-bss-risk-assessment.md"),
    ]
    docx_files = [
        ("DOI for Trial Balance Process .docx", "doi-trial-balance-process.md"),
    ]

    print("=" * 60)
    print("Word Document Extraction")
    print("=" * 60)

    # Extract .doc files
    for src_name, out_name in doc_files:
        src_path = TB_DIR / src_name
        if not src_path.exists():
            print(f"[SKIP] {src_name} not found")
            continue

        print(f"\nProcessing: {src_name}")
        raw_text = extract_doc(src_path)
        md_content = text_to_markdown(raw_text)
        word_count = len(md_content.split())
        write_markdown(OUTPUT_DIR / out_name, md_content, src_name, word_count)

    # Extract .docx files
    for src_name, out_name in docx_files:
        src_path = TB_DIR / src_name
        if not src_path.exists():
            print(f"[SKIP] {src_name} not found")
            continue

        print(f"\nProcessing: {src_name}")
        md_content, image_count = extract_docx(src_path)
        word_count = len(md_content.split())
        write_markdown(
            OUTPUT_DIR / out_name, md_content, src_name, word_count,
            extra_meta={"images_extracted": image_count}
        )

    print(f"\nDone. Output in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
