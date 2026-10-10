;;; test-frag-witness.scm — the sourced figures, guarded.
;;;
;;; The catalogue carries two witness tables of REAL published figures: nine planetary boundaries
;;; (Richardson et al. 2023 / PIK Planetary Health Check) and sixteen climate tipping elements
;;; (Armstrong McKay et al. 2022). This test guards their integrity and the headline scientific facts,
;;; so a careless edit can't silently corrupt a sourced number, and checks that BOTH frameworks reduce
;;; to the same frag machinery (the catalogue->policy seam emits well-formed agents for each).
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/knowledge/test-frag-witness.scm

(use-modules (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        f))
(use-modules (playnet knowledge catalogues eco))

;; ── tipping points: 16 elements, well-ordered ranges, and the paper's headline (5 at/below ~1.5°C) ──
(define tips *climate-tipping-points*)
(define (tmin t) (list-ref t 2)) (define (tcen t) (list-ref t 3)) (define (tmax t) (list-ref t 4))
(define ordered? (every (lambda (t) (<= (tmin t) (tcen t) (tmax t))) tips))
;; the paper's headline: at ~1.1°C current warming, FIVE elements already lie within their threshold
;; range (GrIS, WAIS, LABC, REEF, PFAT) — i.e. minimum threshold ≤ ~1.1°C.
(define already-in-range (length (filter (lambda (t) (<= (tmin t) 1.1)) tips)))
(define amoc (find (lambda (t) (eq? (cadr t) 'AMOC)) tips))
(define amoc-widest (= (- (tmax amoc) (tmin amoc)) (apply max (map (lambda (t) (- (tmax t) (tmin t))) tips))))

;; ── boundaries: nine processes (14 control-variable rows); the six CORE processes transgressed (2023) ──
(define bnds *planetary-boundaries*)
(define (transgressed? b) (list-ref b 6))
(define n-found (lambda (sub) (find (lambda (b) (string-contains (car b) sub)) bnds)))
(define has-nine (every n-found '("climate" "biosphere" "land" "freshwater" "biogeochemical"
                                  "ocean" "aerosol" "ozone" "novel")))
(define (process-transgressed? sub)                       ; ≥1 of a process's control-var rows is over its boundary
  (any (lambda (b) (and (string-contains (car b) sub) (transgressed? b))) bnds))
(define six-core (filter process-transgressed?            ; Richardson 2023: exactly these six of nine
                         '("climate" "biosphere" "land" "freshwater" "biogeochemical" "novel")))

;; ── one frag for both: catalogue->policy emits a well-formed agent for a boundary AND a tipping point ──
(define-values (rates budgets couples) (catalogue->policy *planetary-catalogue*))
(define n-agent  (assoc "nitrogen" rates))                ; a planetary BOUNDARY → rate frag (lo hi alpha w)
(define warm-agent (assoc "warming" budgets))             ; a tipping-point cluster → budget frag (lo hi alpha w)
(define (well-formed? a) (and a (= (length (cdr a)) 4) (< (cadr a) (caddr a)) (>= (car (cdddr a)) 0)))
(define warm-coupled (assoc "warming" (map (lambda (c) (cons (car c) (cdr c))) couples)))  ; driven by co2

(format #t "~%── the sourced figures, guarded ──~%")
(format #t "  tipping elements: ~a   (already in range at ~~1.1°C: ~a)   AMOC widest range: ~a~%"
        (length tips) already-in-range amoc-widest)
(format #t "  planetary boundaries: ~a rows, ~a of 9 core processes transgressed~%" (length bnds) (length six-core))
(format #t "  one frag for both — boundary(nitrogen)→rate ~a,  tip(warming)→budget ~a, co2-coupled ~a~%"
        (and n-agent #t) (and warm-agent #t) (and warm-coupled #t))

(let* ((c1 (= (length tips) 16))                          ; all 16 elements present
       (c2 ordered?)                                      ; min ≤ central ≤ max for every element
       (c3 (= already-in-range 5))                        ; the paper's headline: 5 elements already in range at ~1.1°C
       (c4 amoc-widest)                                   ; AMOC has the widest threshold range (1.4–8.0)
       (c5 has-nine)                                      ; all nine boundary processes named
       (c6 (= (length six-core) 6))                       ; Richardson 2023: six of nine processes transgressed
       (c7 (and (well-formed? n-agent) (well-formed? warm-agent) warm-coupled))  ; both frameworks → valid frags
       (ok (and c1 c2 c3 c4 c5 c6 c7)))
  (format #t "~%  [~a] 16 tipping elements, every range well-ordered (min ≤ central ≤ max)~%" (if (and c1 c2) "✓" "✗"))
  (format #t "  [~a] the headline holds: 5 elements already within range at ~~1.1°C warming~%" (if c3 "✓" "✗"))
  (format #t "  [~a] AMOC carries the widest threshold range (deep model disagreement)~%" (if c4 "✓" "✗"))
  (format #t "  [~a] all nine planetary boundaries named; six of nine core processes transgressed (Richardson 2023)~%" (if (and c5 c6) "✓" "✗"))
  (format #t "  [~a] both frameworks reduce to one frag — a boundary→rate and a tip→budget, both well-formed~%" (if c7 "✓" "✗"))
  (format #t "~%  ~a the sourced planetary-boundary and tipping-point figures are intact and machine-usable~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
