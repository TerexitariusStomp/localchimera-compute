;;; test-federation-decomp.scm — CROSS-VAT decomposition, primal (quantity) form.
;;;
;;; Two SOVEREIGN communes solve SEPARATELY (each its own LP = its own vat) and
;;; exchange only SCALARS — the transfer quantity t and B's fill — never their
;;; inventory, roster, or plan. A coordinator raises the inter-commune transfer
;;; until B's deficit closes, bounded by A's feasibility. It converges (3 rounds)
;;; to the POOLED reference (the one-LP oracle): t* ≈ the oracle's A→B haul, B
;;; fully met. This is the same-vat pooled optimum reproduced by decentralised
;;; solves — the economic proof that federation composes.
;;;
;;; Scarcity is real (flour is #:never-raw, so B cannot self-provision from a free
;;; raw — it genuinely depends on A). Pulls sweep-tested separately show the
;;; naive gap between two pulls settles at partial service; the FAITHFUL dual decomposition
;;; needs a linear -pi*net-flow objective term (see docs/planning/federation/FEDERATED-SOLVE.md,
;;; "the one solver hook"). This test pins the primal version, which needs no hook.
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-federation-decomp.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))
(define (res spec loc q) (er (string-append spec "@" loc) spec #f #:place loc #:qty q #:unit "kg"))
(define (place id lat lon) (place* id #:lat lat #:lon lon))
(define (worker id loc) (person* id #:place loc #:tags '("general")))
(define A (place "a-home" 42.70 23.32))
(define B (place "b-home" 42.75 23.40))
(define bake-procs (list (rp "bake" "Bake bread")))
(define bake-flows (list (out "o" "bread" 1.0 "bake") (in "i" "flour" 1.0 "bake") (wrk "w" 0.1 "bake")))
(define haul (list (make-recipe-flow #:id "p1" #:action 'pickup  #:resource-conforms-to "bread"
                                     #:resource-quantity (make-measure 1.0 "kg")
                                     #:recipe-input-of "haul")
                   (make-recipe-flow #:id "d1" #:action 'dropoff #:resource-conforms-to "bread"
                                     #:resource-quantity (make-measure 1.0 "kg")
                                     #:recipe-output-of "haul")
                   (wrk "hw" 0.01 "haul")))
(define (labour r) (or (assq-ref (assq-ref r 'social) 'direct-labour) 0.0))
(define (guarded thunk) (catch #t thunk (lambda (k . a) (list 'err k))))

;; ── POOLED REFERENCE (the oracle) — both communes, one solve, never-raw flour ──
(define ref
  (call-with-values
    (lambda () (plan-from-records (list (res "flour" "a-home" 300.0))
                 (list (worker "wa" "a-home") (worker "wb" "b-home")) (list A B)
                 (cons (rp "haul" "Haul bread") bake-procs) (append bake-flows haul)
                 #:demand (list (cons (lg "bread" (cell "b-home" 0)) 40.0))
                 #:never-raw '("flour") #:arc-topology? #t #:per-agent? #f #:periods '(0)))
    (lambda (i c m fill cols x idx n r)
      (list (cons 'met fill) (cons 'haul (let ((h (hash-ref idx "p|haul|a-home@0|b-home@0" #f))) (if h (vector-ref x h) 0.0)))
            (cons 'labour (labour r))))))

;; ── THE TWO SOVEREIGN SUBPROBLEMS (separate solves; exchange only scalars) ──
(define (solveA t)   ; A must produce t bread to supply; report feasibility (fillA) + labour
  (guarded (lambda () (call-with-values
    (lambda () (plan-from-records (list (res "flour" "a-home" 300.0)) (list (worker "wa" "a-home")) (list A)
                 bake-procs bake-flows #:demand (list (cons (lg "bread" (cell "a-home" 0)) t))
                 #:never-raw '("flour") #:per-agent? #f #:periods '(0)))
    (lambda (i c m fill cols x idx n r) (list (cons 'fillA fill) (cons 'labA (labour r))))))))
(define (solveB t)   ; B receives t bread; report how much of its 40 is met + its labour
  (guarded (lambda () (call-with-values
    (lambda () (plan-from-records (list (res "bread" "b-home" t)) (list (worker "wb" "b-home")) (list B)
                 bake-procs bake-flows #:demand (list (cons (lg "bread" (cell "b-home" 0)) 40.0))
                 #:never-raw '("flour") #:per-agent? #f #:periods '(0)))
    (lambda (i c m fill cols x idx n r) (list (cons 'metB fill) (cons 'labB (labour r))))))))

;; ── PRIMAL (quantity) DECOMPOSITION: coordinator raises the transfer t until
;;    B's deficit closes, bounded by A's feasibility. Only scalars cross. ──
(format #t "~%  round   t        metB     fillA~%")
(define final-t
  (let loop ((t 0.0) (k 0))
    (let* ((b (solveB t)) (metB (assq-ref b 'metB))
           (a (solveA t)) (fillA (assq-ref a 'fillA))
           (deficit (* 40.0 (- 1.0 metB))))
      (format #t "   ~2d    ~6,2f    ~5,3f    ~5,3f~%" k t metB fillA)
      (if (or (< deficit 0.4) (> k 15)) t
          (loop (min 300.0 (+ t (* 0.9 deficit))) (+ k 1))))))

(format #t "~%── convergence vs pooled oracle ──~%")
(format #t "   decomposed transfer t* = ~,2f~%" final-t)
(format #t "   oracle haul            = ~,2f~%" (assq-ref ref 'haul))
(format #t "   oracle met             = ~,3f~%" (assq-ref ref 'met))
(let* ((bf (solveB final-t)) (metB* (assq-ref bf 'metB)))
  (format #t "   B met at t*            = ~,3f~%" metB*)
  (let ((ok (and (> metB* 0.98) (< (abs (- final-t (assq-ref ref 'haul))) 3.0))))
    (format #t "~%   [~a] primal decomposition converges to the pooled oracle~%~%" (if ok "OK" "XX"))))
