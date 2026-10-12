;;; test-option-composition.scm — the option is WHICH RECIPES compose the plan.
;;;
;;; A building needs a leak fixed. The occupants can compose the maintenance
;;; plan from different recipe sets — and each composition is a different
;;; plan with a different premium, read off (never optimised):
;;;
;;;   A. pay-as-usual : {patch-leak, procure-pipe}            — no pool source ⇒
;;;                     the leak stays unfixed, no leverage, premium $0.
;;;   B. withhold     : + {withhold-dues}                     — withheld dues
;;;                     fund the repair ⇒ leak fixed; the withholding is leverage
;;;                     the counterparty pays to defer (the leverage bound, ρ-gated).
;;;
;;; And credibility is PER-STRATEGY: the SAME withholding plan carries a premium
;;; only when participation (coverage) clears the floor — a 2-unit holdout is
;;; not credible; a building-wide one is. The premium is read off the at-stake
;;; good the composition produced (the withheld dues), not steered toward.
;;;
;;; Run:  guile -L module/playnet/planner -L module --no-auto-compile \
;;;         tests/solve/test-option-composition.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope))
(use-modules (srfi srfi-1) (ice-9 format))

(use-modules (playnet solve engine) (playnet solve plan)
             (playnet solve solver)
             (playnet vf schemas))
