% =============================================================================
% SAP-OSS Apple Document Class - WWDC Keynote Quality
% Version: 2.0.0
% Professional document class with Apple-style typography and layout
% Author: SCB GCFO, AI Research & Development
% =============================================================================
\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{sap-oss-apple}[2026/04/21 SAP-OSS Apple-Style Document Class v2.1.0]
% Note: this class uses `remember picture,overlay' TikZ overlays in chapter
% openers and a sourcequotebox overlay. Run xelatex TWICE to resolve
% overlay positions correctly.

% -----------------------------------------------------------------------------
% CLASS OPTIONS
% -----------------------------------------------------------------------------
\RequirePackage{kvoptions}
\SetupKeyvalOptions{family=saposs,prefix=saposs@}

% Paper size options
\DeclareStringOption[a4paper]{paper}

% Font size options - 10pt by default per WWDC spec body-text policy.
\DeclareStringOption[10pt]{fontsize}

% One-sided or two-sided
\DeclareBoolOption[true]{twoside}

% Show chapter numbers
\DeclareBoolOption[true]{chapternumbers}

% Include draft watermark
\DeclareBoolOption[false]{draft}

% Process options
\ProcessKeyvalOptions*

% -----------------------------------------------------------------------------
% BASE CLASS
% -----------------------------------------------------------------------------
\ifsaposs@twoside
  \LoadClass[\saposs@fontsize,\saposs@paper,twoside,openright]{report}
\else
  \LoadClass[\saposs@fontsize,\saposs@paper,oneside]{report}
\fi

% -----------------------------------------------------------------------------
% REQUIRED PACKAGES
% -----------------------------------------------------------------------------
\RequirePackage{etoolbox}
\RequirePackage{xparse}

% Page geometry - WWDC style: more breathing room
\RequirePackage[
  \saposs@paper,
  margin=28mm,
  inner=35mm,
  outer=25mm,
  top=35mm,
  bottom=30mm,
  headheight=14pt,
  headsep=16pt,
  footskip=24pt
]{geometry}

% Core packages
\RequirePackage{graphicx}
\RequirePackage{xcolor}

% -----------------------------------------------------------------------------
% LOAD SAP-OSS STYLE PACKAGES (EARLY - COLORS FIRST)
% -----------------------------------------------------------------------------
% Add the shared directory to the input path
\makeatletter
\def\input@path{{../../shared/}}
\makeatother

% Load colors first (required by other packages)
\RequirePackage{sap-oss-colors}

% Define link colors for hyperref
\colorlet{linkcolor}{sapblue}
\colorlet{urlcolor}{sapblue}
\colorlet{citecolor}{applegray1}

% Now load TikZ
\RequirePackage{tikz}
\usetikzlibrary{calc,positioning,shapes.geometric,fit,arrows.meta,backgrounds,chains,decorations.pathmorphing,shadows}

% Tables
\RequirePackage{booktabs}
\RequirePackage{tabularx}
\RequirePackage{longtable}
\RequirePackage{array}
\RequirePackage{multirow}
\RequirePackage{colortbl}

% Lists
\RequirePackage{enumitem}

% Math
\RequirePackage{amsmath}
\RequirePackage{amssymb}

% URLs and hyperlinks (after colors are defined)
\RequirePackage[hyphens]{url}
\RequirePackage[
  colorlinks=true,
  linkcolor=linkcolor,
  urlcolor=urlcolor,
  citecolor=citecolor,
  bookmarks=true,
  bookmarksnumbered=true,
  pdfencoding=auto,
  psdextra
]{hyperref}

% Cross-references
\RequirePackage[capitalize,noabbrev]{cleveref}

% Load remaining SAP-OSS style packages
\RequirePackage{sap-oss-typography}
\RequirePackage{sap-oss-boxes}
\RequirePackage{sap-oss-listings}
\RequirePackage{sap-oss-titlepage}

% -----------------------------------------------------------------------------
% PAGE LAYOUT - WWDC BREATHING ROOM
% -----------------------------------------------------------------------------
\raggedbottom

% Prevent widows and orphans
\widowpenalty=10000
\clubpenalty=10000

% Keynote-deck breathing room: typography.sty now uses \linespread{1.35} so
% we match with a full-baselineskip parskip per reviewer. Paragraph indent
% stays at 0pt (Apple-style: space, not indent, signals paragraph break).
\setlength{\parskip}{1\baselineskip}
\setlength{\parindent}{0pt}

% Micro-typography: single-space sentences, soften hyphenation (Apple rarely
% hyphenates), generous emergency stretch. microtype protrusion is loaded
% via sap-oss-typography.sty.
\frenchspacing
\hyphenpenalty=400
\exhyphenpenalty=200
\setlength{\emergencystretch}{5em}
\tolerance=1200
\hbadness=10000

% -----------------------------------------------------------------------------
% HEADERS AND FOOTERS - WWDC BREADCRUMB STYLE
% -----------------------------------------------------------------------------
\RequirePackage{fancyhdr}

% Clear all headers/footers
\fancyhf{}

% Plain style (chapter opening pages)
\fancypagestyle{plain}{%
  \fancyhf{}
  \fancyfoot[C]{}
  \renewcommand{\headrulewidth}{0pt}
  \renewcommand{\footrulewidth}{0pt}
}

% -----------------------------------------------------------------------------
% BREADCRUMB NAVIGATION - true hierarchical breadcrumb across the spread.
% Verso: <Root> > <Chapter>     Recto: <Chapter> > <Section>
% Override root label per-document with \setbreadcrumbroot{Short Label}.
% Storage macro has no @ so it survives fancyhdr shipout expansion.
% -----------------------------------------------------------------------------
% Root is opt-in via \setbreadcrumbroot{...}. When unset, verso falls back
% to just the chapter name so specs without a \title{} still look correct.
\def\breadcrumbroottext{}
% Track whether root was explicitly set. Using a \newif conditional avoids
% \@empty comparisons which break at shipout time (@ not a letter).
\newif\ifbreadcrumbrootset
\newcommand{\setbreadcrumbroot}[1]{%
  \def\breadcrumbroottext{#1}\breadcrumbrootsettrue}
\newcommand{\breadcrumbsep}{\,{\color{applegray3}\guilsinglright}\,}

% Main style - WWDC breadcrumb headers (two-sided by default)
\fancypagestyle{main}{%
  \fancyhf{}
  % Verso: <Root> > <Chapter>  (root omitted if not set)
  \fancyhead[LE]{\small\color{applegray2}%
    \ifbreadcrumbrootset\breadcrumbroottext\breadcrumbsep\fi\leftmark}
  % Recto: <Chapter> > <Section>  (collapses to just chapter before first section)
  \fancyhead[RO]{\small\color{applegray2}%
    \leftmark\ifx\rightmark\leftmark\else\breadcrumbsep\rightmark\fi}
  \fancyhead[RE,LO]{}
  % Footer with styled page numbers
  \fancyfoot[RO]{\small\color{applegray2}\thepage\hspace{8pt}{\color{applegray3}\rule{20pt}{0.5pt}}}
  \fancyfoot[LE]{{\color{applegray3}\rule{20pt}{0.5pt}}\hspace{8pt}\small\color{applegray2}\thepage}
  % Rules
  \renewcommand{\headrulewidth}{0pt}
  \renewcommand{\footrulewidth}{0pt}
}

% Apply main style
\pagestyle{main}

% Header content formatting - chapter feeds \leftmark, section feeds \rightmark.
\renewcommand{\chaptermark}[1]{%
  \markboth{#1}{}%
}
\renewcommand{\sectionmark}[1]{%
  \markright{#1}%
}

% -----------------------------------------------------------------------------
% CHAPTER FORMATTING - WWDC DRAMATIC STYLE
% -----------------------------------------------------------------------------
\RequirePackage{titlesec}

% Chapter format - dramatic WWDC-style chapter openers with a subtle
% full-width sapblue!3 gradient band behind a large faded chapter number,
% then a tracked "CHAPTER N" kicker and the chapter title in semibold.
% Mirrors the minimal class for visual consistency across the suite.
\titleformat{\chapter}[display]
  {\normalfont\thispagestyle{plain}}
  {% Hero band + faded chapter number
    \begin{tikzpicture}[remember picture,overlay]
      \fill[sapblue!3]
        ([yshift=-20pt]current page.north west)
        rectangle
        ([yshift=-170pt]current page.north east);
      \node[anchor=north west,
            font=\fontseries{b}\selectfont\fontsize{110}{110}\selectfont,
            text=applegray4,
            inner sep=0pt]
        at ([xshift=30mm,yshift=-18mm]current page.north west |- 0,0)
        {\thechapter};
    \end{tikzpicture}%
    \vspace{20pt}%
    {\color{sapblue}\fontsize{14}{16}\selectfont\addfontfeature{LetterSpace=10.0}CHAPTER \thechapter}%
  }
  {20pt}
  {\fontsize{36}{42}\selectfont\fontseries{sb}\selectfont\color{appleblack}}
  [\vspace{16pt}{\color{sapblue}\rule{60pt}{2.5pt}}\vspace{30pt}]

\titlespacing*{\chapter}{0pt}{60pt}{40pt}

% Section formats - more dramatic scale
\titleformat{\section}
  {\normalfont\fontsize{24}{28}\selectfont\fontseries{sb}\selectfont\color{appleblack}}
  {\color{sapblue}\thesection}
  {14pt}
  {}

\titlespacing*{\section}{0pt}{36pt}{18pt}

\titleformat{\subsection}
  {\normalfont\fontsize{18}{22}\selectfont\fontseries{sb}\selectfont\color{appleblack}}
  {\color{applegray1}\thesubsection}
  {12pt}
  {}

\titlespacing*{\subsection}{0pt}{28pt}{12pt}

\titleformat{\subsubsection}
  {\normalfont\fontsize{14}{18}\selectfont\fontseries{sb}\selectfont\color{applegray1}}
  {\thesubsubsection}
  {10pt}
  {}

\titlespacing*{\subsubsection}{0pt}{20pt}{10pt}

\titleformat{\paragraph}[runin]
  {\normalfont\normalsize\bfseries\color{appleblack}}
  {}
  {0pt}
  {}
  [.\enskip]

\titlespacing*{\paragraph}{0pt}{14pt}{8pt}

% -----------------------------------------------------------------------------
% TABLE OF CONTENTS - CLEAN WWDC STYLE
% -----------------------------------------------------------------------------
\RequirePackage{titletoc}

% TOC title
\renewcommand{\contentsname}{Contents}

% Apple-HIG TOC: clean chapter lines with right-aligned page numbers, no
% leaders; sections and subsections use a thin dotted leader. "Chapter"
% prefix dropped so the eye tracks chapter titles first.
\titlecontents{chapter}
  [0pt]
  {\addvspace{18pt}\fontseries{sb}\selectfont\large\color{appleblack}}
  {\color{sapblue}\thecontentslabel\quad}
  {}
  {\hfill\color{applegray1}\contentspage}

\titlecontents{section}
  [24pt]
  {\addvspace{4pt}\color{appleblack}}
  {\thecontentslabel\quad}
  {}
  {\quad\titlerule*[10pt]{{\color{applegray3}.}}\color{applegray1}\contentspage}

\titlecontents{subsection}
  [48pt]
  {\small\color{applegray1}}
  {\thecontentslabel\quad}
  {}
  {\quad\titlerule*[10pt]{{\color{applegray3}.}}\contentspage}

% -----------------------------------------------------------------------------
% LISTS - WWDC SPACING
% -----------------------------------------------------------------------------
\setlist{
  topsep=10pt,
  itemsep=6pt,
  parsep=4pt,
  leftmargin=24pt
}

\setlist[itemize,1]{label={\color{sapblue}$\bullet$}}
\setlist[itemize,2]{label={\color{applegray1}$\circ$}}
\setlist[itemize,3]{label={\color{applegray2}--}}

\setlist[enumerate,1]{label={\color{sapblue}\arabic*.}}
\setlist[enumerate,2]{label={\color{applegray1}\alph*)}}
\setlist[enumerate,3]{label={\color{applegray2}\roman*)}}

% -----------------------------------------------------------------------------
% TABLES - WWDC MINIMAL STYLE (NO ALTERNATING ROWS)
% -----------------------------------------------------------------------------
% Table styling - clean, minimal
\renewcommand{\arraystretch}{1.5}

% Custom column types
\newcolumntype{L}[1]{>{\raggedright\arraybackslash}p{#1}}
\newcolumntype{C}[1]{>{\centering\arraybackslash}p{#1}}
\newcolumntype{R}[1]{>{\raggedleft\arraybackslash}p{#1}}

% NO alternating row colors - WWDC style
% \rowcolors{2}{tablerow1}{tablerow2}  % REMOVED

% Apple-style table environment. Body size matches main text (10pt) per
% keynote spec -- no \small wrapper.
\NewDocumentEnvironment{appletable}{m m}{%
  \begin{table}[htbp]
  \centering
  \setlength{\tabcolsep}{12pt}
  \renewcommand{\arraystretch}{1.4}
  \begin{tabular}{@{}#1@{}}
  \toprule[0.8pt]
}{%
  \bottomrule[0.8pt]
  \end{tabular}
  \caption{#2}
  \end{table}
}

% Apple-style table header helper: Semibold, tracked, uppercase.
% Used by metricstable and available for hand-rolled tables.
\newcommand{\metricshead}[1]{%
  {\fontseries{sb}\selectfont\addfontfeature{LetterSpace=4.0}\MakeUppercase{#1}}%
}

% Tabular lining figures: numerals at uniform width so numeric columns align.
\providecommand{\tabularfigures}{\addfontfeature{Numbers={Monospaced,Lining}}}

% Metrics table for evaluation results. Body size matches main text (10pt)
% per keynote spec; numerals are tabular lining for column alignment.
\NewDocumentEnvironment{metricstable}{m}{%
  \begin{table}[htbp]
  \centering
  \tabularfigures
  \setlength{\tabcolsep}{14pt}
  \renewcommand{\arraystretch}{1.5}
  \begin{tabular}{@{}llr@{}}
  \toprule[0.8pt]
  \metricshead{Metric} & \metricshead{Value} & \metricshead{Target} \\
  \midrule
}{%
  \bottomrule[0.8pt]
  \end{tabular}
  \caption{#1}
  \end{table}
}

% -----------------------------------------------------------------------------
% FIGURES
% -----------------------------------------------------------------------------
\RequirePackage{float}
\RequirePackage{caption}

\captionsetup{
  font={small,sf,color=applegray1},
  labelfont={bf,color=sapblue},
  labelsep=endash,
  format=plain,
  margin=24pt,
  skip=12pt
}

% More space before/after floats so figures breathe between paragraphs.
\setlength{\textfloatsep}{20pt plus 2pt minus 4pt}
\setlength{\intextsep}{20pt plus 2pt minus 4pt}
\setlength{\floatsep}{16pt plus 2pt minus 4pt}

% \mermaidfig{<path-without-ext>}{<caption>}{<label>}
% One-liner helper for Mermaid-rendered PDF diagrams. Expands to a full
% figure environment with \caption + \label, enabling \cref{fig:...}. The
% path is resolved relative to the spec's .tex file. Width is
% 0.85\textwidth by default; pass an optional width argument to override.
\NewDocumentCommand{\mermaidfig}{O{0.85\textwidth} m m m}{%
  \begin{figure}[htbp]%
    \centering
    \includegraphics[width=#1]{#2.pdf}%
    \caption{#3}%
    \label{#4}%
  \end{figure}%
}

% -----------------------------------------------------------------------------
% FOOTNOTES
% -----------------------------------------------------------------------------
\renewcommand{\footnoterule}{%
  \kern-3pt%
  {\color{applegray3}\hrule width 2in height 0.4pt}%
  \kern 2.6pt%
}

\renewcommand{\thefootnote}{\color{sapblue}\arabic{footnote}}

% -----------------------------------------------------------------------------
% BIBLIOGRAPHY
% -----------------------------------------------------------------------------
\AtBeginEnvironment{thebibliography}{%
  \small
  \setlength{\itemsep}{8pt}
}

% -----------------------------------------------------------------------------
% DRAFT MODE - disabled by default, add \draftmode to enable
% -----------------------------------------------------------------------------
% To enable draft watermark, add this to your document preamble:
% \RequirePackage{draftwatermark}
% \SetWatermarkText{DRAFT}
% \SetWatermarkScale{0.5}
% \SetWatermarkLightness{0.9}

% -----------------------------------------------------------------------------
% HELPER COMMANDS
% -----------------------------------------------------------------------------
% Path/code helpers wrap their argument in \detokenize so literal strings
% containing `_', `<', `>', `#', `&' etc. print safely without requiring the
% author to backslash-escape them. The argument must be a literal string
% (no macro expansion); this is the correct semantic for file paths, schema
% paths, identifiers and code references.
% File path
\providecommand{\filepath}[1]{%
  {\color{pathcolor}\faIcon{folder}\hspace{4pt}\texttt{\detokenize{#1}}}%
}

% Requirement ID
\newcommand{\reqid}[1]{%
  \textbf{\color{sapblue}\texttt{\detokenize{#1}}}%
}

% Corpus reference
\newcommand{\corpus}[1]{%
  \texttt{\color{applegray1}\detokenize{#1}}%
}

% Tool reference
\newcommand{\tool}[1]{%
  \texttt{\color{tealdark}\detokenize{#1}}%
}

% State ID
\newcommand{\stateid}[1]{%
  \textsc{\color{applepurple}\MakeLowercase{#1}}%
}

% Arabic text placeholder
\newcommand{\ar}[1]{#1}

% Schema path
\newcommand{\schemapath}[1]{%
  \texttt{\color{pathcolor}\detokenize{#1}}%
}

% Enum value
\newcommand{\enumval}[1]{%
  \texttt{\color{applegreen}\detokenize{#1}}%
}

% Field reference
\newcommand{\fieldref}[1]{%
  \texttt{\color{sapblue}\detokenize{#1}}%
}

% Source reference
\newcommand{\srcref}[1]{\texttt{\detokenize{#1}}}
\newcommand{\reqref}[1]{\texttt{#1}}
\newcommand{\specref}[1]{\texttt{#1}}
\newcommand{\schemaref}[1]{\texttt{#1}}
\newcommand{\gapref}[1]{\texttt{#1}}

% Artifact reference
\newcommand{\artifact}[1]{%
  \texttt{\color{sapblue}\detokenize{#1}}%
}

% Apple title (uppercase with tracking)
\newcommand{\appletitle}[1]{%
  {\addfontfeature{LetterSpace=12.0}\fontseries{m}\selectfont\MakeUppercase{#1}}%
}

% Key insight pull quote
\NewDocumentEnvironment{keyinsight}{m}{%
  \vspace{20pt}
  \begin{center}
  \begin{minipage}{0.85\textwidth}
  \color{sapblue}\rule{\textwidth}{2pt}
  \vspace{8pt}
  
  {\large\fontseries{sb}\selectfont\color{appleblack}#1}
  
  \vspace{4pt}
  \small\color{applegray1}
}{%
  
  \vspace{8pt}
  \color{sapblue}\rule{\textwidth}{2pt}
  \end{minipage}
  \end{center}
  \vspace{20pt}
}

% -----------------------------------------------------------------------------
% PDF METADATA
% -----------------------------------------------------------------------------
\AtBeginDocument{%
  \hypersetup{
    pdftitle={\@title},
    pdfauthor={SCB GCFO, AI Research \& Development},
    pdfcreator={XeLaTeX with sap-oss-apple class v2},
    pdfproducer={SCB GCFO Documentation Pipeline}
  }
}

% -----------------------------------------------------------------------------
% SOURCE QUOTE - enhanced keynote style overrides the boxes.sty default.
% Large faded quotation mark overlay gives WWDC pull-quote feel.
% -----------------------------------------------------------------------------
\renewtcolorbox{sourcequotebox}[1][Source]{
  enhanced,
  breakable,
  boxrule=0pt,
  arc=0pt,
  left=48pt,
  right=16pt,
  top=12pt,
  bottom=12pt,
  colback=applegray4!50,
  colframe=applegray3,
  borderline west={3pt}{0pt}{applegray2},
  fontupper=\itshape,
  before upper={\color{applegray1}},
  overlay={%
    \node[anchor=north west, text=sapblue!35,
          font=\fontseries{b}\selectfont\fontsize{48}{48}\selectfont,
          inner sep=0pt]
      at ([xshift=10pt,yshift=-6pt]frame.north west) {\textquotedblleft};
  },
}

% sourcequote environment routes through the enhanced sourcequotebox.
% boxes.sty only defines the sourcequotebox tcolorbox, not a sourcequote
% environment, so we define it fresh here (using \providecommand-style
% guard in case a future version of boxes.sty adds one).
\ifdefined\sourcequote\else
  \newenvironment{sourcequote}{\begin{sourcequotebox}}{\end{sourcequotebox}}
\fi

\endinput