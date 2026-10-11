;;; test-pin-seam.scm — #:pins: accepted commitments as hand-decided columns.
;;;
;;; docs/planning/solve/commitment-horizon.md: an accept is a col-fixed by a human
;;; instead of the search tree — a first-stage fact every scenario branch
;;; shares. The seam under test is robust-assemble's #:pins: pins enter after
;;; every block build (each block's ingest resets the world), pass through the
;;; same substitute-fixed door the discrete layer uses, and an unmeetable pin
;;; RAISES — a floor starved by a pin is refused, never solved around.
;;;
;;; Fixture = robust-records-test's farm: 1 ha, growA (4.0 normal / 0.0
;;; drought) vs growB (1.3 / 1.2), food floor 1.0 in every branch.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-pin-seam.scm

(use-modules (playnet test harness)
             ((playnet test planner prelude) #:select ())   ; load-time setup only — the harness's `check` counts
             (playnet solve engine) (playnet solve robust) (playnet solve plan)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge dsl shorthand)
             (srfi srfi-1)
             (ice-9 format))

(define spatials (list (place* "farm")))
(define resources (list (er "land1" "land" #f #:place "farm" #:unit "ha")))
(define procs (list (rp* "growA" "Grow A (HYV)")
                    (rp* "growB" "Grow B (traditional)")))
(define flows
  (list (consume* "aL" "land" 1.0 "growA" "ha")
        (out* "aF" "food" 1.0 "growA")
        (consume* "bL" "land" 1.0 "growB" "ha")
        (out* "bF" "food" 1.0 "growB")))
(define demand       '(("food#farm@0" . 5.0)))
(define repro-floors '(("food#farm@0" . 1.0)))
(define rob-scenarios
  (list (make-planning-scenario "normal"  "sc-normal"  0.7 '(("growA" . 4.0) ("growB" . 1.3)) "normal year")
        (make-planning-scenario "drought" "sc-drought" 0.3 '(("growA" . 0.0) ("growB" . 1.2)) "drought year")))

(define (solve-plan . pins)
  (call-with-values
    (lambda () (apply plan-robust-from-records resources '() spatials procs flows
                 #:scenarios rob-scenarios #:first-stage-procs '("growA" "growB")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f
                 (if (pair? pins) (list #:pins (car pins)) '())))
    (lambda (x fs rc n ns . _)
      (list (first-stage-activity x fs "growA")
            (first-stage-activity x fs "growB")))))

(define (~= a b) (< (abs (- a b)) 1e-4))
(define (raises? thunk) (catch #t (lambda () (thunk) #f) (lambda _ #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Baseline — the known robust point, no pins
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. baseline: diversity from the floor, land at cap ──\n")

(define base (solve-plan))
(check "growB defends the drought floor (1.2·B ≥ 1)" (>= (* 1.2 (cadr base)) 0.9999))
(check "land at cap" (~= 1.0 (+ (car base) (cadr base))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. A feasible pin is honored; the rest re-optimizes around the fact
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. pin growB = 0.90 — a hand-decided first-stage fact ──\n")

(define pinned (solve-plan '(("p|growB|farm@0" . 0.90))))
(check "the pin is a fact (growB reads 0.90)" (~= 0.90 (cadr pinned)))
(check "the rest re-optimized under it (growA ≤ remaining land)"
       (<= (car pinned) 0.1001))
(check "drought floor still held through the pin (1.2·0.90 ≥ 1)"
       (>= (* 1.2 (cadr pinned)) 1.0))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. An unmeetable pin raises — refused, never solved around
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. refusals: starving, homeless, recourse, negative ──\n")

;; growB = 0.20 → drought food 0.24 < floor 1.0: no plan holds the floor.
(check "a floor-starving pin raises"
       (raises? (lambda () (solve-plan '(("p|growB|farm@0" . 0.20))))))
;; a key no column of this assembly carries
(check "a homeless pin raises"
       (raises? (lambda () (solve-plan '(("p|growZ|farm@0" . 0.5))))))
;; a real column that is NOT first-stage here (growB left to recourse)
(check "a recourse pin raises"
       (raises? (lambda ()
                  (plan-robust-from-records resources '() spatials procs flows
                    #:scenarios rob-scenarios #:first-stage-procs '("growA")
                    #:repro-floors repro-floors #:demand demand #:per-agent? #f
                    #:pins '(("p|growB|farm@0" . 0.9))))))
(check "a negative pin raises"
       (raises? (lambda () (solve-plan '(("p|growB|farm@0" . -1.0))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. The canonical entry: plan-from-records #:scenarios threads #:pins
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. plan-from-records #:scenarios #:pins — the one front door ──\n")

(define pfr-report
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios rob-scenarios #:first-stage-procs '("growA" "growB")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f
                 #:pins '(("p|growB|farm@0" . 0.90))))
    (lambda (x cols idx . rest) (last rest))))
(define pfr-fs (or (assoc-ref pfr-report 'first-stage-plan) '()))
(check "the report's first-stage plan carries the pinned fact"
       (~= 0.90 (or (assoc-ref pfr-fs "growB") 0)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. A pin rides the DISCRETE search: it joins every node's fixings
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. #:whole growA + pin growB — a fact in every node of the tree ──\n")

(define disc-report
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios rob-scenarios #:first-stage-procs '("growA" "growB")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f
                 #:whole '("growA")
                 #:pins '(("p|growB|farm@0" . 0.90))))
    (lambda (x cols idx . rest) (last rest))))
(define disc-fs (or (assoc-ref disc-report 'first-stage-plan) '()))
(check "the pin is a fact under the search too (growB = 0.90)"
       (~= 0.90 (or (assoc-ref disc-fs "growB") 0)))
(check "the searched column is integral (growA a whole count on 0.1 ha ⇒ 0)"
       (let ((a (or (assoc-ref disc-fs "growA") 0)))
         (< (abs (- a (round a))) 1e-3)))
(check "the certificate names the discrete search"
       (let ((c (assq-ref disc-report 'certificate)))
         (and (list? c) (assq 'discrete c) #t)))

(test-summary!)
