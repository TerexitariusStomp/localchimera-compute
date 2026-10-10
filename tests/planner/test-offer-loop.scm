;;; test-offer-loop.scm — the bounded rung, live: an offer holds its column
;;; across re-solves, hands over to the pin on accept, and lapses loudly.
;;;
;;; docs/planning/solve/commitment-horizon.md. Fixture: (playnet test planner bread)
;;; — the one bread economy, a REAL plan-store and alert-store in a mocked
;;; scope. The other concerns of the arc have their own files:
;;;   test-commitment-endings.scm   release / expiry / the knobs / the window
;;;   test-horizon-read.scm         the solve's horizon cache, the escalation door
;;;   test-offer-doors.scm          present-offers, accept-regret, the fresh check
;;;   test-commitment-drift.scm     dated facts, κ, the drift comparison

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet planner vf schemas)
             (playnet planner scope live)
             (playnet planner plan accepts)
             (playnet planner doors offers)
             (playnet planner plan store)
             (playnet planner execution alerts)
             (playnet test planner bread)
             ((playnet utils clock) #:select (now instant->unix))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define vat (spawn-vat #:name "offer-loop"))
(define-values (scope ps als) (with-vat vat (spawn-bread-scope)))
(define (solve) (with-vat vat (plan-scope->alist scope #:demand '(("bread#town@0" . 4.0)) #:backend 'native-c)))
(define (bake-hours r) (bread-hours r "bake"))
;; 4 offered hours = 8 runs: above the 4 demanded, and inside ONE day — the
;; world declares no partition, so it stands on a day of 8 h a person, and 8
;; runs of bread ask the farmer for ~6.6 of them.
(define bake-row '((input-of . "bake") (effort . 4.0) (conforms-to . "skill-bake")
                   (at-location . "town")))


(display "\n── 1. an open offer HOLDS its column across re-solves ──\n")

(define base (solve))
(check "baseline: demand 4 bread wants ~2 bake hours" (< (bake-hours base) 3.0))

(define pid (with-vat vat (offer-work scope bake-row "ada")))
(check "the offer stands: a directed proposal with an acceptance window"
       (equal? (list pid) (with-vat vat (map (lambda (r) (proposal-id (car r)))
                                             (open-work-offers scope)))))
(define held (solve))
(check "the hold rides the solve: 4 offered hours held open (8 runs > the 4 demanded)"
       (> (bake-hours held) 3.9))

(display "\n── 2. accept → the hold releases and the pin takes over ──\n")

(with-vat vat ($ ps 'accept-proposal pid
                 '((provider . "ada") (receiver . "town"))
                 '((accepting-agent-id . "ada"))))
(check "the accepted intent is finished — no open offer remains"
       (null? (with-vat vat (open-work-offers scope))))
(define pinned (solve))
(check "the commitment pins the next solve: first-stage bake = 8.0 runs, exactly"
       (< (abs (- (or (assoc-ref (assq-ref pinned 'first-stage-plan) "bake") 0) 8.0)) 1e-9))

(display "\n── 3. urgency-lapse: a closed window ends the offer, named once ──\n")

;; an offer whose window already closed, laid directly (offer-work derives
;; its window from the forcing point, so it never authors an expired one)
(with-vat vat
  (let ((iid "offer:ada:mill@") (nowu (instant->unix (now))))
    ($ ps 'add-intent (make-intent #:id iid #:action 'work #:input-of "mill"
                                   #:effort-quantity (make-measure 0.3 %effort-unit)))
    ($ ps 'add-proposal (make-proposal #:id (string-append "prop-" iid) #:name "o"
                          #:has-end (number->string (- nowu 60)) #:created (now) #:purpose 'offer
                          #:publishes (list iid) #:proposed-to '("ada")))))
(check "an expired offer is not open" (null? (with-vat vat (open-work-offers scope))))
(check "…its published intent is FINISHED — it left every enumeration by state"
       (with-vat vat (intent-finished ($ ps 'get-intent "offer:ada:mill@"))))
(with-vat vat (open-work-offers scope))   ; a second sweep must not re-alert
(check "…and its lapse lands on the alert rail exactly once"
       (= 1 (length (with-vat vat ($ als 'of-kind 'offer-lapsed)))))

(display "\n── 4. the governed bound on open holds refuses, loudly ──\n")

(with-vat vat (offer-work scope '((input-of . "grow") (effort . 0.5)) "farmer"))
(check "past the bound the offer is refused — holding everything is mass-freezing"
       (raises? (lambda () (with-vat vat (offer-work scope bake-row "bob" #:max-open 1)))))
(check "re-offering the SAME slot passes the bound — a replacement, not a new hold"
       (string? (with-vat vat (offer-work scope '((input-of . "grow") (effort . 1.0)) "farmer"
                                          #:max-open 1))))

(display "\n── 5. feasibility-lapse: an unhonorable hold lapses, the solve stands ──\n")

(with-vat vat (offer-work scope '((input-of . "bake") (effort . 1000.0)) "bob"))
(define freed (solve))
(check "the re-solve without holds stands — a plan, not a crash"
       (pair? (assq-ref freed 'work)))
(check "every holding offer feasibility-lapsed on the rail"
       (pair? (with-vat vat ($ als 'of-kind 'offer-infeasible))))
(check "a lapsed offer holds nothing: the next solve carries only the §2 pin (8 runs, not 2000)"
       (< (abs (- (bake-hours (solve)) 4.0)) 0.1))
(check "re-presenting the lapsed slot re-opens it BY STATE (the intent re-adds unfinished)"
       (let ((p (with-vat vat (offer-work scope '((input-of . "bake") (effort . 0.5)) "bob"))))
         (member p (with-vat vat (map (lambda (r) (proposal-id (car r))) (open-work-offers scope))))))

(test-summary!)
