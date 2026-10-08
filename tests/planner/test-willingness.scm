;;; test-willingness.scm — the solver offers first; willingness gates materialization.
;;;
;;; The humane labour loop, proven at the convex core (no UI, no actors — like
;;; coherence-test). ONE convex program, bound TWO ways by ONE predicate *willing?*:
;;;
;;;   SOLVE #1 (cold, ungated, *willing?* ≡ #t) = the EMP-fair CANDIDATE FIELD.
;;;       Over ALL reachable workers: per need, who'd help most and their fair share.
;;;       This is the OFFER — "you'd be helpful here", an invitation, not a commitment.
;;;
;;;   SOLVE #2 (warm, gated to the WILLING) = the budget-bounded MATERIALIZATION.
;;;       Only workers who opted in carry flow; the single hours-budget bounds each
;;;       (a worker can't exceed their hours however many offers they marked willing);
;;;       EMP spreads the feasible optimum fairly across the willing.
;;;
;;; Scenario: care@town needs 50 doctor-hours; three doctors (Ada, Ben, Cy), 40 hrs each.
;;;   (1) FIELD — cold solve exposes all three as candidates per need (fair shares).
;;;   (2) GATE  — willing={Ada,Ben}: only those two materialize (Cy carries ZERO),
;;;               demand still met, EMP splits ~25/25 (≤ each 40-hr budget).
;;;   (3) BUDGET — willing={Ada}: the single bundle cap binds; Ada delivers exactly 40,
;;;               never her 50-hour over-subscription. Materialization respects the limit.
;;;   (4) DECLINE→RE-SOLVE — from {Ada,Ben,Cy}, Cy withdraws; warm re-solve rebalances
;;;               feasibly onto {Ada,Ben}, Cy drops to zero, budgets still respected.
;;;
;;; Run:  guile -L module/playnet/planner module/playnet/planner/willingness-test.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver)
             (playnet planner vf schemas))

(define DEMAND 50.0)
(define BUDGET 40.0)

;; One cold/warm solve under a given willingness gate. Returns the field (candidates),
;; the materialized hours per worker, and the total care delivered. warm = a prior x.
(define (solve-willing willing? warm)
  ;; treat: 1 doctor-hour → 1 care.  (name outputs inputs hours skills)
  (declare-world! #:places '(("town" 0.0 0.0))
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doctor" 1.0))))
                  #:workers
                    (list (list "Ada" '("doctor") (cell "town" 0) BUDGET)
                          (list "Ben" '("doctor") (cell "town" 0) BUDGET)
                          (list "Cy"  '("doctor") (cell "town" 0) BUDGET)))
  (set! *emp-rho* 0.02)                                   ; moderate EMP ⇒ fair spread across the willing
  (hash-set! *demand* (lg "care" (cell "town" 0)) DEMAND)
  (set! *willing?* willing?)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values (lambda () (solve forms labform (or warm (located-warm cols ncol idx)))) list))))
        (call-with-values (lambda () (plan->work x cols idx))
          (lambda (ints coms cands)
            (let ((hours (make-hash-table)))
              (for-each (lambda (c)
                          (let ((w (commitment-provider c)))
                            (hash-set! hours w (+ (hash-ref hours w 0.0)
                                                  (measure-has-numerical-value (commitment-effort-quantity c))))))
                        coms)
              (list cands hours
                    (fold (lambda (c a) (+ a (measure-has-numerical-value (commitment-effort-quantity c)))) 0.0 coms)
                    x cols idx))))))))

(define (who-of res w) (hash-ref (cadr res) w 0.0))
(define (field-of res) (caddar res))          ; candidates: ((need . ((w share oid)…))…)
(define (delivered res) (caddr res))
(define (warm-of res) (list-ref res 3))
(define (cands res) (car res))

