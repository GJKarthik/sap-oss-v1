.PHONY: all clean

all: tb-review-spec.pdf

tb-review-spec.pdf: tb-review-spec.tex chapters/*.tex
	tectonic -X compile tb-review-spec.tex

clean:
	rm -f tb-review-spec.pdf tb-review-spec.log tb-review-spec.aux \
	      tb-review-spec.toc tb-review-spec.lof tb-review-spec.lot \
	      tb-review-spec.out
