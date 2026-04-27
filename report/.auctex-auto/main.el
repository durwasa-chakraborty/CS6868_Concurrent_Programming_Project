;; -*- lexical-binding: t; -*-

(TeX-add-style-hook
 "main"
 (lambda ()
   (TeX-add-to-alist 'LaTeX-provided-class-options
                     '(("article" "11pt" "a4paper")))
   (TeX-add-to-alist 'LaTeX-provided-package-options
                     '(("inputenc" "utf8") ("fontenc" "T1") ("geometry" "margin=1in") ("microtype" "") ("lmodern" "") ("amsmath" "") ("amssymb" "") ("graphicx" "") ("booktabs" "") ("array" "") ("enumitem" "") ("xcolor" "") ("listings" "") ("hyperref" "") ("cleveref" "capitalise" "noabbrev")))
   (add-to-list 'LaTeX-verbatim-environments-local "lstlisting")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "href")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "hyperimage")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "hyperbaseurl")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "nolinkurl")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "url")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "path")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "lstinline")
   (add-to-list 'LaTeX-verbatim-macros-with-delims-local "path")
   (add-to-list 'LaTeX-verbatim-macros-with-delims-local "lstinline")
   (TeX-run-style-hooks
    "latex2e"
    "article"
    "art11"
    "inputenc"
    "fontenc"
    "geometry"
    "microtype"
    "lmodern"
    "amsmath"
    "amssymb"
    "graphicx"
    "booktabs"
    "array"
    "enumitem"
    "xcolor"
    "listings"
    "hyperref"
    "cleveref")
   (LaTeX-add-labels
    "sec:goals"
    "sec:background"
    "sec:tasks"
    "sec:evaluation"
    "sec:llm"
    "sec:conclusions"
    "sec:contributions")
   (LaTeX-add-bibliographies
    "references")
   (LaTeX-add-xcolor-definecolors
    "codegray"))
 :latex)