(define ALL  (lambda (w s c) #t))
(define (only . names) (lambda (w s c) (and (member w names) #t)))

;; ── (1) the cold FIELD: every reachable doctor is a candidate ──
(define r-field (solve-willing ALL #f))
(define candidates (cands r-field))
(define field-workers
  (delete-duplicates (append-map (lambda (kv) (map car (cdr kv))) candidates)))

;; ── (2) GATE to {Ada,Ben}: only those two materialize, Cy zero, demand met ──
(define r-gate (solve-willing (only "Ada" "Ben") #f))

;; ── (3) BUDGET: willing={Ada} only — the single bundle cap binds at 40 ──
(define r-budget (solve-willing (only "Ada") #f))

;; ── (4) DECLINE → warm re-solve: from all-willing, Cy withdraws; rebalance ──
(define r-all (solve-willing ALL #f))
(define r-redo (solve-willing (only "Ada" "Ben") (warm-of r-all)))   ; warm re-solve, Cy gone

(format #t "~%── care@town needs ~,0f doctor-hours · 3 doctors · ~,0f-hr budget each ──~%" DEMAND BUDGET)
(format #t "~%  (1) FIELD  candidates/need = ~a~%" field-workers)
(format #t "  (2) GATE   willing={Ada,Ben}: Ada ~,1f  Ben ~,1f  Cy ~,1f   (delivered ~,1f/~,0f)~%"
        (who-of r-gate "Ada") (who-of r-gate "Ben") (who-of r-gate "Cy") (delivered r-gate) DEMAND)
(format #t "  (3) BUDGET willing={Ada}:     Ada ~,1f   (capped at ~,0f; delivered ~,1f/~,0f)~%"
        (who-of r-budget "Ada") BUDGET (delivered r-budget) DEMAND)
(format #t "  (4) DECLINE willing={Ada,Ben} after Cy withdraws: Ada ~,1f  Ben ~,1f  Cy ~,1f~%"
        (who-of r-redo "Ada") (who-of r-redo "Ben") (who-of r-redo "Cy"))

(let* ((c1 (and (member "Ada" field-workers) (member "Ben" field-workers) (member "Cy" field-workers)
                (>= (length candidates) 1)))                              ; field offers all three
       (c2 (and (> (who-of r-gate "Ada") 1.0) (> (who-of r-gate "Ben") 1.0)
                (< (who-of r-gate "Cy") 1e-3)))                           ; gate honoured: Cy carries nothing
       (c2b (> (delivered r-gate) (* 0.95 DEMAND)))                       ; demand substantially met (EMP leaves a sliver as overwork-protection)
       (c2c (< (abs (- (who-of r-gate "Ada") (who-of r-gate "Ben"))) 5.0)) ; EMP-fair among the willing
       (c3 (and (<= (who-of r-budget "Ada") (+ BUDGET 1e-2))             ; single bundle cap binds
                (< (delivered r-budget) (- DEMAND 1.0))                  ; can't exceed budget ⇒ demand unmet
                (> (who-of r-budget "Ada") (- BUDGET 1.0))))             ; works up to the cap
       (c4 (and (< (who-of r-redo "Cy") 1e-3)                            ; declined worker drops out
                (> (delivered r-redo) (* 0.95 DEMAND))                   ; open part rebalances feasibly
                (<= (who-of r-redo "Ada") (+ BUDGET 1e-2))
                (<= (who-of r-redo "Ben") (+ BUDGET 1e-2))))             ; budgets still respected
       (ok (and c1 c2 c2b c2c c3 c4)))
  (format #t "~%  [~a] cold FIELD exposes every reachable doctor as a candidate (the offer)~%" (if c1 "✓" "✗"))
  (format #t "  [~a] GATE honoured: only willing {Ada,Ben} materialize, Cy carries zero~%" (if c2 "✓" "✗"))
  (format #t "  [~a] gated materialization substantially meets demand                  (~,1f/~,0f)~%" (if c2b "✓" "✗") (delivered r-gate) DEMAND)
  (format #t "  [~a] EMP spreads the feasible optimum fairly across the willing        (|Ada−Ben| < 5h)~%" (if c2c "✓" "✗"))
  (format #t "  [~a] single bundle hour-cap BINDS: Ada ≤ ~,0f however over-subscribed   (Ada ~,1f, met ~,1f)~%" (if c3 "✓" "✗") BUDGET (who-of r-budget "Ada") (delivered r-budget))
  (format #t "  [~a] decline → warm re-solve rebalances feasibly; declined worker drops~%" (if c4 "✓" "✗"))
  (format #t "~%  ~a the solver offers first; willingness gates materialization; budgets always bind~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
