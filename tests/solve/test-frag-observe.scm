;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-frag-observe.scm — the observer→planner loop: an eco agent's MEASURED state becomes the baseline.
;;;
;;; Eco agents are ordinary observed resources: an EconomicResource whose `conforms-to` spec is
;;; frag-capped and whose onhand quantity is the draw already committed toward the tip. ingest-stock!
;;; routes that observed quantity to *frag-prior* (NOT to *cap* as an available-draw bound), so the
;;; barrier baseline becomes s_tip − observed. This is the live loop: the observer holds the world's
;;; state, ingest reads it each solve, the plan draws incrementally from there.
;;;
;;; Proves the wiring end to end through ingest-located!: (a) a frag-capped agent's onhand routes to
;;; *frag-prior*, keyed by located-good for a per-period cap and by bare spec for a cumulative budget;
;;; (b) it does NOT land in *cap*; (c) the emitted barrier's baseline is exactly tip − observed.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-observe.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve ingest) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define s-tip 10.0)   ; co2 tip = quantile_0.5 of [8,12]
(define obs   4.0)    ; the OBSERVED draw already committed (the eco agent's onhand) ⇒ headroom 6
(define (emit-recipe)
  (compile-recipe (list (rp "emit" "Emit"))
                  (list (out "o1" "widget" 1.0 "emit") (wrk "o2" 0.1 "emit")
                        (in "o3" "co2" 1.0 "emit"))))   ; co2 is a raw, drawn 1:1
(define (co2-resource onhand)   ; an eco agent as an ordinary observed EconomicResource
  (er "co2-obs" "co2" #f #:qty onhand #:unit "kg"))
(define (town) (place* "town"))
(define lg-co2 (lg "co2" (cell "town" 0)))
(define (index-kind C k) (let ((kv (ckind C)) (n (cnt C)))
                           (let loop ((i 0)) (cond ((= i n) #f) ((= (vector-ref kv i) k) i) (else (loop (+ i 1)))))))
(define (frag-const)   ; the baseline of the (single) emitted frag form = tip − observed
  (hash-set! *A* (cell "town" 0) 10000.0)
  (call-with-values build-located
    (lambda (forms . _) (let* ((C (flatten forms)) (i3 (index-kind C 3))) (and i3 (vector-ref (cconst C) i3))))))

;; ── per-period fragility cap: onhand routes to *frag-prior* keyed by located-good ──
(set-templates! (emit-recipe))
(ingest-located! (list (co2-resource obs)) '() (list (town))
  #:periods '(0)
  #:eco-frag (list (cons lg-co2 (list 8.0 12.0 0.5 50.0)))
  #:demand   (list (cons (lg "widget" (cell "town" 0)) 20.0)))
(define pp-prior (hash-ref *frag-prior* lg-co2 #f))   ; observed → prior (per-period key)
(define pp-cap   (hash-ref *cap* lg-co2 #f))          ; must NOT be a hard cap
(define pp-const (frag-const))                         ; barrier baseline

;; ── cumulative budget: onhand routes to *frag-prior* keyed by bare spec ──
(set-templates! (emit-recipe))
(ingest-located! (list (co2-resource obs)) '() (list (town))
  #:periods '(0)
  #:eco-budget (list (cons "co2" (list 8.0 12.0 0.5 50.0)))
  #:demand     (list (cons (lg "widget" (cell "town" 0)) 20.0)))
(define bg-prior (hash-ref *frag-prior* "co2" #f))    ; observed → prior (budget key = spec)
(define bg-const (frag-const))

(format #t "~%── observer → planner · eco agent onhand ~a, tip ~a ──~%" obs s-tip)
(format #t "  per-period: *frag-prior*[co2#town@0] = ~a   *cap* = ~a   barrier baseline = ~a~%" pp-prior pp-cap pp-const)
(format #t "  budget:     *frag-prior*[co2]        = ~a   barrier baseline = ~a~%" bg-prior bg-const)

(let* ((c1 (and pp-prior (< (abs (- pp-prior obs)) 1e-9)))            ; observed onhand → per-period prior
       (c2 (not pp-cap))                                             ; …NOT a hard *cap*
       (c3 (and pp-const (< (abs (- pp-const (- s-tip obs))) 1e-9))) ; baseline = tip − observed (= 6)
       (c4 (and bg-prior (< (abs (- bg-prior obs)) 1e-9)))           ; budget: observed → prior keyed by spec
       (c5 (and bg-const (< (abs (- bg-const (- s-tip obs))) 1e-9))) ; budget baseline = tip − observed
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] per-period: observed onhand routes to *frag-prior* (~a), not *cap*~%" (if (and c1 c2) "✓" "✗") pp-prior)
  (format #t "  [~a] per-period barrier baseline = tip − observed (~a = ~a − ~a)~%" (if c3 "✓" "✗") pp-const s-tip obs)
  (format #t "  [~a] budget: observed onhand routes to *frag-prior* keyed by spec (~a)~%" (if c4 "✓" "✗") bg-prior)
  (format #t "  [~a] budget barrier baseline = tip − observed (~a)~%" (if c5 "✓" "✗") bg-const)
  (format #t "~%  ~a an eco agent's measured state flows through ingest to the barrier baseline — the observe→plan loop~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
