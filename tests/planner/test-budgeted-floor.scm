;;; test-budgeted-floor.scm — a floor held against ANY Γ sources lost, without a
;;; future per source (Bertsimas & Sim 2004; engine `lay-budgeted-floors`).
;;;
;;; The world: two fields A and B, each 1 ha of land growing 1 kg of food per ha,
;;; a ground G with no land, and a haul (pickup/dropoff) that carries food along
;;; any arc. A floor F on food at G.
;;;
;;; Properties asserted (not a snapshot of quantities):
;;;   • Γ = 0: the plain floor — one source may carry all of it.
;;;   • Γ = 1, F = 1: every source alone can be lost, so EACH must deliver F —
;;;     both hauls to G carry ≥ F: the wall spreads the supply by construction.
;;;   • Γ = 1, F above what the others can carry: the program refuses
;;;     (planner-starvation), the honest answer.
;;;   • the term: a right stated `against:Γ` reads Γ; a bare one reads #f.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-budgeted-floor.scm

(use-modules (playnet planner knowledge dsl shorthand))
(use-modules (srfi srfi-1) (ice-9 format)
             (playnet planner solve engine) (playnet planner vf schemas)
             (playnet planner facts tension-terms))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define spatials (list (place* "A")
                       (place* "B" #:lon 0.2)
                       (place* "G" #:lat 0.1 #:lon 0.1)))
(define resources
  (list (er "landA" "land" #f #:place "A" #:qty 1.0 #:unit "ha")
        (er "landB" "land" #f #:place "B" #:qty 1.0 #:unit "ha")))
(define procs (list (rp* "grow" "Grow")
                    (rp* "haul" "Haul")))
(define flows
  (list (consume* "gL" "land" 1.0 "grow" "ha")
        (out* "gF" "food" 1.0 "grow")
        (make-recipe-flow #:id "hp" #:action 'pickup  #:resource-conforms-to "food"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "haul")
        (make-recipe-flow #:id "hd" #:action 'dropoff #:resource-conforms-to "food"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "haul")))

(define* (plan #:key (floor '()) (budgeted '()))
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:repro-floors floor #:budgeted-floors budgeted
                 #:demand '(("food#G@0" . 1.0)) #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report)
      (lambda (key) (if (eq? key 'report) report
                        (let ((i (hash-ref idx key #f))) (if i (vector-ref x i) 0.0)))))))

;; refused = the typed raise (the robust door) or a certificate that says so (the deterministic door)
(define (refuses? thunk)
  (catch 'planner-starvation
    (lambda () (let* ((x (thunk)) (c (assq-ref (x 'report) 'certificate)))
                 (and (list? c) (eq? #f (assq-ref c 'feasible?)))))
    (lambda _ #t)))

(format #t "~%── Γ = 0: the plain floor ──~%")
(define x0 (plan #:floor '(("food#G@0" . 1.0))))
(define hA0 (x0 "p|haul|A@0|G@0")) (define hB0 (x0 "p|haul|B@0|G@0"))
(format #t "  hauls to G: A ~,3f  B ~,3f~%" hA0 hB0)
(check "the plain floor is carried (A + B ≥ 1)" (>= (+ hA0 hB0) 0.99))

(format #t "~%── Γ = 1, F = 1: each source must carry the floor alone ──~%")
(define x1 (plan #:budgeted '(("food#G@0" 1.0 1))))
(define hA1 (x1 "p|haul|A@0|G@0")) (define hB1 (x1 "p|haul|B@0|G@0"))
(format #t "  hauls to G: A ~,3f  B ~,3f   z ~,3f~%" hA1 hB1 (x1 "z|food|G@0"))
(check "haul from A alone covers the floor (≥ 0.98)" (>= hA1 0.98))
(check "haul from B alone covers the floor (≥ 0.98)" (>= hB1 0.98))
(check "each source's OWN harvest is drawn (grow at A and at B ≥ 0.98)" (and (>= (x1 "p|grow|A@0") 0.98) (>= (x1 "p|grow|B@0") 0.98)))

(format #t "~%── Γ = 1, F = 1.5: more than any one source can carry ──~%")
(check "the program refuses (certificate feasible? #f, or the typed raise)"
       (refuses? (lambda () (plan #:budgeted '(("food#G@0" 1.5 1))))))

(format #t "~%── the term ──~%")
(check "against:2 on a right reads 2" (eqv? 2 (tension-against-of (append (with-tension-terms '() "floor" 0) '("against:2")))))
(check "a bare right reads #f" (not (tension-against-of (with-tension-terms '() "floor" 0))))
(check "\"budget\" is a cell kind" (eq? 'budget (kind-string->symbol "budget")))

(format #t "~%=== Results: ~a passed, ~a failed ===~%" *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
