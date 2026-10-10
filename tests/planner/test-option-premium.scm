;;; test-option-premium.scm — Pricing VF Plans as options
;;;
;;; Exercises the four functions in algorithms/option-premium.scm:
;;;   compute-plan-underlier  (S)
;;;   compute-plan-strike     (K)
;;;   compute-plan-volatility (V)
;;;   compute-plan-premium    (BSM-inspired premium)
;;;
;;; Run:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/planner/test-option-premium.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet algorithms option-premium) (playnet federation store-registry) (playnet scope root) (playnet vf schemas))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))

;; ══════════════════════════════════════════════════════════���══════════════
;; 1. cumulative-normal accuracy
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── cumulative-normal ──\n")

(check "N(0) = 0.5" (approx= (cumulative-normal 0) 0.5 0.0001))
(check "N(1.96) ≈ 0.975" (approx= (cumulative-normal 1.96) 0.975 0.001))
(check "N(-1.96) ≈ 0.025" (approx= (cumulative-normal -1.96) 0.025 0.001))
(check "N(3.5) ≈ 1.0" (approx= (cumulative-normal 3.5) 0.9998 0.001))
(check "N(-3.5) ≈ 0.0" (approx= (cumulative-normal -3.5) 0.0002 0.001))
(check "N(1) ≈ 0.8413" (approx= (cumulative-normal 1.0) 0.8413 0.001))

;; ═════════════════════════════════════════════════════════════════════════
;; 2. Setup: one scope with recipe-store for S(P) and K(P) tests
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── Setup: recipe-store with withhold-and-maintain-style recipe ──\n")

(define store (make-memory-store))
(define scope-root-env-full
  ;; each env names its own actor; a new slot on ^scope-root needs no edit here
  (make-persistence-env '() #:extends (list scope-root-env store-registry-env)))

(define-values (vat scope registry)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda ()
      (values (spawn-scope-root "Option Premium Test Scope")
              (spawn ^store-registry (hashmap))))
    store))

