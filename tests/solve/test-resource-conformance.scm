;;; test-resource-conformance.scm — substitutability is GENERIC across skills and
;;; means.  A means supplies the CONFORMANCE CLOSURE of its spec, capped by one
;;; shared budget — the exact worker-bundle mechanism, minus the labour-only EMP
;;; and κ free-time terms (a means is need-priced, it has no free time to equalise).
;;;
;;; The claim under test: a `convection-oven` can fill a recipe that only asks for
;;; an `oven`, because `oven` is `satisfied-by` `convection-oven` — the SAME
;;; `effective-skills` closure a worker's licences flow through, now carrying an
;;; instrument.  And the shared capacity means one oven is one oven: its whole
;;; closure draws on a single budget, so it can be an `oven` OR a
;;; `convection-oven`-qua-itself, never both at once beyond what it can do.
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-resource-conformance.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))
(use-modules (playnet vf formulas capacity))

;; bake 1 bread per oven-hour: a `use` of an OVEN (Svc|oven) + a little labour.
(define bake-oven
  (car (compile-recipe (list (rp "bake" "Bake"))
         (list (out "b1" "bread" 1.0 "bake")
               (wrk "b2" 0.1 "bake")
               (use* "b3" "oven" "bake" 1.0 #:qty 1.0)))))

;; knead 1 dough per flour consumed: a `consume` of FLOUR (a bare stock).
(define knead-flour
  (car (compile-recipe (list (rp "knead" "Knead"))
         (list (out "k1" "dough" 1.0 "knead")
               (wrk "k2" 0.1 "knead")
               (in  "k3" "flour" 1.0 "knead")))))

(define twn (cell "town" 0))

;; Drive one solve: SUPPLIERS is a list of (id closure-specs cell cap durable?);
;; ECO-CAPS is an alist poured straight into *cap*. DEMANDS is (good . qty).
(define (run tpls suppliers eco-caps demands)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates tpls
                  #:resource-suppliers suppliers)
  (hash-set! *A* twn 1000.0)                                   ; labour abundant — the MEANS is the only scarcity
  (for-each (lambda (ec) (hash-set! *cap* (car ec) (cdr ec))) eco-caps)
  (for-each (lambda (d) (hash-set! *demand* (lg (car d) twn) (cdr d))) demands)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values
                     (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))))
        (lambda (key) (let ((i (hash-ref idx key #f))) (if i (vector-ref x i) 0.0)))))))

;; ── 1. a convection-oven fills a recipe that only asks for an `oven` ──
;; The ONLY oven-service in the economy is a convection-oven offering its closure
;; {convection-oven, oven}. No plain Svc|oven cap exists.
(define conv2 (run (list bake-oven)
                   '(("conv" ("convection-oven" "oven") "town@0" 2.0 #t))
                   '() '(("bread" . 8.0))))
(define conv4 (run (list bake-oven)
                   '(("conv" ("convection-oven" "oven") "town@0" 4.0 #t))
                   '() '(("bread" . 8.0))))
(define bread2 (conv2 "p|bake|town@0"))
(define bread4 (conv4 "p|bake|town@0"))

;; ── 2. a plain oven (singleton closure) is byte-identical to a plain eco-cap ──
(define via-supplier (run (list bake-oven)
                          '(("plainov" ("oven") "town@0" 3.0 #t))
                          '() '(("bread" . 8.0))))
(define via-ecocap   (run (list bake-oven)
                          '()
                          (svc-eco-caps '(("oven" "town" 3.0)) '(0))
                          '(("bread" . 8.0))))
(define sup-bread (via-supplier "p|bake|town@0"))
(define cap-bread (via-ecocap   "p|bake|town@0"))

;; ── 3. a stock supplies the bare consumable through its closure ──
;; wheat-flour is-a flour: {wheat-flour, flour}, durable? = #f ⇒ a bare `flour` good.
(define flour3 (run (list knead-flour)
                    '(("wf" ("wheat-flour" "flour") "town@0" 3.0 #f))
                    '() '(("dough" . 8.0))))
(define dough3 (flour3 "p|knead|town@0"))

;; ── 4. the closure shares ONE budget — one oven is not two ──
;; Two bakes: one asks for `oven`, one asks (via its own recipe) for the exact
;; `convection-oven`. Both draw the SAME supplier's single 3-hour budget.
(define bake-conv
  (car (compile-recipe (list (rp "bakec" "BakeConv"))
         (list (out "c1" "cake" 1.0 "bakec")
               (wrk "c2" 0.1 "bakec")
               (use* "c3" "convection-oven" "bakec" 1.0 #:qty 1.0)))))
(define shared (run (list bake-oven bake-conv)
                    '(("conv" ("convection-oven" "oven") "town@0" 3.0 #t))
                    '() '(("bread" . 4.0) ("cake" . 4.0))))
(define shared-total (+ (shared "p|bake|town@0") (shared "p|bakec|town@0")))

(define (≈ a b) (< (abs (- a b)) 0.05))

(format #t "~%── substitutability is one mechanism for skills AND means ──~%")
(let* ((c1 (≈ bread2 2.0))                                      ; convection-oven satisfies `oven`, bounded by its cap
       (c2 (≈ bread4 4.0))                                      ; more capacity ⇒ more of the substituted service
       (c3 (≈ sup-bread cap-bread))                             ; singleton closure ≡ plain eco-cap
       (c4 (≈ dough3 3.0))                                      ; wheat-flour fills `flour` as a bare stock
       (c5 (≈ shared-total 3.0))                                ; the closure shares ONE budget (3, not 6)
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "  [~a] convection-oven fills a `use oven`             (cap 2 ⇒ bread ~,2f ≈ 2)~%" (if c1 "✓" "✗") bread2)
  (format #t "  [~a] sized by the means' capacity                  (cap 4 ⇒ bread ~,2f ≈ 4)~%" (if c2 "✓" "✗") bread4)
  (format #t "  [~a] singleton closure ≡ plain eco-cap             (supplier ~,2f = eco-cap ~,2f)~%" (if c3 "✓" "✗") sup-bread cap-bread)
  (format #t "  [~a] wheat-flour fills a `consume flour` (bare)    (cap 3 ⇒ dough ~,2f ≈ 3)~%" (if c4 "✓" "✗") dough3)
  (format #t "  [~a] the closure shares ONE budget — one oven ≠ two (bread+cake ~,2f ≈ 3, not 6)~%" (if c5 "✓" "✗") shared-total)
  (format #t "~%  ~a a means supplies its spec's conformance closure on one shared budget — the worker bundle, need-priced~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
