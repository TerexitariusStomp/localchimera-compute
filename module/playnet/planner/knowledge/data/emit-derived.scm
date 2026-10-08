;;; emit-derived.scm — GENERATE the mechanical-derivation layer of a bioregion's
;;; knowledge as a Scheme data file, from the vendored raw. Guile-native: the generator
;;; and the generated are the SAME language (homoiconic — no cross-language string
;;; templating). Closes the provenance loop; human JUDGMENT stays in <label>-valley.scm.
;;;
;;;   guile emit-derived.scm [LABEL] [COUNTRY] [CROPS] > ../<label>-derived.scm
;;;   guile emit-derived.scm doon India rice,maize,ragi,pulses > ../doon-derived.scm
;;;
;;; Reproducible: same vendored raw ⇒ byte-identical output (checked by `make verify-derived`).

(add-to-load-path (dirname (current-filename)))
(define here (dirname (current-filename)))
(use-modules (bioclim) (agronomy) (ice-9 format) (ice-9 rdelim) (ice-9 ftw) (srfi srfi-1))

(define args (cdr (command-line)))
(define label   (if (> (length args) 0) (list-ref args 0) "doon"))
(define country (if (> (length args) 1) (list-ref args 1) "India"))
(define crops   (if (> (length args) 2) (string-split (list-ref args 2) #\,) '("rice" "maize" "ragi" "pulses")))
(define raw (string-append here "/raw/" label))
(define tempf (string-append raw "/temp.json"))

;; sha16 of a vendored file, read from its checksum manifest (no gcrypt dep needed).
(define (sha16 manifest fname)
  (or (call-with-input-file (string-append raw "/" manifest)
        (lambda (p) (let loop ()
                      (let ((l (read-line p)))
                        (cond ((eof-object? l) #f)
                              ((string-suffix? fname l) (substring (car (string-split l #\space)) 0 16))
                              (else (loop)))))))
      "----------------"))

(define S    (scenarios (string-append raw "/precip.json")))
(define cnts (scen-counts S))                         ; (drought normal flood)
(define n    (scen-ref S 'n))
(define rain (scen-rain-by-class S))
(define mult (multipliers rain crops))
(define yield-csvs (or (scandir raw (lambda (f) (string-prefix? "yield-" f))) '()))
(define yields (sort (national-yields country (map (lambda (f) (string-append raw "/" f)) yield-csvs))
                     (lambda (a b) (string<? (car a) (car b)))))

(define P (string-append label "-derived"))
(define (alist->str pairs fmt)                        ; ((k . v) …) → ("k" . v) … one line
  (string-join (map (lambda (kv) (format #f "(~s . ~a)" (car kv) (format #f fmt (cdr kv)))) pairs) " "))

(define out (current-output-port))
(define (e . xs) (for-each (lambda (x) (display x out)) xs) (newline out))
(e ";;; " label "-derived.scm — GENERATED from vendored raw by data/emit-derived.scm. DO NOT EDIT.")
(e ";;; Regenerate: cd data && guile emit-derived.scm " label " " country " " (string-join crops ",") " > ../" label "-derived.scm")
(e ";;; Verify (CI): make verify-derived  — re-runs the generator, diffs this file, fails on drift.")
(e ";;;")
(e ";;; The MECHANICAL layer — pure derivations from the vendored record. Human")
(e ";;; JUDGMENT (state-yield anchors, stage-physiology multiplier refinements, the")
(e ";;; Taleb tail) lives in " label "-valley.scm / the shed, layered on top explicitly.")
(e ";;; Source raw (sha256/16):")
(e ";;;   precip.json " (sha16 "SHA256SUMS" "precip.json"))
(for-each (lambda (f) (e ";;;   " f " " (sha16 "SHA256SUMS-yields" f))) yield-csvs)
(e "")
(e ";; growing season — auto-detected (calendar months above the mean month)")
(e "(define *" P "-season* '(" (string-join (map number->string (scen-ref S 'months)) " ") "))")
(e "")
(e ";; HOW WARM IT IS WHERE THE WORK HAPPENS (°C, last decade of the record).")
(e ";; The shed already knows; anything that needs a working temperature asks here")
(e ";; rather than carrying its own table. warm-quarter is bioclim BIO10, the mean")
(e ";; of the warmest three consecutive months — NOT of *-season* above, which is")
(e ";; detected from rainfall and in a Mediterranean shed is the COLD half of the")
(e ";; year. (catalogues/subsistence.scm reads warm-quarter for the sweat curve.)")
(e ";;   temp.json " (sha16 "SHA256SUMS-temp" "temp.json"))
(e "(define *" P "-warm-quarter-degc* " (format #f "~,1f" (warm-quarter-temp tempf)) ")")
(e "(define *" P "-annual-mean-degc* "  (format #f "~,1f" (annual-mean-temp tempf)) ")")
(e "")
(e ";; scenario probabilities — IMD ±1σ classification of " n " growing seasons")
(e "(define *" P "-scenario-probs*")
(e "  '((\"normal\" . " (format #f "~,6f" (/ (cadr cnts) n))
   ") (\"drought\" . " (format #f "~,6f" (/ (car cnts) n))
   ") (\"flood\" . " (format #f "~,6f" (/ (caddr cnts) n)) ")))")
(e "")
(e ";; mean growing-season rainfall within each class (mm) — the water reference")
(e "(define *" P "-scenario-rain*")
(e "  '(" (alist->str rain "~,1f") "))")
(e "")
(e ";; per-scenario yield multipliers — FAO Ky × the local rainfall (agronomy.scm)")
(e "(define *" P "-ky-multipliers*")
(e "  '(" (string-join
           (map (lambda (sc) (format #f "(~s ~a)" (car sc) (alist->str (cdr sc) "~,2f"))) mult)
           "\n     ") "))")
(e "")
(e ";; national baseline yields (kg/ha, OWID/FAOSTAT) — a cross-check anchor")
(e "(define *" P "-yields*")
(e "  '(" (alist->str yields "~,1f") "))")
(e "")
