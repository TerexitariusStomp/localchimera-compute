;;; test-wear-maintenance.scm — wear/maintenance with NO bespoke machinery.
;;;
;;; A durable's CONDITION is just a stock good `Cond|oven`. Per-recipe wear is a
;;; `consume` flow on the using recipe (its quantity IS the manner — 0.5 for a gentle
;;; bake, 2.0 for a sear); maintenance is a `produce` flow. The Cond ≥ 0 balance, its
;;; maintenance-pull dual, the carrying stock (Cond is *storable*), and the embodied
;;; depreciation rolled into the output (Cond is an input — good-labour-content sums
;;; it) ALL fall out of the good/recipe machinery — no *wear-rate*, no special section,
;;; no special SNLT term. Condition's onhand is its starting *init*.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-wear-maintenance.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve report) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver))

(define (bake-recipe wear maintain?)
  (compile-recipe
    (append (list (rp "bake" "Bake")) (if maintain? (list (rp "fix" "Maintain oven")) '()))
    (append (list (out "b1" "bread" 1.0 "bake") (wrk "b2" 0.1 "bake")
                  (in "b3" "Cond|oven" wear "bake"))                      ; WEAR = a consume of oven-condition (per-recipe quantity)
            (if maintain? (list (out "f1" "Cond|oven" 5.0 "fix") (wrk "f2" 1.0 "fix")) '()))))  ; MAINTENANCE = a produce of condition

(define (run wear cond0 maintain?)
  (declare-world! #:places '(("town" 0.0 0.0))
                  #:templates (bake-recipe wear maintain?)
                  #:storable '("Cond|oven"))   ; condition carries across periods (a stock)
  (hash-set! *init* (lg "Cond|oven" (cell "town" 0)) cond0)     ; starting condition = the good's onhand
  (hash-set! *A* (cell "town" 0) 10000.0)
  (hash-set! *demand* (lg "bread" (cell "town" 0)) 50.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((res (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))
             (x (car res)) (t (cadr res))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
             (bread (V "p|bake|town@0")) (fix (V "p|fix|town@0"))
             (slack (max 1e-9 (- (+ cond0 (* 5.0 fix)) (* wear bread))))   ; Cond|oven available
             (pull  (/ t slack)))
        (list bread fix pull)))))

(define gentle (run 0.5 20.0 #f))
(define sear   (run 2.0 20.0 #f))
(define fixed  (run 0.5 20.0 #t))
(define (bread r)(first r))(define (fix r)(second r))(define (pull r)(third r))

;; embodied depreciation rides in for free — Cond|oven is a consumed input good:
(define (bread-ell wear) (cdr (assoc "bread" (good-labour-content))))   ; needs *templates* set by run
(run 0.5 20.0 #t) (define ell-gentle (bread-ell 0.5))                   ; bake 0.1 + 0.5·(Cond ℓ̂ = 1/5 = .2) = 0.2
(run 2.0 20.0 #t) (define ell-sear   (bread-ell 2.0))                   ; bake 0.1 + 2.0·.2 = 0.5

(format #t "~%── condition as a stock GOOD (init 20), demand 50 loaves ──~%")
(format #t "  ~16a ~8a ~8a ~10a~%" "manner" "bread" "fix" "maint-pull")
(format #t "  ~16a ~8,1f ~8,1f ~10,3f~%" "gentle (wear .5)" (bread gentle) (fix gentle) (pull gentle))
(format #t "  ~16a ~8,1f ~8,1f ~10,3f~%" "sear   (wear 2)" (bread sear)   (fix sear)   (pull sear))
(format #t "  ~16a ~8,1f ~8,1f ~10,3f~%" "gentle+maintain" (bread fixed)  (fix fixed)  (pull fixed))
(format #t "  embodied ℓ̂(bread): gentle = ~,3f , sear = ~,3f   (the oven-wear, rolled in automatically)~%" ell-gentle ell-sear)

(let* ((c1 (and (> (bread gentle) 38.0) (< (bread gentle) 41.0)))   ; condition caps at 20/0.5 = 40
       (c2 (and (> (bread sear) 9.0) (< (bread sear) 11.0)))        ; 20/2 = 10 — same good, harsher manner
       (c3 (< (bread sear) (* 0.5 (bread gentle))))
       (c4 (and (> (bread fixed) 45.0) (> (fix fixed) 0.5)))        ; maintenance (produce Cond) ⇒ demand met
       (c5 (< (pull fixed) (pull gentle)))                          ; maintenance relieves the pull (the Cond balance's dual)
       (c6 (> ell-sear (+ ell-gentle 0.2)))                         ; embodied: sear bread carries more oven-wear (Cond input ℓ̂)
       (ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  [~a] condition (a good) caps output: gentle ≈ 40        (~,1f)~%" (if c1 "✓" "✗") (bread gentle))
  (format #t "  [~a] same oven, sear caps far lower ≈ 10               (~,1f)~%"   (if c2 "✓" "✗") (bread sear))
  (format #t "  [~a] manner, not amount (per-recipe consume quantity)   (sear ~,1f ≪ gentle ~,1f)~%" (if c3 "✓" "✗") (bread sear) (bread gentle))
  (format #t "  [~a] maintenance (produce Cond) restores ⇒ demand met   (bread ~,1f, fix ~,1f)~%" (if c4 "✓" "✗") (bread fixed) (fix fixed))
  (format #t "  [~a] maintenance relieves the pull (the Cond dual)       (~,3f → ~,3f)~%" (if c5 "✓" "✗") (pull gentle) (pull fixed))
  (format #t "  [~a] embodied depreciation rolls in: sear ℓ̂ > gentle ℓ̂  (~,3f vs ~,3f)~%" (if c6 "✓" "✗") ell-sear ell-gentle)
  (format #t "~%  ~a wear/maintenance entirely on the good/recipe machinery — condition is a stock, wear a consume, maintenance a produce~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
