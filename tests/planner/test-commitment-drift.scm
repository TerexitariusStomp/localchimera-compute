;;; test-commitment-drift.scm — the drift question: declarations, lapses and
;;; endings are dated facts on one rail, every rate is one read, and κ meets
;;; the rate at which commitments come apart — one window, one clock.
;;;
;;; docs/planning/solve/commitment-horizon.md (renegotiation cadence). Fixture:
;;; (playnet test planner bread). The history here is built ON PURPOSE
;;; and asserted directly — no section depends on another's residue.

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (playnet plan accepts)
             (playnet doors offers)
             (playnet plan store)
             (playnet test planner bread)
             ((playnet utils clock) #:select (now instant->unix))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define vat (spawn-vat #:name "drift"))
(define-values (scope ps als) (with-vat vat (spawn-bread-scope)))
(define nowu (instant->unix (now)))
(define (solve) (with-vat vat (plan-scope->alist scope #:demand '(("bread#town@0" . 4.0)) #:backend 'native-c)))
(define (accept! id proc hours provider . end)
  (with-vat vat ($ ps 'add-commitment
                   (make-commitment #:id id #:action 'work #:input-of proc #:resource-conforms-to (string-append "skill-" proc)
                                    #:effort-quantity (make-measure hours %effort-unit) #:provider provider #:receiver "town" #:has-end (and (pair? end) (car end)) #:at-location "town"))))


(display "\n── 1. declarations are dated facts — κ is a READ, not a meter ──\n")

(with-vat vat
  ($ ps 'add-intent (make-intent #:id "churn-a" #:action 'work #:input-of "mill" #:resource-conforms-to "skill-mill"
                                 #:effort-quantity (make-measure 0.3 %effort-unit)
                                 #:at-location "town"))
  ($ ps 'remove-intent "churn-a"))
(check "an add and a remove are two dated facts on the rail"
       (= 2 (length (with-vat vat (dated-facts ps 'declared 0 (+ nowu 3600))))))
(check "κ reads off them — declarations per day over ANY window asked for"
       (= (/ 2 7.0) (with-vat vat (rate-of ps 'declared nowu 7.0))))


(display "\n── 2. the history, built on purpose ──\n")

;; two lapses: one urgency (a window laid closed), one feasibility
(with-vat vat
  (let ((iid "offer:ada:mill@"))
    ($ ps 'add-intent (make-intent #:id iid #:action 'work #:input-of "mill"
                                   #:effort-quantity (make-measure 0.3 %effort-unit)))
    ($ ps 'add-proposal (make-proposal #:id (string-append "prop-" iid) #:name "o"
                          #:has-end (number->string (- nowu 60)) #:created (now) #:purpose 'offer #:publishes (list iid) #:proposed-to '("ada")))))
(with-vat vat (open-work-offers scope))                                  ; the urgency sweep
(with-vat vat (offer-work scope '((input-of . "bake") (effort . 1000.0)) "bob"))
(solve)                                                                  ; the feasibility lapse
;; three endings: a release, a fulfilment, an expiry
(accept! "cmt-rel" "bake" 1.0 "ada")
(with-vat vat ($ ps 'release-commitment "cmt-rel" "ada" nowu))
(accept! "cmt-ful" "bake" 1.0 "ada")
(with-vat vat ($ ps 'end-commitment "cmt-ful" 'fulfilled nowu))
(accept! "cmt-exp" "mill" 0.3 "bob" (- nowu 3600))
(solve)                                                                  ; the expiry sweep
;; the sweeps date their facts on the clock as it stands when they run, so the
;; window that holds the whole history ends at a moment read AFTER it is built
(define builtu (instant->unix (now)))
(check "two lapses stand as dated facts" (= 2 (length (with-vat vat (dated-facts ps 'lapsed 0 (+ nowu 3600))))))
(check "three endings stand, one of each kind"
       (equal? '((released . 1) (fulfilled . 1) (expired . 1))
               (with-vat vat (how-commitments-end ps builtu 7.0))))


(display "\n── 3. κ against the lapse and apart rates — one read, one clock ──\n")

(define drift (with-vat vat (commitment-drift ps)))
(check "lapses per day read off the facts" (= (/ 2 7.0) (assq-ref drift 'lapse-rate)))
(check "coming apart = released + expired; fulfilment is the rung doing its job"
       (= (/ 2 7.0) (assq-ref drift 'apart-rate)))
(check "κ reads off the same rail, same clock, same window"
       (= (assq-ref drift 'kappa) (with-vat vat (rate-of ps 'declared (assq-ref drift 'as-of) 7.0))))
(check "the ratios a cadence rule would be stated in are real numbers"
       (and (number? (assq-ref drift 'lapse/kappa)) (number? (assq-ref drift 'apart/kappa))))
(check "an epoch that ended is askable from the ledger: one ending BEFORE today's facts sees none, one ending now sees them all"
       (let ((before (with-vat vat (commitment-drift ps #:window-days 7.0 #:at (- nowu (* 8 86400)))))
             (here   (with-vat vat (commitment-drift ps #:window-days 7.0 #:at builtu))))
         (and (= 0 (assq-ref before 'lapse-rate)) (= 0 (assq-ref before 'apart-rate))
              (= (- nowu (* 8 86400)) (assq-ref before 'as-of))
              (= (/ 2 7.0) (assq-ref here 'lapse-rate)))))
(check "the window is a parameter of the question: a wider window, a smaller rate"
       (< (assq-ref (with-vat vat (commitment-drift ps #:window-days 70.0)) 'lapse-rate)
          (assq-ref drift 'lapse-rate)))
(check "a re-presented slot re-opens by state and its earlier lapse STAYS a fact: it happened"
       (begin (with-vat vat (offer-work scope '((input-of . "bake") (effort . 0.5)) "bob"))
              (and (pair? (with-vat vat (open-work-offers scope)))
                   (= 2 (length (with-vat vat (dated-facts ps 'lapsed 0 (+ nowu 3600))))))))

(test-summary!)
