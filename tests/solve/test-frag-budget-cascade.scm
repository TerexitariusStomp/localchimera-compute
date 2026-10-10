;;; test-frag-budget-cascade.scm — Space ∘ Time: a CUMULATIVE budget on EFFECTIVE pressure.
;;;
;;; The budget reads the spec's effective pressure p = (I−C)^{-1}·draw, summed across the whole
;;; horizon — so a coupled agent's draw eats the budget, and (the subtle part) it does so even at
;;; periods/cells where the budgeted spec ITSELF isn't drawn. The propagate operator sums each
;;; agent's TOTAL horizon draw scaled by the Leontief row, so no cell is missed.
;;;
;;; co2 carries a cumulative budget (tip 10) and is coupled to soil (drawing soil stresses co2 by 0.5).
;;; widget (drawing co2) is demanded ONLY in period 0 — so co2 is drawn only at p0. grain (drawing soil)
;;; is demanded in BOTH periods — so soil is drawn at p0 AND p1. The budget = co2(p0) + 0.5·(soil_p0 +
;;; soil_p1) must stay under 10, which means soil's period-1 draw — at a cell where co2 is absent — is
;;; suppressed by co2's budget. That is the cell-aggregation subtlety, made to bite.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-budget-cascade.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver))

(define s-tip 10.0) (define cpl 0.5)
(define (recipes)
  (compile-recipe
    (list (rp "emit" "Emit") (rp "till" "Till"))
    (list (out "a1" "widget" 1.0 "emit") (wrk "a2" 0.1 "emit") (in "a3" "co2" 1.0 "emit")
          (out "b1" "grain" 1.0 "till") (wrk "b2" 0.1 "till") (in "b3" "soil" 1.0 "till"))))

(define (run coupled?)
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods '(0 1)
                  #:templates (recipes))
  (hash-set! *A* (cell "town" 0) 10000.0) (hash-set! *A* (cell "town" 1) 10000.0)
  (hash-set! *cap* (lg "soil" (cell "town" 0)) 100.0)             ; soil available, both periods (loose)
  (hash-set! *cap* (lg "soil" (cell "town" 1)) 100.0)
  (hash-set! *frag-budget* "co2" (list 8.0 12.0 0.5 50.0))        ; cumulative co2 budget, tip 10
  (when coupled? (hash-set! *eco-couple* "co2" (list (cons "soil" cpl))))   ; drawing soil stresses co2
  (hash-set! *demand* (lg "widget" (cell "town" 0)) 8.0)          ; widget ONLY period 0 ⇒ co2 drawn only at p0
  (hash-set! *demand* (lg "grain" (cell "town" 0)) 8.0)           ; grain BOTH periods ⇒ soil drawn at p0 and p1
  (hash-set! *demand* (lg "grain" (cell "town" 1)) 8.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (list (V "p|emit|town@0") (V "p|till|town@0") (V "p|till|town@1"))))))   ; co2 draw (p0), soil (p0), soil (p1)

(define free (run #f))
(define cpld (run #t))
(define (co2 r)(first r))(define (s0 r)(second r))(define (s1 r)(third r))
(define eff-free (+ (co2 free) (* cpl (+ (s0 free) (s1 free)))))   ; what co2's effective pressure WOULD be (uncoupled: not enforced)
(define eff-cpld (+ (co2 cpld) (* cpl (+ (s0 cpld) (s1 cpld)))))   ; the ENFORCED effective-pressure budget when coupled

(format #t "~%── cascade-aware budget · co2 tip ~a, soil stresses co2 by ~a ──~%" s-tip cpl)
(format #t "  uncoupled: co2(p0) ~,3f  soil(p0) ~,3f  soil(p1) ~,3f   (eff would be ~,3f)~%" (co2 free) (s0 free) (s1 free) eff-free)
(format #t "  coupled:   co2(p0) ~,3f  soil(p0) ~,3f  soil(p1) ~,3f   (eff = ~,3f)~%"        (co2 cpld) (s0 cpld) (s1 cpld) eff-cpld)

(let* ((c1 (< eff-cpld s-tip))                       ; effective-pressure budget never crossed
       (c2 (> (- s-tip eff-cpld) 0.05))              ; …eased off before the tip
       (c3 (< (co2 cpld) (co2 free)))                ; coupling suppresses co2's own draw
       (c4 (< (s1 cpld) (- (s1 free) 1.0)))          ; THE SUBTLETY: soil's PERIOD-1 draw (co2 absent there) is suppressed ⇒ the budget feels it
       (c5 (> eff-free s-tip))                       ; uncoupled, the same draws WOULD breach the tip through the cascade
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] coupled effective-pressure budget eases off before the tip (~,3f < ~a)~%" (if (and c1 c2) "✓" "✗") eff-cpld s-tip)
  (format #t "  [~a] coupling suppresses co2's own draw (~,3f < ~,3f)~%" (if c3 "✓" "✗") (co2 cpld) (co2 free))
  (format #t "  [~a] soil's period-1 draw is suppressed — the budget feels it where co2 is ABSENT (~,3f < ~,3f)~%" (if c4 "✓" "✗") (s1 cpld) (s1 free))
  (format #t "  [~a] uncoupled, those draws would breach the tip through the cascade (~,3f > ~a)~%" (if c5 "✓" "✗") eff-free s-tip)
  (format #t "~%  ~a a cumulative budget on effective pressure (I−C)^{-1}·draw — Space and Time composed, no cell missed~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