;; Resource specs
(define usd-spec
  (make-resource-specification #:id "spec-usd" #:name "Dollars" #:default-unit-of-resource "usd"
                               #:medium-of-exchange #t))
(define labor-spec
  (make-resource-specification #:id "spec-labor" #:name "Labor hours"
                               #:default-unit-of-resource %effort-unit))
(define pipe-spec
  (make-resource-specification #:id "spec-pipe" #:name "Pipe (meters)"
                               #:default-unit-of-resource "m"))
(define repair-spec
  (make-resource-specification #:id "spec-repair" #:name "Repair completed"
                               #:default-unit-of-resource %count-unit))

;; Recipe: repair job consuming $24 pipe + 2h labor → 1 repair
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (for-each (lambda (s) ($ rs 'add-resource-spec s))
              (list usd-spec labor-spec pipe-spec repair-spec))

    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-repair" #:name "Do the repair"
                            #:has-duration (make-duration 2 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-pipe" #:action 'consume #:resource-conforms-to "spec-pipe"
                         #:resource-quantity (make-measure 3 "m")
                         #:recipe-input-of "rp-repair"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-labor" #:action 'work #:effort-quantity (make-measure 2 %effort-unit)
                         #:recipe-input-of "rp-repair"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-repair-out" #:action 'produce #:resource-conforms-to "spec-repair"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-repair"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-repair" #:name "Repair job" #:primary-output "spec-repair"
                    #:recipe-processes (list "rp-repair")))))

;; Price function: pipe=$8/m, labor=$25/h
(define (test-price-of spec unit)
  (cond
    ((equal? spec "spec-pipe") 8)
    ((equal? spec "labor") 25)
    (else 0)))

;; ═════════════════════════════════════════════════════════════════════════
;; 3. S(P) — underlier value
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── S(P): plan underlier value ──\n")

;; Recipe consumes 3m pipe × $8/m = $24 (work flows NOT counted in underlier)
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (let ((S (compute-plan-underlier rs (list "recipe-repair")
                                     #:price-of test-price-of)))
      (check "S(repair) = $24 (3m × $8)" (approx= S 24 0.01)))))

;; ═════════════════════════════════════════════════════════════════════════
;; 4. K(P) — execution cost (materials + labor)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── K(P): plan execution cost ──\n")

;; 3m pipe × $8 = $24 materials + 2h × $25 = $50 labor = $74 total
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (let ((K (compute-plan-strike rs (list "recipe-repair")
                                  #:price-of test-price-of)))
      (check "K(repair) = $74 (24 materials + 50 labor)" (approx= K 74 0.01)))))

;; ═════════════════════════════════════════════════════════════════════════
;; 5. V(P) — volatility from buffer-snapshot series
;; ═══════════════════════════════════════════════════════════════════════��═

(display "\n── V(P): buffer-signal volatility ──\n")

;; Oscillating onhand: 80, 120, 80, 120, 80, 120, 80, 120, 80, 120
;; mean=100, stddev=~21.08 (sample), CV = 21.08/100 = 0.2108
(define test-snapshots-volatile '((80 120 80 120 80 120 80 120 80 120)))
(define test-snapshots-stable   '((99 100 101 100 99 100 101 100 99 100)))

(let ((v-volatile (compute-plan-volatility test-snapshots-volatile '()
                                           #:buffer-weight 1.0
                                           #:governance-weight 0.0))
      (v-stable   (compute-plan-volatility test-snapshots-stable '()
                                           #:buffer-weight 1.0
                                           #:governance-weight 0.0)))
  (check "V(volatile) ≈ 0.211" (approx= v-volatile 0.211 0.02))
  (check "V(stable) < 0.02" (< v-stable 0.02))
  (check "volatile > stable" (> v-volatile v-stable)))

;; Multiple specs: average their CVs
(let ((v-multi (compute-plan-volatility
                 '((80 120 80 120 80) (99 100 101 100 99))
                 '()
                 #:buffer-weight 1.0 #:governance-weight 0.0)))
  (check "V(multi-spec) between volatile and stable"
         (and (> v-multi 0.05) (< v-multi 0.25))))

;; ═════════════════════════════════════════════════════════════════════════
;; 6. V(P) — governance-signal volatility
;; ══════════════════════════════��══════════════════════════════════════════

(display "\n── V(P): governance-signal volatility ──\n")

;; [#t #t #f #t #f] = 3 reversals in 4 gaps = 0.75
(let ((v-gov (compute-plan-volatility '() '(#t #t #f #t #f)
                                      #:buffer-weight 0.0
                                      #:governance-weight 1.0)))
  (check "V(gov: 3 reversals in 5) = 0.75" (approx= v-gov 0.75 0.01)))

;; Stable governance: [#t #t #t #t #t] = 0 reversals
(let ((v-gov (compute-plan-volatility '() '(#t #t #t #t #t)
                                      #:buffer-weight 0.0
                                      #:governance-weight 1.0)))
  (check "V(gov: no reversals) = 0" (approx= v-gov 0 0.001)))

;; ═════════════════════════════════════════════════════════════════════════
;; 7. V(P) — blended
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── V(P): blended buffer + governance ──\n")

;; buffer CV ≈ 0.211, governance rate = 0.75
;; V = √(0.5 × 0.211² + 0.5 × 0.75²) = √(0.5×0.0445 + 0.5×0.5625)
;;   = √(0.02225 + 0.28125) = √0.3035 ≈ 0.551
(let ((v-blended (compute-plan-volatility
                   test-snapshots-volatile
                   '(#t #t #f #t #f)
                   #:buffer-weight 0.5
                   #:governance-weight 0.5)))
  (check "V(blended) ≈ 0.55" (approx= v-blended 0.55 0.05)))

;; ═════════════════════════════════════════════════════════════════════════
;; 8. Premium — approximate mode (the V² × √dt approximation)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── Premium: approximate mode ──\n")

;; S=1000, V=0.3, dt=30/365 ≈ 0.0822
;; Premium = 1000 × 0.09 × √0.0822 = 1000 × 0.09 × 0.2867 = 25.80
(let ((p (compute-plan-premium 1000 0 0.3 (/ 30 365))))
  (check "approx premium: S=1000 V=0.3 dt=30d" (approx= p 25.80 0.5)))

;; V doubles → premium quadruples (V² relationship)
(let ((p1 (compute-plan-premium 1000 0 0.2 (/ 30 365)))
      (p2 (compute-plan-premium 1000 0 0.4 (/ 30 365))))
  (check "doubling V quadruples premium" (approx= (/ p2 p1) 4.0 0.1)))

;; Zero volatility → zero premium
(let ((p (compute-plan-premium 1000 0 0.0 (/ 30 365))))
  (check "V=0 → premium=0" (approx= p 0 0.001)))

;; Zero underlier → zero premium
(let ((p (compute-plan-premium 0 0 0.3 (/ 30 365))))
  (check "S=0 → premium=0" (approx= p 0 0.001)))

;; ═════════════════════════════════════════════════════════════════════════
;; 9. Premium — BSM put mode
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── Premium: BSM put mode ──\n")

;; S=100, K=100 (at-the-money), V=0.25, dt=1yr, r=0.05
;; BSM put: d1=0.325, d2=0.075, N(-d1)≈0.3727, N(-d2)≈0.4701
;; P = 100×e^(-0.05)×0.4701 - 100×0.3727 ≈ 7.45
(let ((p (compute-plan-premium 100 100 0.25 1.0 #:r 0.05 #:mode 'bsm)))
  (check "BSM ATM put: S=K=100 V=0.25 dt=1y r=5%" (approx= p 7.45 0.5)))

;; Deep in-the-money put: K=150, S=100 → intrinsic ≈ K×e^(-r×dt) - S ≈ 42.68
;; Total includes time-value on top
(let ((p (compute-plan-premium 100 150 0.25 1.0 #:r 0.05 #:mode 'bsm)))
  (check "BSM ITM put: K=150 S=100" (> p 40)))

;; V→0 → premium approaches intrinsic value
(let ((p (compute-plan-premium 100 120 0.001 1.0 #:r 0.05 #:mode 'bsm)))
  (let ((intrinsic (max 0 (- (* 120 (exp -0.05)) 100))))
    (check "V→0: premium ≈ intrinsic" (approx= p intrinsic 0.5))))

;; S=0 → premium = K×e^(-r×dt) (full protection value)
(let ((p (compute-plan-premium 0.001 100 0.25 1.0 #:r 0.05 #:mode 'bsm)))
  (check "S≈0: premium ≈ K×e^(-rdt)" (approx= p (* 100 (exp -0.05)) 1.0)))

;; ═════════════════════════════════════════════════════════════════════════
;; 10. Integration: full pipeline S → K → V → Premium
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── Integration: full pipeline ──\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (S (compute-plan-underlier rs (list "recipe-repair")
                                   #:price-of test-price-of))
         (K (compute-plan-strike rs (list "recipe-repair")
                                #:price-of test-price-of))
         (V (compute-plan-volatility test-snapshots-volatile
                                     '(#t #t #f #t #f)
                                     #:buffer-weight 0.5
                                     #:governance-weight 0.5))
         (dt (/ 30 365))
         (p-approx (compute-plan-premium S K V dt))
         (p-bsm    (compute-plan-premium S K V dt #:r 0.02 #:mode 'bsm)))

    (check "pipeline S = $24" (approx= S 24 0.01))
    (check "pipeline K = $74" (approx= K 74 0.01))
    (check "pipeline V > 0" (> V 0))
    (check "pipeline approx premium > 0" (> p-approx 0))
    (check "pipeline BSM premium > 0" (> p-bsm 0))
    (check "BSM premium > approx (K > S → deep ITM)"
           (> p-bsm p-approx))

    (format #t "  pipeline: S=$~,2f K=$~,2f V=~,3f dt=~,4f\n" S K V dt)
    (format #t "  approximate premium: $~,4f\n" p-approx)
    (format #t "  BSM put premium:     $~,4f\n" p-bsm)))

;;; ════════════════════════════════��════════════════════════════════���══════

(newline)
(test-summary!)