;; option-premium is a module; option-composition is still a fragment and
;; reads its names out of the current module, so import before loading it.
(use-modules (playnet algorithms option-premium))
(use-modules (playnet algorithms option-composition))
(use-modules ((playnet vf formulas actions) #:select (creating-actions))
             ((playnet vf formulas flows) #:select (committed-by-spec)))

(define *pass* 0) (define *fail* 0)
(define (ok? name cond)
  (if cond (begin (set! *pass* (+ *pass* 1)) (format #t "  ok   ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  FAIL ~a~%" name))))
(define (approx= a b tol) (< (abs (- a b)) tol))

;; ═════════════════════════════════════════════════════════════════════════
;; The building economy (labour + withheld dues modelled as consumable stocks)
;; ═════════════════════════════════════════════════════════════════════════
(define resources
  (list (er "r-dues" "spec-dues-owed" "pool" #:place "bldg" #:qty 300.0 #:unit "unit")           ; dues they could withhold
        (er "sk-fix" "spec-fix" "occupants" #:place "bldg" #:qty 1.0 #:unit "unit")))       ; the occupants' repair skill
(define agents   (list (make-agent #:id "occupants" #:type 'person #:name "Occupants' association"
                                   #:primary-location "bldg" #:classified-as '())))
(define spatials (list (make-spatial-thing #:id "bldg" #:lat 0.0 #:long 0.0)))
(define demand   (list (cons "spec-leak-fixed#bldg@0" 1.0)))   ; habitability need
;; "no leverage pool exists": when the withhold recipe is ABSENT, the engine
;; reverts any good with no producing column to a FREE raw input (usd with no
;; withholding, and pipe with no usd to buy it) — so it would conjure the
;; repair for free. Cap the whole chain's intermediates to 0 so the only way
;; to fund the repair is to produce the pool — i.e. to withhold. When
;; withholding IS composed in, usd and pipe are produced goods and need no
;; cap. The cap encodes the absence of a pool, which is exactly what
;; not-withholding means.
(define no-fund-caps (list (cons "spec-usd#bldg@0" 0.0)
                           (cons "spec-pipe#bldg@0" 0.0)))

;; ── recipes ────────────────────────────────────────────────────────────────
(define (proc id name) (make-recipe-process #:id id #:name name))
(define (cons-flow id spec q proc)
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec
                    #:resource-quantity (make-measure q "unit") #:recipe-input-of proc))
(define (prod-flow id spec q proc)
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (make-measure q "unit") #:recipe-output-of proc
                    #:is-primary #t))
(define (work-flow id hrs proc)               ; living labour (the occupants' repair skill)
  (make-recipe-flow #:id id #:action 'work #:resource-conforms-to "spec-fix"
                    #:effort-quantity (make-measure hrs %effort-unit) #:recipe-input-of proc))

;; common provisioning: fix the leak from a pipe; buy the pipe with fund dollars.
(define procs-common (list (proc "rp-leak" "Patch the leak")
                           (proc "rp-proc" "Procure pipe")))
(define flows-common
  (list (work-flow "f-leak-lab"  4.0           "rp-leak")
        (cons-flow "f-leak-pipe" "spec-pipe"      1.0   "rp-leak")
        (prod-flow "f-leak-out"  "spec-leak-fixed" 1.0  "rp-leak")
        (cons-flow "f-proc-usd"  "spec-usd"       100.0 "rp-proc")
        (prod-flow "f-proc-out"  "spec-pipe"      1.0   "rp-proc")))

;; the WITHHOLD recipe: withhold dues → leverage-pool dollars (the held option).
(define procs-strike (list (proc "rp-strike" "Withhold dues into the leverage pool")))
(define flows-strike
  (list (work-flow "f-strike-lab"  0.5            "rp-strike")
        (cons-flow "f-strike-dues" "spec-dues-owed" 100.0 "rp-strike")
        (prod-flow "f-strike-usd"  "spec-usd"       100.0 "rp-strike")))

(define* (compose procs flows #:key (caps '()))
  (set! *backend* 'native-c)
  (call-with-values
      (lambda () (plan-from-records resources agents spatials procs flows
                                    #:demand demand #:periods '(0) #:eco-caps caps
                                    #:agent-hours (lambda (a t) 20.0) #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (values material fill report))))

;; ═════════════════════════════════════════════════════════════════════════
;; A. pay-as-usual — no fund source, the leak stays unfixed
;; ═════════════════════════════════════════════════════════════════════════
(display "\n── A. pay-as-usual (no strike recipe) ──\n")
(call-with-values (lambda () (compose procs-common flows-common #:caps no-fund-caps))
  (lambda (matA fillA repA)
    (define pA (price-leverage matA #:at-stake-spec "spec-usd" #:R 0.40 #:coverage 0.80))
    (format #t "   leak met ~,1f%   withheld $~,0f   concession $~,1f~%"
            (* 100 fillA) (assq-ref pA 'leverage) (assq-ref pA 'concession))
    (ok? "without a fund source the leak stays unfixed" (< fillA 0.5))
    (ok? "no withholding ⇒ no leverage" (approx= (assq-ref pA 'leverage) 0.0 1e-6))
    (ok? "no leverage ⇒ no concession ($0)" (approx= (assq-ref pA 'concession) 0.0 1e-6))))

;; ═════════════════════════════════════════════════════════════════════════
;; B. withhold — the withheld dues fund the repair; leverage priced
;; ═════════════════════════════════════════════════════════════════════════
(display "\n── B. withhold (compose in withhold-dues) ──\n")
(call-with-values (lambda () (compose (append procs-common procs-strike)
                                      (append flows-common flows-strike)))
  (lambda (matB fillB report)
    ;; SAME plan, two participation levels — credibility is per-strategy.
    (define lowpart  (price-leverage matB #:at-stake-spec "spec-usd" #:R 0.40 #:coverage 0.20))
    (define highpart (price-leverage matB #:at-stake-spec "spec-usd" #:R 0.40 #:coverage 0.80))
    (format #t "   leak met ~,1f%   withheld $~,0f~%" (* 100 fillB) (assq-ref highpart 'leverage))
    (format #t "   2-unit strike  (cov 0.20): credible ~a  concession $~,1f~%"
            (assq-ref lowpart 'credible) (assq-ref lowpart 'concession))
    (format #t "   building strike (cov 0.80): credible ~a  concession $~,1f~%"
            (assq-ref highpart 'credible) (assq-ref highpart 'concession))
    (ok? "the strike-funded plan fixes the leak" (> fillB 0.99))
    (ok? "the plan withheld dues (leverage > 0)" (> (assq-ref highpart 'leverage) 0.0))
    ;; INTERIOR-POINT: `leverage` is the PRODUCED leverage pool (withheld dues). The
    ;; central-path solve over-produces it by O(barrier-t/κ) barrier slack — κ does
    ;; not drive it to the vertex ($100 = one pipe). So assert what is robust: the
    ;; withheld leverage COVERS the repair (≥ the $100 the pipe needs) and stays
    ;; within the dues actually available (≤ $300 seeded), and the plan is certified
    ;; near-optimal (duality gap ≤ m·t). The exact ~$100 is a t→0 idealisation.
    (ok? "the withheld leverage covers the repair, is bounded by the dues, and the plan is certified near-optimal"
         (and (>= (assq-ref highpart 'leverage) 100.0)
              (<= (assq-ref highpart 'leverage) 300.0)
              (< (assq-ref (assq-ref report 'certificate) 'duality-gap-bound) 5.0)))
    (ok? "a small holdout is NOT credible ⇒ concession $0"
         (and (not (assq-ref lowpart 'credible)) (approx= (assq-ref lowpart 'concession) 0.0 1e-6)))
    (ok? "a building-wide holdout IS credible ⇒ concession > 0"
         (and (assq-ref highpart 'credible) (> (assq-ref highpart 'concession) 0.0)))
    ;; Bound check: extractable = B(1−R) − B(1−cov) = B(cov−R) when credible
    (ok? "concession = B·(coverage−R) (the extractable bound)"
         (approx= (assq-ref highpart 'concession)
                  (* (assq-ref highpart 'leverage) (- 0.80 0.40)) 1e-2))))

;; ═════════════════════════════════════════════════════════════════════════
;; The headline: which recipes we plan with ⇒ different plans, different premiums
;; ═════════════════════════════════════════════════════════════════════════
(display "\n── the composition IS the decision ──\n")
(call-with-values (lambda () (compose procs-common flows-common #:caps no-fund-caps))
  (lambda (matA fillA _rA)
    (call-with-values (lambda () (compose (append procs-common procs-strike)
                                          (append flows-common flows-strike)))
      (lambda (matB fillB _rB)
        (ok? "different recipe sets give different plans (met differs)"
             (> (- fillB fillA) 0.5))
        (ok? "and different premiums (one withholds, one doesn't)"
             (> (produced-of matB "spec-usd") (produced-of matA "spec-usd")))
        (ok? "the tally of every spec at once says of each what the one-spec tally says"
             (let ((by (committed-by-spec matB creating-actions)))
               (and (pair? by)
                    (every (lambda (p) (= (cdr p) (produced-of matB (car p)))) by)
                    (= (length by) (length (delete-duplicates (map car by)))))))))))

(format #t "~%==== option-composition: ~a passed, ~a failed ====~%" *pass* *fail*)
(when (> *fail* 0) (exit 1))
