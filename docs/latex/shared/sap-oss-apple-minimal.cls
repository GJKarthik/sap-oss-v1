% =============================================================================
% SAP-OSS Apple Document Class - WWDC Quality Edition
% =============================================================================
\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{sap-oss-apple-minimal}[2026/04/21 SAP-OSS Apple-Style Document Class v9 WWDC+SF+µtype+Mermaid]
% Note: this class uses `remember picture,overlay' TikZ overlays in chapter
% openers. Run xelatex TWICE to resolve overlay positions correctly.

% Load base class - 10pt for technical documents
\LoadClass[10pt,a4paper,twoside,openright]{report}

% -----------------------------------------------------------------------------
% REQUIRED PACKAGES
% -----------------------------------------------------------------------------
\RequirePackage{etoolbox}
\RequirePackage{xparse}
\RequirePackage{calc}

% Micro-typography: XeTeX only supports protrusion (character hanging into
% the margin for optical edge alignment), which is the single most impactful
% micro-typography feature for pro-grade text.
\RequirePackage{microtype}
\microtypesetup{protrusion=true,expansion=false,tracking=false,kerning=false,spacing=false}

% Page geometry - generous margins for premium feel
\RequirePackage[
  a4paper,
  margin=25mm,
  inner=30mm,
  outer=22mm,
  top=30mm,
  bottom=28mm,
  headheight=14pt,
  headsep=20pt,
  footskip=24pt
]{geometry}

% Core packages
\RequirePackage{graphicx}
\RequirePackage{xcolor}
\RequirePackage{tikz}
\usetikzlibrary{calc,positioning,shapes.geometric,fit,arrows.meta,backgrounds,shadows.blur}

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

% Typography
\RequirePackage{fontspec}
\RequirePackage{fontawesome5}

% Code listings
\RequirePackage{listings}

% -----------------------------------------------------------------------------
% COLORS - WWDC PALETTE
% -----------------------------------------------------------------------------
\definecolor{sapblue}{RGB}{0, 100, 215}
\definecolor{appleblack}{RGB}{29, 29, 31}
\definecolor{applewhite}{RGB}{255, 255, 255}
\definecolor{applegray1}{RGB}{99, 99, 102}
\definecolor{applegray2}{RGB}{142, 142, 147}
\definecolor{applegray3}{RGB}{199, 199, 204}
\definecolor{applegray4}{RGB}{229, 229, 234}
\definecolor{applegreen}{RGB}{52, 199, 89}
\definecolor{appleorange}{RGB}{255, 149, 0}
\definecolor{applered}{RGB}{255, 59, 48}
\definecolor{applepurple}{RGB}{175, 82, 222}
\definecolor{appleteal}{RGB}{90, 200, 250}
\definecolor{tealdark}{RGB}{0, 128, 128}
\definecolor{pathcolor}{RGB}{0, 100, 215}
\definecolor{codebg}{RGB}{248, 248, 250}
\definecolor{shadowcolor}{RGB}{0, 0, 0}

% Link colors
\colorlet{linkcolor}{sapblue}
\colorlet{urlcolor}{sapblue}
\colorlet{citecolor}{applegray1}

% -----------------------------------------------------------------------------
% FONTS - SIMPLE SETUP
% -----------------------------------------------------------------------------
% Body face - Inter keeps body text crisp at 10pt; SF Text is optimised
% differently and is slightly less legible in long-form prose at this size.
\IfFontExistsTF{Inter}{%
  \setmainfont{Inter}[
    UprightFont = *-Regular,
    BoldFont = *-Bold,
    ItalicFont = *-Italic,
    BoldItalicFont = *-BoldItalic,
  ]
  \setsansfont{Inter}[
    UprightFont = *-Regular,
    BoldFont = *-Bold,
    ItalicFont = *-Italic,
    BoldItalicFont = *-BoldItalic,
  ]
}{%
  \IfFontExistsTF{Helvetica Neue}{%
    \setmainfont{Helvetica Neue}
    \setsansfont{Helvetica Neue}
  }{%
    \setmainfont{Helvetica}
    \setsansfont{Helvetica}
  }
}

% Display face - SF Pro Display is what Apple uses for keynotes and HIG.
% Used in titles, chapter openers, and section headings only.
\IfFontExistsTF{SF Pro Display}{%
  \newfontfamily\sfdisplay{SF Pro Display}
  \newfontfamily\sfdisplaylight{SF Pro Display}[UprightFont={* Light}]
  \newfontfamily\sfdisplaysemi{SF Pro Display}[UprightFont={* Semibold}]
  \newfontfamily\sfdisplaybold{SF Pro Display}[UprightFont={* Bold}]
}{%
  % Graceful fallback to Inter if SF Pro Display is not installed
  \let\sfdisplay\normalfont
  \let\sfdisplaylight\normalfont
  \let\sfdisplaysemi\bfseries
  \let\sfdisplaybold\bfseries
}

% SF Symbols access via SF Pro. SF Symbols ship inside the SF Pro font at
% Private Use Area codepoints (0x100000+). Use \sfsymbol{<hex-codepoint>}
% to insert one, e.g. \sfsymbol{100181} for the folder glyph.
% Codepoints are visible in the SF Symbols app: File > Copy as > Unicode.
\IfFontExistsTF{SF Pro Text}{%
  \newfontfamily\sfsymbolsfont{SF Pro Text}
}{%
  \let\sfsymbolsfont\normalfont
}
\newcommand{\sfsymbol}[1]{{\sfsymbolsfont\symbol{"#1}}}

% JetBrains Mono with Contextual Alternates (calt) enables the programming
% ligatures for `->', `=>', `!=', `===', `<=', `>=' that Xcode-style code
% blocks are known for. Menlo/Courier fall back silently.
\IfFontExistsTF{JetBrains Mono}{%
  \setmonofont{JetBrains Mono}[Scale=0.85,Contextuals=Alternate]
}{%
  \IfFontExistsTF{Menlo}{%
    \setmonofont{Menlo}[Scale=0.85]
  }{%
    \setmonofont{Courier New}[Scale=0.85]
  }
}

% URLs and hyperlinks
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

% -----------------------------------------------------------------------------
% PAGE LAYOUT - WWDC BREATHING ROOM
% -----------------------------------------------------------------------------
\raggedbottom
\widowpenalty=10000
\clubpenalty=10000

% Single-space sentences (Apple convention) instead of TeX's default
% wider inter-sentence spacing.
\frenchspacing

% Soften hyphenation: Apple rarely hyphenates body copy. Raising the
% penalty makes LaTeX prefer a slightly-too-wide line or stretched
% interword glue over splitting a word; emergencystretch prevents the
% occasional overfull hbox in narrow measures.
\hyphenpenalty=400
\exhyphenpenalty=200
\tolerance=1200
\setlength{\emergencystretch}{3em}

% Keynote-deck breathing room: 1.35 linespread + full-baselineskip parskip
% gives prose room to breathe per reviewer. Paragraph indent stays at 0pt
% (Apple-style: paragraph break is signalled by space, not indent).
\setlength{\parskip}{1\baselineskip}
\setlength{\parindent}{0pt}
\linespread{1.35}

% -----------------------------------------------------------------------------
% HEADERS AND FOOTERS - BREADCRUMB NAVIGATION
% -----------------------------------------------------------------------------
\RequirePackage{fancyhdr}
\fancyhf{}

\fancypagestyle{plain}{%
  \fancyhf{}
  \fancyfoot[C]{\small\color{applegray2}\thepage}
  \renewcommand{\headrulewidth}{0pt}
  \renewcommand{\footrulewidth}{0pt}
}

% -----------------------------------------------------------------------------
% BREADCRUMB NAVIGATION
% -----------------------------------------------------------------------------
% Apple HIG-style hierarchical breadcrumb: <Root> > <Chapter> > <Section>
% split across the spread. The root is opt-in: call \setbreadcrumbroot{Short
% Label} in the preamble to enable it. When unset, verso falls back to just
% the chapter name (two-level: Chapter > Section on recto, Chapter on verso).
%
% Note: the storage command has no @ in its name because fancyhdr expands
% header content at shipout time when @ is not a letter.
\def\breadcrumbroottext{}
% Track whether root was explicitly set. Using a \newif conditional avoids
% \@empty comparisons which break at shipout time (@ not a letter).
\newif\ifbreadcrumbrootset
\newcommand{\setbreadcrumbroot}[1]{%
  \def\breadcrumbroottext{#1}\breadcrumbrootsettrue}

% Chevron separator - Apple uses U+203A SINGLE RIGHT-POINTING ANGLE QUOTATION
\newcommand{\breadcrumbsep}{\,{\color{applegray3}\guilsinglright}\,}

\fancypagestyle{main}{%
  \fancyhf{}
  % Verso (even, left): <Root> > <Chapter> (root omitted if not set)
  \fancyhead[LE]{\scriptsize\color{applegray2}\addfontfeature{LetterSpace=6.0}%
    \ifbreadcrumbrootset\breadcrumbroottext\breadcrumbsep\fi\leftmark}
  % Recto (odd, right): <Chapter> > <Section> (section omitted pre-first-section)
  \fancyhead[RO]{\scriptsize\color{applegray2}\addfontfeature{LetterSpace=6.0}%
    \leftmark\ifx\rightmark\leftmark\else\breadcrumbsep\rightmark\fi}
  % Page numbers on outer edges, bottom (book-like)
  \fancyfoot[RE,LO]{\small\color{applegray2}\thepage}
  \renewcommand{\headrulewidth}{0pt}
  \renewcommand{\footrulewidth}{0pt}
}

\pagestyle{main}

% Chapter name goes to \leftmark (uppercase), section name to \rightmark.
\renewcommand{\chaptermark}[1]{\markboth{\MakeUppercase{#1}}{}}
\renewcommand{\sectionmark}[1]{\markright{#1}}

% Force empty pagestyle on blank verso pages inserted by \cleardoublepage.
% Without this, the `main' style prints a ghost "CHAPTER 0 •" header on
% verso pages in the front matter.
% (.cls files already have @ as a letter, so no \makeatletter/\makeatother.)
\def\cleardoubleemptypage{%
  \clearpage
  \if@twoside
    \ifodd\c@page\else
      \hbox{}\thispagestyle{empty}\newpage
      \if@twocolumn\hbox{}\newpage\fi
    \fi
  \fi
}

