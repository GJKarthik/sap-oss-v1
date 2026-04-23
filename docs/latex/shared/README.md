# SAP-OSS LaTeX Style System - WWDC Quality Edition

Professional document styling inspired by Apple WWDC keynote presentations, featuring clean typography, generous whitespace, and modern visual elements.

## Quick Start

```latex
% Use the minimal class for simple documents
\documentclass{sap-oss-apple-minimal}

\title{Your Document Title}
\author{SCB GCFO, AI Research \& Development}
\date{April 2026}
\setdocsubtitle{Document subtitle here}
\setdocref{DOC-REF-001}
\setdocversion{1.0.0}

\begin{document}
\makesaptitle
\tableofcontents
\clearpage

\chapter{Introduction}
Your content here...

\makecolophon{Colophon text here}
\end{document}
```

## Available Classes

### `sap-oss-apple-minimal.cls` (Recommended)

A self-contained, minimal document class with WWDC-inspired styling. Includes:
- Inter font family with fallbacks to Helvetica/Helvetica Neue
- JetBrains Mono for code with fallbacks to Menlo/Monaco
- Professional color palette based on Apple's design system
- All box environments (adrbox, infobox, warningbox, etc.)
- Clean headers and footers
- Title page generation
- Colophon page support

**Usage:** `\documentclass{sap-oss-apple-minimal}`

### `sap-oss-apple.cls` (Advanced)

Full-featured class with modular style packages. Use for complex customization needs.

**Usage:** `\documentclass[fontsize=11pt,paper=a4paper]{sap-oss-apple}`

## Color Palette

| Color Name | RGB | Usage |
|------------|-----|-------|
| `sapblue` | (0, 100, 215) | Primary accent, links, chapter numbers |
| `appleblack` | (29, 29, 31) | Body text, headings |
| `applegray1` | (99, 99, 102) | Secondary text, subsection numbers |
| `applegray2` | (142, 142, 147) | Page numbers, headers |
| `applegray3` | (199, 199, 204) | Borders, rules |
| `applegreen` | (52, 199, 89) | Success states |
| `appleorange` | (255, 149, 0) | Warnings |
| `applered` | (255, 59, 48) | Critical/errors |
| `applepurple` | (175, 82, 222) | States, decorative |

## Box Environments

### Decision/ADR Box
```latex
\begin{adrbox}[ADR-001: Architecture Decision]
Content describing the decision...
\end{adrbox}
```

### Information Box
```latex
\begin{infobox}[Key Information]
Important notes for the reader...
\end{infobox}
```

### Warning Box
```latex
\begin{warningbox}[Caution]
Warning content here...
\end{warningbox}
```

### Success Box
```latex
\begin{successbox}[Validation Passed]
Success message...
\end{successbox}
```

### Critical Box
```latex
\begin{criticalbox}[Breaking Change]
Critical information...
\end{criticalbox}
```

## Helper Commands

| Command | Usage | Example |
|---------|-------|---------|
| `\filepath{path}` | File/directory paths | `\filepath{src/main.py}` |
| `\artifact{name}` | Code artifacts | `\artifact{.clinerules}` |
| `\reqid{id}` | Requirement IDs | `\reqid{TB-REQ-ES01}` |
| `\corpus{ref}` | Corpus references | `\corpus{TB-BC-001}` |
| `\tool{name}` | Tool references | `\tool{xelatex}` |
| `\stateid{state}` | State identifiers | `\stateid{COMPLETED}` |
| `\enumval{value}` | Enum values | `\enumval{approved}` |
| `\fieldref{field}` | Field references | `\fieldref{variance_id}` |

## Compilation

These documents **must** be compiled with XeLaTeX for proper font support:

```bash
# Single compilation
xelatex document.tex

# Full compilation with TOC/references
xelatex document.tex && xelatex document.tex

# Using latexmk
latexmk -xelatex document.tex
```

## Typography

The WWDC-style typography features:

- **Inter** as the primary font (with Helvetica Neue/Helvetica fallback)
- **JetBrains Mono** for code (with Menlo/Monaco/Courier fallback)
- 1.35× line height for comfortable reading
- Generous paragraph spacing (1.1× baseline)
- No paragraph indentation (block style)
- Dramatic heading scale:
  - Chapter: Large + accent color prefix
  - Section: Large + blue number
  - Subsection: Large + gray number

## Page Layout

- A4 paper (210mm × 297mm)
- Generous margins: 28mm general, 35mm inner, 25mm outer
- Two-sided printing with `openright` chapters
- No headers on chapter opening pages
- Clean page numbers in header

## Files in This Directory

| File | Description |
|------|-------------|
| `sap-oss-apple-minimal.cls` | Self-contained minimal class (recommended) |
| `sap-oss-apple.cls` | Full-featured class with modular packages |
| `sap-oss-colors.sty` | Color definitions |
| `sap-oss-typography.sty` | Font and text styling |
| `sap-oss-boxes.sty` | Box environments (tcolorbox) |
| `sap-oss-listings.sty` | Code listing styles |
| `sap-oss-titlepage.sty` | Title page generation |

## Version

- **Version:** 2.0.0
- **Date:** April 2026
- **Author:** SCB GCFO, AI Research & Development

## License

Internal use only - SCB GCFO