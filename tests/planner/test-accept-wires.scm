;;; test-accept-wires.scm — the three accept wires around the #:pins seam.
;;;
;;; docs/planning/solve/commitment-horizon.md, "the two accept wires":
;;;   A. accepts->pins (live.scm) — the VF-terms compile: the plan-store's
;;;      in-window work accepts become ((col-key . runs) …), hours divided by
;;;      the process's work coefficient, accepts on one column summing.
;;;   B. #:holds (engine/robust.scm) — the bounded rung: an offer under live
;;;      consideration held as a wall x ≥ v; a hold the program cannot honor
;;;      raises (the feasibility-lapse signal).
;;;   C. seed-deployment / greedy-deploy #:seed #:tentative (uc-matching) —
;;;      an accept consumes its provider's pool entry and books the slot; a
;;;      hold books the slot only, the entry staying for other buckets.
;;;
;;; Fixture = pin-seam-test's farm plus work flows (2 h per run on each grow).
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-accept-wires.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet test harness)
             ((playnet test planner prelude) #:select ())
             (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond scenario)
             ((playnet plan accepts) #:select (accepts->pins))
             (playnet federation uc-matching)
             (playnet pools availability-pool)
             (playnet federation plan-bundle)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 format))

(define spatials (list (place* "farm")))
(define resources
  (list (er "land1" "land" #f #:place "farm" #:qty 1.0 #:unit "ha")))
(define procs (list (rp* "growA" "Grow A (HYV)")
                    (rp* "growB" "Grow B (traditional)")))
(define flows
  (list (consume* "aL" "land" 1.0 "growA" "ha")
        (wk* "aW" "farming" 2.0 "growA")
        (out* "aF" "food" 1.0 "growA")
        (consume* "bL" "land" 1.0 "growB" "ha")
        (wk* "bW" "farming" 2.0 "growB")
        (out* "bF" "food" 1.0 "growB")))
(define demand       '(("food#farm@0" . 5.0)))
(define repro-floors '(("food#farm@0" . 1.0)))
(define rob-scenarios
  (list (make-planning-scenario "normal"  "sc-normal"  0.7 '(("growA" . 4.0) ("growB" . 1.3)) "normal year")
        (make-planning-scenario "drought" "sc-drought" 0.3 '(("growA" . 0.0) ("growB" . 1.2)) "drought year")))

;; a plan-store-shaped work accept, fields in <commitment> order
(define* (mk-accept id #:key (proc "growB") (place "farm") (hours 1.0)
                    (provider "alice") (skill "farming")
                    (end #f) (finished #f) (window #f))
  (make-commitment #:id id #:action 'work #:input-of proc #:resource-conforms-to skill
                   #:effort-quantity (make-measure hours %effort-unit) #:provider provider #:has-end end #:at-location place #:finished finished #:availability-window window))

(define (solve-with . kw)
  (call-with-values
    (lambda () (apply plan-robust-from-records resources '() spatials procs flows
                 #:scenarios rob-scenarios #:first-stage-procs '("growA" "growB")
                 #:repro-floors repro-floors #:demand demand #:per-agent? #f kw))
    (lambda (x fs rc n ns . _)
      (list (first-stage-activity x fs "growA")
            (first-stage-activity x fs "growB")))))

(define (~= a b) (< (abs (- a b)) 1e-4))
(define (raises? thunk) (catch #t (lambda () (thunk) #f) (lambda _ #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; A. accepts->pins — VF terms in, pins out
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── A. the compile: hours → runs on the process's own coefficient ──\n")

(let ((pins (accepts->pins (list (mk-accept "c1" #:hours 1.0)
                                 (mk-accept "c2" #:hours 0.8 #:provider "bo"))
                           flows)))
  (check "two accepts on one column sum, in runs (1.8h / 2h-per-run = 0.9)"
         (and (= 1 (length pins))
              (equal? "p|growB|farm@0" (caar pins))
              (~= 0.9 (cdar pins)))))

(check "a finished accept compiles to nothing"
       (null? (accepts->pins (list (mk-accept "c3" #:finished #t)) flows)))
(check "a window closed before now compiles to nothing"
       (null? (accepts->pins (list (mk-accept "c4" #:end "2026-01-01T00:00:00Z"))
                             flows #:now "2026-08-19T00:00:00Z")))
(check "a window still open at now compiles"
       (= 1 (length (accepts->pins (list (mk-accept "c5" #:end "2027-01-01T00:00:00Z"))
                                   flows #:now "2026-08-19T00:00:00Z"))))
(check "a work accept naming no process raises"
       (raises? (lambda () (accepts->pins (list (mk-accept "c6" #:proc #f)) flows))))
;; two different absences, two different answers (accepts.scm carried-processes):
;; a process the store no longer carries has no column to pin — the record is
;; void, said once on the log; a process it DOES carry, with no work flow to turn
;; hours into runs, is a fault in the record and stays one
(check "an accept standing on a process the store no longer carries is void"
       (null? (accepts->pins (list (mk-accept "c7" #:proc "growZ")) flows)))
(check "a carried process without a work flow raises"
       (raises? (lambda ()
                  (accepts->pins (list (mk-accept "c8" #:proc "fallow"))
                                 (cons (consume* "zL" "land" 1.0 "fallow" "ha")
                                       flows)))))

(display "\n── A2. the full loop: plan-store accepts → pins → the solve honors them ──\n")

(let* ((pins (accepts->pins (list (mk-accept "c1" #:hours 1.0)
                                  (mk-accept "c2" #:hours 0.8 #:provider "bo"))
                            flows))
       (r (solve-with #:pins pins)))
  (check "the compiled accepts are a fact of the solve (growB = 0.9)"
         (~= 0.9 (cadr r)))
  (check "the rest re-optimizes under them (land cap holds)"
         (<= (+ (car r) (cadr r)) 1.0001)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; B. #:holds — the bounded rung, as a wall the solve feels
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── B. a hold keeps the offered value available; an impossible one raises ──\n")

(let ((base (solve-with)))
  (check "baseline sits below the hold about to be asked" (< (cadr base) 0.89)))
(let ((held (solve-with #:holds '(("p|growB|farm@0" . 0.9)))))
  (check "the held offer stays available (growB ≥ 0.9)" (>= (cadr held) 0.8999))
  (check "a hold is a floor, never a fix (growB may exceed it)" (<= 0.8999 (cadr held) 1.0001)))
(check "a hold the land cannot honor raises — the feasibility-lapse signal"
       (raises? (lambda () (solve-with #:holds '(("p|growB|farm@0" . 1.5))))))
(check "a homeless hold raises"
       (raises? (lambda () (solve-with #:holds '(("p|growZ|farm@0" . 0.5))))))
(check "#:holds without #:scenarios is refused at the front door"
       (raises? (lambda () (plan-from-records resources '() spatials procs flows
                             #:demand demand #:per-agent? #f
                             #:holds '(("p|growB|farm@0" . 0.5))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; C. deployment seeding — accepts consume, holds reserve
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── C. a seeded person is never assigned twice; a held slot waits ──\n")

(define (fresh-pool)
  (fold (lambda (e p) (pool-add p e)) (make-labour-pool)
        (list (make-entry "alice" "bake" #f "town" 8.0)
              (make-entry "bo"    "bake" #f "town" 8.0))))

(define bake-wi
  (make-intent #:id "wi1" #:action 'work #:input-of "bakery" #:resource-conforms-to "bake"
               #:effort-quantity (make-measure 4.0 %effort-unit) #:at-location "town" #:planned-within "plan-1"))
(define prop (make-rising-proposal "prop-1" "plan-1" "scope-1" '("wi1")))
;; wi-by-prop carries the intents directly:
(define (deploy* . kw)
  (car (apply greedy-deploy (list prop) `(("prop-1" ,bake-wi)) '(("prop-1" . 1))
              (fresh-pool) kw)))

(define first-pick
  (let ((d (deploy*))) (and (= 1 (length d)) (commitment-provider (car d)))))
(define other (if (equal? first-pick "alice") "bo" "alice"))
(check "unseeded, one of the pool's two is assigned" (member first-pick '("alice" "bo")))
(let ((d (deploy* #:seed (list (mk-accept "a1" #:provider first-pick #:skill "bake")))))
  (check "an accept consumes its provider — the assignment moves to the other"
         (and (= 1 (length d)) (equal? other (commitment-provider (car d))))))
(let ((d (deploy* #:tentative (list (mk-accept "h1" #:provider first-pick #:skill "bake")))))
  (check "a hold blocks the slot the same — the assignment moves to the other"
         (and (= 1 (length d)) (equal? other (commitment-provider (car d))))))
(let* ((s1 (seed-deployment (fresh-pool) (hashmap)
                            (list (mk-accept "a1" #:provider "alice" #:skill "bake")) #t))
       (s2 (seed-deployment (fresh-pool) (hashmap)
                            (list (mk-accept "h1" #:provider "alice" #:skill "bake")) #f)))
  (check "an accept removes exactly the provider's own pool entry (bo remains)"
         (equal? '("bo") (map entry-agent (pool-query (car s1) #:skill "bake" #:cell "town"))))
  (check "a hold keeps the pool entry (alice still queryable for other buckets)"
         (member "alice" (map entry-agent (pool-query (car s2) #:skill "bake" #:cell "town"))))
  (check "both book the slot"
         (and (hashmap-ref (cdr s1) "alice|any" #f)
              (hashmap-ref (cdr s2) "alice|any" #f))))
(check "a seed without a provider raises"
       (raises? (lambda () (seed-deployment (fresh-pool) (hashmap)
                                            (list (mk-accept "a2" #:provider #f)) #t))))

(test-summary!)