% Number sections down to subsubsection and include in TOC.
\setcounter{secnumdepth}{3}
\setcounter{tocdepth}{3}

% -----------------------------------------------------------------------------
% CHAPTER FORMATTING - DRAMATIC WWDC STYLE
% -----------------------------------------------------------------------------
\RequirePackage{titlesec}

% Chapter: Large faded number + subtle hero background + title + decorative rule
% Chapter title uses SF Pro Display Bold for authentic Apple keynote feel.
\titleformat{\chapter}[display]
  {\normalfont\thispagestyle{plain}}
  {% Hero background + chapter label
    \begin{tikzpicture}[remember picture,overlay]
      % Subtle full-width background band behind faded chapter number
      \fill[sapblue!3]
        ([yshift=-20pt]current page.north west)
        rectangle
        ([yshift=-160pt]current page.north east);
      % Large faded chapter number (SF Pro Display Bold)
      \node[anchor=north west,
            font=\sfdisplaybold\fontsize{100}{100}\selectfont,
            text=applegray4,
            inner sep=0pt]
        at ([xshift=0mm,yshift=-10mm]current page.north west |- 0,0)
        {\thechapter};
    \end{tikzpicture}%
    \vspace{10pt}%
    {\color{sapblue}\fontsize{14}{16}\selectfont\addfontfeature{LetterSpace=10.0}CHAPTER \thechapter}%
  }
  {20pt}
  {\sfdisplaybold\fontsize{28}{34}\selectfont\color{appleblack}}
  [{\color{sapblue}\rule{60pt}{2.5pt}}]

