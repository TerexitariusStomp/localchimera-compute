;;; process-yields.scm — per-crop baseline yields (kg/ha) from vendored OWID yield CSVs.
;;; The reader lives in agronomy.scm (shared with emit-derived.scm). Guile-native.
;;;
;;;   guile process-yields.scm COUNTRY raw/<label>/yield-*.csv
;;;   guile process-yields.scm India raw/doon/yield-*.csv

(add-to-load-path (dirname (current-filename)))
(define here (dirname (current-filename)))
(use-modules (agronomy) (ice-9 format) (srfi srfi-1))

(define args (cdr (command-line)))
(define country (if (> (length args) 0) (list-ref args 0) "India"))
(define paths   (if (> (length args) 1) (cdr args) '("raw/doon/yield-rice.csv")))
(define ys (sort (national-yields country paths) (lambda (a b) (string<? (car a) (car b)))))

(format #t "[~a] national baseline yields (mean of last 5 yrs, OWID/FAOSTAT):~%" country)
(for-each (lambda (cy) (format #t "  (~s . ~,1f)   ; kg/ha  [OWID t/ha ×1000]~%" (car cy) (cdr cy))) ys)
(format #t "→ a bioregion's *crop-yields* baseline (rename crops to your recipe ids).~%")
