;;; test-robust-records.scm — robust multi-scenario planning through the RECORDS
;;; pipeline, keyed by the VF-aligned <planning-scenario> record (Phase 2).
;;;
;;; Same claim as robust-multiscenario-test (the raw-forms proof), now driven end-
;;; to-end through records + build-located: diversity is a DERIVED result of
;;; defending the reproduction floor under uncertainty — no new solver machinery,
;;; just a scenario-aware ASSEMBLY of the forms build-located already emits.
;;;
;;; One farm, one unit of land (1 ha), two grow recipes producing the SAME `food`:
;;;   • growA (HYV):         base 1.0 kg/ha, scaled per scenario → 4.0 normal, 0.0 drought.
;;;   • growB (traditional): base 1.0 kg/ha, scaled per scenario → 1.3 normal, 1.2 drought.
;;; Reproduction floor: food ≥ 1.0.  A modest surplus demand rewards more food.
;;; growA/growB are FIRST-STAGE (you plant before you know the weather) → shared.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-robust-records.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner vf schemas) (playnet planner beyond scenario)
             (playnet planner knowledge dsl shorthand)
             (srfi srfi-1)
             (ice-9 format))

;; ── the farm as records ──────────────────────────────────────────────────────
(define spatials (list (place* "farm")))
;; land: 1 ha on hand, a raw consumed by growing (no producer ⇒ a hard cap).
(define resources
  (list (er "land1" "land" #f #:place "farm" #:unit "ha")))
(define procs (list (rp* "growA" "Grow A (HYV)")
                    (rp* "growB" "Grow B (traditional)")))
;; each grow: consume 1 ha land, produce 1.0 food (BASE yield; scenarios scale it).
(define flows
  (list (consume* "aL" "land" 1.0 "growA" "ha")
        (out* "aF" "food" 1.0 "growA")
        (consume* "bL" "land" 1.0 "growB" "ha")
        (out* "bF" "food" 1.0 "growB")))
(define demand       '(("food#farm@0" . 5.0)))   ; want surplus for market → rewards A's high normal yield
(define repro-floors '(("food#farm@0" . 1.0)))   ; subsistence floor — must hold in EVERY scenario

;; ── scenarios as <planning-scenario> records (Phase-2 seam) ──────────────────
;;   deterministic = the naive certainty-equivalent: ONE world at MEAN yields.
(define det-scenarios
  (list (make-planning-scenario "mean" #f 1.0
          '(("growA" . 2.8) ("growB" . 1.27)) "expected-yield world")))
;;   robust = the two real futures, probability-weighted.
(define rob-scenarios
  (list (make-planning-scenario "normal"  "sc-normal"  0.7 '(("growA" . 4.0) ("growB" . 1.3)) "normal year")
        (make-planning-scenario "drought" "sc-drought" 0.3 '(("growA" . 0.0) ("growB" . 1.2)) "drought year")))

;; first-stage activity of a proc (Σ x over its shared grow columns) — engine/robust.scm helper
(define (solve-plan scenarios)
  (call-with-values
    (lambda () (plan-robust-from-records resources '() spatials procs flows
                 #:scenarios scenarios #:first-stage-procs '("growA" "growB")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f))
    (lambda (x fs rc n ns . _)
      (list (first-stage-activity x fs "growA") (first-stage-activity x fs "growB") ns))))

(define det (solve-plan det-scenarios))
(define rob (solve-plan rob-scenarios))
(define det-A (car det)) (define det-B (cadr det))
(define rob-A (car rob)) (define rob-B (cadr rob))
(define det-drought-food (+ (* 0.0 det-A) (* 1.2 det-B)))   ; the deterministic plan met by drought yields

(format #t "~%DETERMINISTIC (mean-yield, 1 world): growA=~,3f  growB=~,3f~%" det-A det-B)
(format #t "  → if a drought hits: food = ~,3f  (floor 1.0)  ~a~%"
        det-drought-food (if (< det-drought-food 1.0) "*** STARVES ***" "ok"))
(format #t "ROBUST (~a scenarios):               growA=~,3f  growB=~,3f~%" (caddr rob) rob-A rob-B)

;; ── Phase 3: the SAME robustness through the canonical plan-from-records entry ──
(define pfr-report
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios rob-scenarios #:first-stage-procs '("growA" "growB")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report) report)))
(define pfr-robust (assoc-ref pfr-report 'robust))
(define pfr-nscen  (assoc-ref pfr-report 'nscenarios))
(define pfr-fs     (or (assoc-ref pfr-report 'first-stage-plan) '()))
(define pfr-B      (or (assoc-ref pfr-fs "growB") 0.0))
(format #t "~%plan-from-records #:scenarios → robust=~a  nscenarios=~a  first-stage growB=~,3f~%"
        pfr-robust pfr-nscen pfr-B)

(format #t "~%── assertions ──~%")
(check "deterministic plants a MONOCULTURE of A (growA > 0.9)"        (> det-A 0.9))
(check "deterministic barely grows B (growB < 0.1)"                  (< det-B 0.1))
(check "deterministic plan STARVES in drought (food < floor)"        (< det-drought-food 1.0))
(check "robust DIVERSIFIES into B (growB > 0.7)"                     (> rob-B 0.7))
(check "robust keeps some A where safe (growA > 0.05)"               (> rob-A 0.05))
(check "robust is not a degenerate all-B monoculture (growB < 0.95)" (< rob-B 0.95))
(check "diversity DERIVED via records pipeline (robust growB ≫ det growB)"
       (> rob-B (+ det-B 0.5)))
(check "the <planning-scenario> set drove 2 scenarios"              (= (caddr rob) 2))
(check "plan-from-records #:scenarios returns a robust plan"        (eq? pfr-robust #t))
;; the report narrates real numbers, not gaps: the social-individual
;; accounting (scenario-0 view) and a feasibility verdict ride the robust
;; report exactly as they ride the deterministic one
(check "robust report carries a numeric social ledger (free-time f)"
       (number? (assoc-ref (or (assoc-ref pfr-report 'social) '()) 'free-time)))
(check "robust report carries a certificate (feasible verdict)"
       (list? (assoc-ref pfr-report 'certificate)))
(check "  … via the canonical entry, carrying the diversified plan (growB > 0.7)" (> pfr-B 0.7))
(check "  … reporting the 2-scenario count"                        (= pfr-nscen 2))

(check-done "  robust planning runs through the RECORDS pipeline via <planning-scenario>;~%  diversity emerges, no new solver.~%")
