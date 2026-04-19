# Build the Arabic AP Implementation Specification.
#
# Requires XeLaTeX (polyglossia + bidi) and an Arabic font in the
# system (Geeza Pro on macOS). Tectonic is preferred because it fetches
# LaTeX packages on demand.

TEX = arabic-ap-spec.tex
PDF = arabic-ap-spec.pdf

.PHONY: all clean tectonic xelatex

all: tectonic

tectonic:
	tectonic -X compile --keep-intermediates --keep-logs $(TEX)

xelatex:
	xelatex -interaction=nonstopmode $(TEX)
	xelatex -interaction=nonstopmode $(TEX)

clean:
	rm -f $(PDF) *.aux *.log *.out *.toc *.lof *.lot *.fdb_latexmk *.fls