% Extra breathing room below chapter opener (30pt -> 42pt)
\titlespacing*{\chapter}{0pt}{60pt}{42pt}

% Section: SF Pro Display Semibold with bold blue number
\titleformat{\section}
  {\sfdisplaysemi\fontsize{18}{22}\selectfont\color{appleblack}}
  {\color{sapblue}\sfdisplaybold\thesection}
  {12pt}
  {}

\titlespacing*{\section}{0pt}{24pt}{12pt}

% Subsection: SF Pro Display Semibold, gray number
\titleformat{\subsection}
  {\sfdisplaysemi\fontsize{14}{18}\selectfont\color{appleblack}}
  {\color{applegray1}\thesubsection}
  {10pt}
  {}

\titlespacing*{\subsection}{0pt}{18pt}{8pt}

% Subsubsection
\titleformat{\subsubsection}
  {\normalfont\fontsize{12}{15}\selectfont\bfseries\color{appleblack}}
  {\color{applegray2}\thesubsubsection}
  {8pt}
  {}

\titlespacing*{\subsubsection}{0pt}{14pt}{6pt}

% -----------------------------------------------------------------------------
% TABLE OF CONTENTS
% -----------------------------------------------------------------------------
\RequirePackage{titletoc}
\renewcommand{\contentsname}{Contents}

