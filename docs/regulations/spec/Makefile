.PHONY: all clean validate

all: regulations-spec.pdf

regulations-spec.pdf: regulations-spec.tex chapters/*.tex
	tectonic -X compile regulations-spec.tex

validate:
	python3 ../structured/validate.py

clean:
	rm -f regulations-spec.pdf regulations-spec.log regulations-spec.aux \
	      regulations-spec.toc regulations-spec.lof regulations-spec.lot \
	      regulations-spec.out
