# Diagram workflow

Specs use a **hybrid Mermaid pipeline**: `.mmd` source files live alongside the
pre-rendered `.pdf` outputs, both committed to git.

## Layout

```
docs/latex/
├── Makefile                        # build targets
├── shared/
│   ├── mermaid-theme.json          # SAP/Apple palette, Inter/JBM fonts
│   └── diagrams/                   # diagrams used by test-apple.tex
└── specs/
    ├── simula/diagrams/            # *.mmd + *.pdf
    └── clinerules-agents/diagrams/ # *.mmd + *.pdf
```

## Editing a diagram

1. Edit the `.mmd` file (standard Mermaid syntax — flowchart, sequence, gantt, class, etc.).
2. Run `make diagrams` from `docs/latex/`. On first run, `npx` downloads `@mermaid-js/mermaid-cli` (~250 MB, includes headless Chromium). Subsequent runs reuse the cached copy.
3. Commit both the `.mmd` source and the regenerated `.pdf`.

## Adding a new diagram

1. Create `specs/<spec>/diagrams/<name>.mmd`.
2. Reference it from a chapter with the `\mermaidfig` helper:

   ```latex
   \mermaidfig{diagrams/<name>}{Caption text.}{fig:<name>}
   ```

   The helper expands to a proper `figure` environment with `\caption` and
   `\label`, so you can cross-reference with `\cref{fig:<name>}` → "Figure X.Y".

## Theme

`shared/mermaid-theme.json` encodes the Apple-style palette:

| Role            | Hex       | Notes                       |
|-----------------|-----------|-----------------------------|
| Primary         | `#0064D7` | SAP blue (node borders)     |
| Primary fill    | `#E8F0FC` | Soft blue node background   |
| Text            | `#1D1D1F` | Apple appleblack            |
| Edge / line     | `#636366` | Apple applegray1            |
| Note            | `#FF9500` | Apple appleorange border    |
| Critical / done | `#FF3B30` | Apple applered              |
| Active          | `#34C759` | Apple applegreen            |
| Font            | Inter     | Matches body typography     |

Tweak values in `mermaid-theme.json` and rerun `make diagrams` to re-render everything.

## Build targets

| Target                | What it does                                                 |
|-----------------------|--------------------------------------------------------------|
| `make diagrams`       | `mmdc` every `.mmd` that is newer than its `.pdf`            |
| `make pdf`            | Both specs → PDF (runs `make diagrams` first)                |
| `make pdf-simula`     | Simula only: xelatex + biber + 2×xelatex                     |
| `make pdf-clinerules` | Clinerules-agents only: xelatex ×2                           |
| `make docx`           | Both specs → DOCX via pandoc                                 |
| `make all`            | diagrams + pdf + docx                                        |
| `make clean`          | Remove `.aux .toc .out .log .bbl .blg` etc.                  |
| `make distclean`      | `clean` + remove generated PDFs and DOCX                     |

## CI note

The pre-rendered `.pdf` files are checked in so CI doesn't need Node or Chromium.
Only developers editing diagrams need `npx` / `mermaid-cli`.