% Apple-HIG TOC: thin rule leader (not dots) for chapters, dotted leaders
% for sections/subsections, page numbers in applegray1 so the eye tracks
% chapter titles first. "Chapter" prefix is dropped per reviewer.
\titlecontents{chapter}
  [0pt]
  {\addvspace{16pt}\sfdisplaysemi\large\color{appleblack}}
  {\color{sapblue}\thecontentslabel\quad}
  {}
  {\hfill\color{applegray1}\contentspage}

\titlecontents{section}
  [20pt]
  {\addvspace{4pt}\color{appleblack}}
  {\thecontentslabel\quad}
  {}
  {\quad\titlerule*[8pt]{{\color{applegray3}.}}\color{applegray1}\contentspage}

\titlecontents{subsection}
  [45pt]
  {\small\color{applegray1}}
  {\thecontentslabel\quad}
  {}
  {\quad\titlerule*[8pt]{{\color{applegray3}.}}\contentspage}

% -----------------------------------------------------------------------------
% LISTS
% -----------------------------------------------------------------------------
\setlist{topsep=6pt, itemsep=4pt, parsep=2pt, leftmargin=20pt}
\setlist[itemize,1]{label={\color{sapblue}\textbullet}}
\setlist[itemize,2]{label={\color{applegray1}$\circ$}}
\setlist[itemize,3]{label={\color{applegray2}--}}
\setlist[enumerate,1]{label={\color{sapblue}\bfseries\arabic*.}}
\setlist[enumerate,2]{label={\color{applegray1}\alph*.}}

