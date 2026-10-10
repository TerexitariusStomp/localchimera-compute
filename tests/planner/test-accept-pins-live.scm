;;; test-accept-pins-live.scm — the live loop closes: a plan-store accept PINS
;;; the next plan-scope solve.
;;;
;;; docs/planning/solve/commitment-horizon.md, the live wire: every plan-scope solve
;;; runs robust-by-default (a singleton deterministic scenario when no futures
;;; are declared), and the plan-store's in-window work accepts ride in as
;;; #:pins — hand-decided columns the solve treats as facts. Fixture = the
;;; bread chain of test-live-wiring, mocked stores in a vat.

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-11)
             (playnet scope live)
             (playnet plan store)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define procs bread-procs) (define flows bread-flows)

(define bake-accept
  (make-commitment #:id "cmt-ada-bake" #:action 'work #:input-of "bake" #:resource-conforms-to "skill-bake"
                   #:effort-quantity (make-measure 2.0 %effort-unit) #:provider "ada" #:at-location "town"))
;; a provider-only labour commitment (no process) — the class the live compile
;; names on stderr and leaves out, without harming the accepts that map.
(define no-proc
  (make-commitment #:id "lc:other:ada" #:action 'work #:resource-conforms-to "skill-bake"
                   #:effort-quantity (make-measure 1.0 %effort-unit) #:provider "ada"))

(define (solve-with-store coms)
  (let ((vat (spawn-vat #:name "accept-pins")))
    (with-vat vat
      (let-values (((scope ps als) (spawn-bread-scope)))
        (for-each (lambda (c) ($ ps 'add-commitment c)) coms)
        ;; 8 bread: a day's demand. The world declares no partition, so it stands
        ;; on ONE day (engine standing-partition) — 8 h a person, not a week's 40.
        (plan-scope->alist scope #:demand '(("bread#town@0" . 8.0)) #:backend 'native-c)))))

(define (bake-hours result) (bread-hours result "bake"))

(display "\n── the live loop: a plan-store accept pins the next solve ──\n")

(define base (solve-with-store '()))
(check "baseline: demand 8 bread wants ~4 bake hours" (> (bake-hours base) 3.0))
(check "baseline runs robust-by-default (singleton scenario)"
       (eq? #t (assq-ref base 'robust)))

(define pinned (solve-with-store (list bake-accept no-proc)))
(check "the accept is a fact: the first-stage plan carries bake = 4.0 runs, exactly"
       (< (abs (- (or (assoc-ref (assq-ref pinned 'first-stage-plan) "bake") 0) 4.0)) 1e-9))
(check "…and the emitted bake work is the accepted 2 hours (deployment split aside)"
       (< (abs (- (bake-hours pinned) 2.0)) 0.05))
(check "…so the plan's bread fill follows the pin down, honestly"
       (< (bake-hours pinned) (bake-hours base)))
(check "a no-process labour commitment is left out loudly, never fatally"
       (pair? (assq-ref pinned 'work)))

;; ── a MATERIAL accept: quantity ÷ the produce flow's per-run output ──────────
;; 6 kg of bread from bake (1 kg/run) pins p|bake|town@0 = 6 runs — the
;; produce-side sibling of the work compile above.
(define bread-accept
  (make-commitment #:id "cmt-bread" #:action 'produce #:output-of "bake" #:resource-conforms-to "bread"
                   #:resource-quantity (make-measure 6.0 "kg") #:provider "ada" #:at-location "town"))
(define mat (solve-with-store (list bread-accept)))
(check "a produce accept pins its process: first-stage bake = 6.0 runs, exactly"
       (< (abs (- (or (assoc-ref (assq-ref mat 'first-stage-plan) "bake") 0) 6.0)) 1e-9))

(test-summary!)
