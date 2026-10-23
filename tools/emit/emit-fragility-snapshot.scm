;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; emit-fragility-snapshot.scm — the fragility face's data, straight from the
;;; encoded catalogue. Reads the WITNESS TABLES in
;;; module/playnet/knowledge/catalogues/eco.scm (the real, cited planetary-boundary
;;; and climate-tipping figures) and the solver weights in *planetary-catalogue*,
;;; and emits browser/data/snapshots/fragility-snapshot.json — the offline fallback the
;;; fragility face renders. The live gateway pushes the same shape via
;;; the app's "fragility" topic. Nothing is invented here: every number is
;;; transcribed in eco-catalogue.scm from its primary source.
;;;
;;;   guile --no-auto-compile -L module tools/emit/emit-fragility-snapshot.scm [out]
;;;
;;; `make check-fragility-fresh` regenerates and diffs the committed copy.
;;;
;;; The two witness tables and the solver catalogue come from
;;; (playnet knowledge catalogues eco), imported below.

(use-modules (ice-9 format) (srfi srfi-1))

(define root (dirname (dirname (dirname (current-filename)))))
(define (rel p) (string-append root "/" p))
(use-modules (playnet knowledge catalogues eco))

;; ── governance weight w per control, from the solver catalogue where the
;; federation actually draws the limit; a default steepness elsewhere (witness-
;; only boundaries the federation bears witness to but cannot yet draw). w is a
;; political-economic choice (§2.0.8), carried here only so the wheel has a
;; concrete saturation to render.
(define solver-w
  (filter-map (lambda (e)
                (and (pair? e) (not (eq? (car e) 'couple)) (>= (length e) 6)
                     (cons (car e) (list-ref e 5))))   ; (spec . w)
              *planetary-catalogue*))
(define (weight-for spec)
  (cond ((assoc spec solver-w) => cdr) (else 6.0)))    ; default governance steepness

;; ── the nine boundaries, keyed so the 14 controls group under them for labels.
(define (group-of name)
  (cond ((string-prefix? "climate" name) "climate change")
        ((string-prefix? "biosphere" name) "biosphere integrity")
        ((string-prefix? "land" name) "land-system change")
        ((string-prefix? "freshwater" name) "freshwater change")
        ((string-prefix? "biogeochemical" name) "biogeochemical flows")
        ((string-prefix? "ocean" name) "ocean acidification")
        ((string-prefix? "atmospheric" name) "atmospheric aerosols")
        ((string-prefix? "stratospheric" name) "stratospheric ozone")
        ((string-prefix? "novel" name) "novel entities")
        (else name)))
;; map a witness row's control-variable → the solver spec that carries its weight
(define (spec-of name ctrl)
  (cond ((string-contains name "N ") "nitrogen")
        ((string-contains name "P regional") "phosphorus")
        ((string-contains name "ocean") "ocean-acidification")
        ((and (string-prefix? "climate" name) (string-contains ctrl "CO2")) "warming")
        (else name)))

;;; ─── the JSON writer the snapshot emitters share, plus this file's own
;;; number form (a missing figure is null) and its field-by-field object ──────
(use-modules ((playnet utils json-emit) #:select (J:s J:b)))
(define (J:n x) (cond ((not (number? x)) "null")
                      ((= x (round x)) (number->string (inexact->exact (round x))))
                      (else (number->string (exact->inexact x)))))
(define (J:field k v) (string-append (J:s k) ":" v))
(define (J:obj . kvs) (string-append "{" (string-join kvs ",") "}"))
(define (J:arr items) (string-append "[" (string-join items ",") "]"))

;; ── controls: the 14 planetary-boundary control variables (witness table 1)
(define controls
  (map (lambda (row)
         (let* ((name  (list-ref row 0)) (ctrl (list-ref row 1))
                (b     (list-ref row 2)) (hi   (list-ref row 3))
                (cur   (list-ref row 4)) (unit (list-ref row 5))
                (trans (list-ref row 6)) (src  (list-ref row 7)))
           (J:obj (J:field "group"       (J:s (group-of name)))
                  (J:field "control"     (J:s ctrl))
                  (J:field "boundary"    (J:n b))
                  (J:field "riskHi"      (J:n hi))
                  (J:field "current"     (J:n cur))
                  (J:field "unit"        (J:s unit))
                  (J:field "transgressed"(J:b trans))
                  (J:field "w"           (J:n (weight-for (spec-of name ctrl))))
                  (J:field "source"      (J:s src)))))
       *planetary-boundaries*))

;; ── tipping elements (witness table 2), for the tipping ring / hover detail
(define tips
  (map (lambda (t)
         (J:obj (J:field "name"    (J:s (list-ref t 0)))
                (J:field "abbr"    (J:s (list-ref t 1)))
                (J:field "min"     (J:n (list-ref t 2)))
                (J:field "central" (J:n (list-ref t 3)))
                (J:field "max"     (J:n (list-ref t 4)))
                (J:field "years"   (J:n (list-ref t 5)))
                (J:field "character"(J:s (list-ref t 6)))))
       *climate-tipping-points*))

(define out
  (J:obj (J:field "source" (J:s "Richardson et al. 2023 (nine planetary boundaries) + Armstrong McKay et al. 2022 (climate tipping elements), via module/playnet/knowledge/catalogues/eco.scm"))
         (J:field "warmingNow" (J:n *warming-now*))
         (J:field "controls" (J:arr controls))
         (J:field "tippingElements" (J:arr tips))))

(define out-path
  (let ((args (cdr (command-line))))
    (if (pair? args) (car args) (rel "browser/data/snapshots/fragility-snapshot.json"))))
(call-with-output-file out-path
  (lambda (p) (set-port-encoding! p "UTF-8") (display out p) (newline p)))
(format #t "wrote ~a — ~a controls, ~a tipping elements~%" out-path
        (length controls) (length tips))