% -----------------------------------------------------------------------------
% TABLES - MINIMAL WWDC STYLE
% -----------------------------------------------------------------------------
\renewcommand{\arraystretch}{1.5}
\newcolumntype{L}[1]{>{\raggedright\arraybackslash}p{#1}}
\newcolumntype{C}[1]{>{\centering\arraybackslash}p{#1}}
\newcolumntype{R}[1]{>{\raggedleft\arraybackslash}p{#1}}

% Metrics table environment. Header uses SF Pro Display Semibold (lighter
% and more Apple-HIG than \textbf) and gets tracked small-caps treatment.
% Body cells get tabular lining figures so numeric columns align properly.
\newcommand{\metricshead}[1]{{\sfdisplaysemi\addfontfeature{LetterSpace=4.0}\MakeUppercase{#1}}}
\newcommand{\tabularfigures}{\addfontfeature{Numbers={Monospaced,Lining}}}
\NewDocumentEnvironment{metricstable}{m}{%
  \begin{table}[htbp]
  \centering
  \tabularfigures
  \setlength{\tabcolsep}{14pt}
  \renewcommand{\arraystretch}{1.6}
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

% Specification table environment. Body size matches main text (10pt).
\NewDocumentEnvironment{spectable}{m}{%
  \begin{table}[htbp]
  \centering
  \setlength{\tabcolsep}{12pt}
  \renewcommand{\arraystretch}{1.5}
  \begin{tabularx}{\textwidth}{@{}lX@{}}
  \toprule[0.8pt]
}{%
  \bottomrule[0.8pt]
  \end{tabularx}
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
  margin=20pt,
  skip=12pt
}

% More space before/after floats so figures breathe between paragraphs.
\setlength{\textfloatsep}{18pt plus 2pt minus 4pt}
\setlength{\intextsep}{18pt plus 2pt minus 4pt}
\setlength{\floatsep}{14pt plus 2pt minus 4pt}

% \mermaidfig{<path-without-ext>}{<caption>}{<label>}
% One-liner helper for Mermaid-rendered PDF diagrams. Expands to a full
% figure environment with \caption + \label, enabling \cref{fig:...}. The
% path is resolved relative to the spec's .tex file (i.e. the chapter or
% top-level), not to this class. Width is 0.85\textwidth by default.
\NewDocumentCommand{\mermaidfig}{O{0.85\textwidth} m m m}{%
  \begin{figure}[htbp]%
    \centering
    \includegraphics[width=#1]{#2.pdf}%
    \caption{#3}%
    \label{#4}%
  \end{figure}%
}

% -----------------------------------------------------------------------------
% CODE LISTINGS - WWDC STYLE
% -----------------------------------------------------------------------------
% Line-number gutter colour (Xcode-like distinct band behind line numbers)
\definecolor{linenumberbg}{RGB}{244, 246, 249}

\lstset{
  basicstyle=\small\ttfamily\color{appleblack},
  keywordstyle=\color{sapblue}\bfseries,
  stringstyle=\color{applepurple},
  commentstyle=\color{applegray2}\itshape,
  numbers=left,
  numberstyle=\tiny\color{applegray3}\ttfamily,
  numbersep=12pt,
  breaklines=true,
  breakatwhitespace=true,
  showstringspaces=false,
  tabsize=2,
  frame=leftline,
  framerule=28pt,
  rulecolor=\color{linenumberbg},
  backgroundcolor=\color{codebg},
  xleftmargin=28pt,
  xrightmargin=10pt,
  aboveskip=16pt,
  belowskip=16pt,
  framesep=6pt,
  framexleftmargin=0pt,
}

% Language definitions mirrored from sap-oss-listings.sty so specs that use
% `language=pythonx|jsonx|yamlx' compile with the minimal class too.
\lstdefinelanguage{pythonx}{
  language=Python,
  morekeywords={self,True,False,None,async,await,yield,with,as,lambda,nonlocal,
                match,case,dataclass,field,Optional,List,Dict,Set,Tuple,Union,
                Any,Callable,TypeVar,Generic,Protocol,Literal,Final,ClassVar},
  morecomment=[l]{\#},
  morestring=[b]",
  morestring=[b]',
}
\lstdefinelanguage{jsonx}{
  morestring=[b]",
  morecomment=[l]{//},
  literate=
    *{:}{{{\color{sapblue}:}}}1
    {,}{{{\color{sapblue},}}}1
    {true}{{{\color{sapblue}true}}}4
    {false}{{{\color{sapblue}false}}}5
    {null}{{{\color{sapblue}null}}}4,
}
\lstdefinelanguage{yamlx}{
  keywords={true,false,null,yes,no,on,off},
  sensitive=false,
  morecomment=[l]{\#},
  morestring=[b]',
  morestring=[b]",
}

% Code block with file path header (uses lstnewenvironment for verbatim support)
\lstnewenvironment{codeblock}[2][]
  {%
    \vspace{8pt}%
    \noindent
    \begin{tikzpicture}
      \node[
        fill=sapblue,
        text=white,
        font=\small\ttfamily,
        inner xsep=12pt,
        inner ysep=6pt,
        rounded corners=4pt,
      ] (header) {\faIcon{file-code}\hspace{6pt}\detokenize{#2}};
    \end{tikzpicture}%
    \vspace{-8pt}%
    \lstset{#1}%
  }
  {\vspace{4pt}}

% Inline code
\newcommand{\code}[1]{{\small\ttfamily\color{sapblue}#1}}

% -----------------------------------------------------------------------------
% BOX ENVIRONMENTS - WWDC STYLE WITH SHADOWS
% -----------------------------------------------------------------------------
\RequirePackage{tcolorbox}
\tcbuselibrary{skins,breakable}

% Base WWDC box style
\tcbset{
  wwdcbox/.style={
    enhanced,
    breakable,
    boxrule=0pt,
    arc=6pt,
    left=14pt,
    right=14pt,
    top=12pt,
    bottom=12pt,
    fonttitle=\bfseries,
    drop shadow={opacity=0.08,shadow xshift=2pt,shadow yshift=-2pt},
    borderline west={3pt}{0pt}{#1},
    colback=#1!5,
    colframe=#1,
    coltitle=appleblack,
    attach boxed title to top left={xshift=12pt, yshift=-8pt},
    boxed title style={
      colback=#1,
      colframe=#1,
      arc=3pt,
      boxrule=0pt,
      left=8pt,
      right=8pt,
      top=4pt,
      bottom=4pt,
    },
  }
}

% ADR Decision Box
\newtcolorbox{adrbox}[1][Decision]{
  wwdcbox=sapblue,
  title={\color{white}\faIcon{gavel}\hspace{6pt}#1},
}

% Info box
\newtcolorbox{infobox}[1][Information]{
  wwdcbox=sapblue,
  title={\color{white}\faIcon{info-circle}\hspace{6pt}#1},
}

% Warning box
\newtcolorbox{warningbox}[1][Warning]{
  wwdcbox=appleorange,
  title={\color{white}\faIcon{exclamation-triangle}\hspace{6pt}#1},
}

% Success box
\newtcolorbox{successbox}[1][Success]{
  wwdcbox=applegreen,
  title={\color{white}\faIcon{check-circle}\hspace{6pt}#1},
}

% Critical box - icon unified with sap-oss-boxes.sty (exclamation-circle)
\newtcolorbox{criticalbox}[1][Critical]{
  wwdcbox=applered,
  title={\color{white}\faIcon{exclamation-circle}\hspace{6pt}#1},
}

% Note box
\newtcolorbox{notebox}[1][Note]{
  wwdcbox=applegray1,
  title={\color{white}\faIcon{sticky-note}\hspace{6pt}#1},
}

% Source quotation box - keynote-style with a large leading quotation mark
% in faded sapblue for that WWDC pull-quote feel.
\newtcolorbox{sourcequotebox}[1][Source]{
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
          font=\sfdisplaybold\fontsize{48}{48}\selectfont,
          inner sep=0pt]
      at ([xshift=10pt,yshift=-6pt]frame.north west) {\textquotedblleft};
  },
}

% Simple source quote environment
\newenvironment{sourcequote}{\begin{sourcequotebox}}{\end{sourcequotebox}}

% -----------------------------------------------------------------------------
% HELPER COMMANDS
% -----------------------------------------------------------------------------
% Path/code helpers use \detokenize to survive literal strings containing
% `_', `<', `>', `#', `&' etc. without requiring the author to escape them.
% The argument must be a literal string (no macro expansion); this is the
% correct semantic for file paths, schema paths and identifiers.
\newcommand{\filepath}[1]{{\color{pathcolor}\faIcon{folder}\hspace{4pt}\texttt{\small\detokenize{#1}}}}
\newcommand{\artifact}[1]{\texttt{\small\color{sapblue}\detokenize{#1}}}
\newcommand{\reqid}[1]{\textbf{\color{sapblue}\texttt{\detokenize{#1}}}}
\newcommand{\corpus}[1]{\texttt{\small\color{applegray1}\detokenize{#1}}}
\newcommand{\tool}[1]{\texttt{\small\color{tealdark}\detokenize{#1}}}
\newcommand{\stateid}[1]{\textsc{\small\color{applepurple}\MakeLowercase{#1}}}
\newcommand{\ar}[1]{#1}
\newcommand{\schemapath}[1]{\texttt{\small\color{pathcolor}\detokenize{#1}}}
\newcommand{\enumval}[1]{\texttt{\small\color{applegreen}\detokenize{#1}}}
\newcommand{\fieldref}[1]{\texttt{\small\color{sapblue}\detokenize{#1}}}
\newcommand{\srcref}[1]{\texttt{\small\detokenize{#1}}}
\newcommand{\reqref}[1]{\texttt{\small #1}}
\newcommand{\specref}[1]{\texttt{\small #1}}
\newcommand{\schemaref}[1]{\texttt{\small #1}}
\newcommand{\gapref}[1]{\texttt{\small #1}}

% Status badges
\newcommand{\statusbadge}[2]{%
  \tikz[baseline=(badge.base)]{
    \node[
      fill=#1,
      text=white,
      font=\scriptsize\bfseries,
      inner xsep=6pt,
      inner ysep=2pt,
      rounded corners=3pt,
    ] (badge) {#2};
  }%
}
\newcommand{\statusmust}{\statusbadge{applered}{MUST}}
\newcommand{\statusshould}{\statusbadge{appleorange}{SHOULD}}
\newcommand{\statuscould}{\statusbadge{sapblue}{COULD}}
\newcommand{\statuswont}{\statusbadge{applegray2}{WON'T}}

% Badge-aligned list: tabular-based so TikZ badges in the first column do
% not interact with list-environment token scanning. Use inside a
% `badgelist' environment; each row is `\badgeitem{<badge>}{<text>}'.
\NewDocumentEnvironment{badgelist}{}{%
  \par\vspace{4pt}%
  \noindent\begin{tabular}{@{}p{62pt}@{\hspace{10pt}}p{\dimexpr\textwidth-80pt\relax}@{}}
}{%
  \end{tabular}\par\vspace{4pt}%
}
\newcommand{\badgeitem}[2]{#1 & #2 \\[4pt]}

% -----------------------------------------------------------------------------
% TITLE PAGE - WWDC STYLE
% -----------------------------------------------------------------------------
\newcommand{\@docsubtitle}{}
\newcommand{\@docref}{}
\newcommand{\@docversion}{}
\newcommand{\@docteam}{SCB GCFO}
\newcommand{\setdocsubtitle}[1]{\renewcommand{\@docsubtitle}{#1}}
\newcommand{\setdocref}[1]{\renewcommand{\@docref}{#1}}
\newcommand{\setdocversion}[1]{\renewcommand{\@docversion}{#1}}
\newcommand{\setdocteam}[1]{\renewcommand{\@docteam}{#1}}
\newcommand{\setsaplogo}[1]{}
\newcommand{\setbrandimage}[1]{}

\newcommand{\makesaptitle}{%
  \begin{titlepage}
    \thispagestyle{empty}
    % Blue header bar
    \begin{tikzpicture}[remember picture,overlay]
      \fill[sapblue] 
        ([yshift=0pt]current page.north west) 
        rectangle 
        ([yshift=-50pt]current page.north east);
    \end{tikzpicture}
    
    \vspace*{0.18\textheight}
    
    \begin{flushleft}
      % Document type label
      {\addfontfeature{LetterSpace=10.0}\color{sapblue}\small SPECIFICATION}
      
      \vspace{20pt}
      
      % Title - SF Pro Display Light at 40pt (authentic WWDC feel)
      {\sfdisplaylight\fontsize{40}{48}\selectfont\color{appleblack}\@title}
      
      \vspace{12pt}
      
      % Subtitle
      \ifx\@docsubtitle\empty\else
        {\fontsize{16}{20}\selectfont\color{applegray1}\@docsubtitle}
        \vspace{16pt}
      \fi
      
      % Decorative rule
      {\color{sapblue}\rule{80pt}{3pt}}
    \end{flushleft}
    
    \vfill
    
    % Footer info
    \begin{flushleft}
      {\small\color{applegray1}%
        \@author\\[4pt]
        \@date\\[8pt]
        \ifx\@docversion\empty\else Version \@docversion\\[4pt]\fi
        \ifx\@docref\empty\else\texttt{\@docref}\fi
      }
    \end{flushleft}
    
    \vspace{20pt}
    
    % Bottom decorative bar
    \begin{tikzpicture}[remember picture,overlay]
      \fill[sapblue] 
        ([yshift=0pt]current page.south west) 
        rectangle 
        ([yshift=8pt]current page.south east);
    \end{tikzpicture}
  \end{titlepage}
  \cleardoubleemptypage
}

% -----------------------------------------------------------------------------
% COLOPHON
% -----------------------------------------------------------------------------
\newcommand{\makecolophon}[1]{%
  \clearpage
  \thispagestyle{empty}
  \vspace*{\fill}
  \begin{center}
    {\color{sapblue}\rule{0.4\textwidth}{1pt}}\\[20pt]
    {\small\color{applegray1}#1}\\[20pt]
    {\color{sapblue}\rule{0.4\textwidth}{1pt}}
  \end{center}
  \vspace*{\fill}
}

% -----------------------------------------------------------------------------
% PDF METADATA
% -----------------------------------------------------------------------------
\AtBeginDocument{%
  \hypersetup{pdftitle={\@title}, pdfauthor={\@author}}
}

\endinput