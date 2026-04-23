#!/usr/bin/env perl
# =============================================================================
# expand-mermaidfig.pl --- in-place rewrite \mermaidfig calls to raw
# \begin{figure}...\end{figure} blocks that pandoc's LaTeX reader understands.
#
# Pandoc silently drops unknown commands like \mermaidfig (it does not load
# our .cls file), so the DOCX build must pre-expand them. This script runs
# over a throw-away mirror of the spec tree in the Makefile; it never touches
# the canonical source under docs/latex/specs/.
#
# Usage: perl expand-mermaidfig.pl file1.tex file2.tex ...
# =============================================================================
use strict;
use warnings;

for my $path (@ARGV) {
    open my $in, '<', $path or die "open $path: $!";
    local $/;
    my $body = <$in>;
    close $in;

    # Captures: [WIDTH]? {PATH} {CAPTION} {LABEL}
    # Caption may span multiple lines and contain nested {...}.
    $body =~ s{
        \\mermaidfig
        (?: \[ ([^\]]*) \] )?          # optional [WIDTH]
        \{ ([^{}]*) \}                 # {PATH}   - no braces inside
        \s* \%? \s* \n? \s*
        \{ ( (?: [^{}] | \{[^{}]*\} )* ) \}  # {CAPTION} - one level of nested
        \s* \%? \s* \n? \s*
        \{ ([^{}]*) \}                 # {LABEL}
    }{
        my ($w, $file, $caption, $label) = ($1, $2, $3, $4);
        $w = defined $w && length $w ? $w : '0.85\textwidth';
        "\\begin{figure}[htbp]\\centering\\includegraphics[width=$w]{$file.png}"
          . "\\caption{$caption}\\label{$label}\\end{figure}";
    }gsex;

    open my $out, '>', $path or die "write $path: $!";
    print $out $body;
    close $out;
}
