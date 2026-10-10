;;; process.scm — a bioregion's drought/normal/flood scenario PROBABILITIES from its
;;; precipitation record. Guile-native (bioclim.scm). Reproducible: same raw ⇒ same output.
;;;
;;;   guile process.scm [PRECIP_JSON] [WET_MONTHS]
;;;   guile process.scm raw/doon/precip.json            # AUTO-detects the growing season
;;;   guile process.scm raw/doon/precip.json 6,7,8,9    # or name it; or `annual`

(add-to-load-path (dirname (current-filename)))
(define here (dirname (current-filename)))
(use-modules (bioclim) (ice-9 format) (srfi srfi-1))
(define (rnd x) (inexact->exact (round x)))

(define args (cdr (command-line)))
(define path (if (> (length args) 0) (list-ref args 0) "raw/doon/precip.json"))
(define arg  (and (> (length args) 1) (list-ref args 1)))
(define S    (scenarios path arg))
(define c    (scen-counts S)) (define n (scen-ref S 'n))
(define months (scen-ref S 'months))
(define mstr (if (equal? months (iota 12 1)) "annual" (string-join (map number->string months) "-")))
(define label (basename (dirname path)))

(format #t "[~a] growing-season rainfall (months ~a, ~a) ~a–~a (n=~a): mean=~amm σ=~amm~%"
        label mstr (scen-ref S 'how) (car (scen-ref S 'years)) (last (scen-ref S 'years))
        n (rnd (scen-ref S 'mean)) (rnd (scen-ref S 'sd)))
(format #t "  drought p = ~a/~a = ~,3f~%" (car c) n (exact->inexact (/ (car c) n)))
(format #t "  normal  p = ~a/~a = ~,3f~%" (cadr c) n (exact->inexact (/ (cadr c) n)))
(format #t "  flood   p = ~a/~a = ~,3f~%" (caddr c) n (exact->inexact (/ (caddr c) n)))
(format #t "→ a bioregion's <planning-scenario> probabilities.~%")
