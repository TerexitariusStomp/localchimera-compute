;;; reaction-network-test.scm — the unification: a reaction NETWORK is a PLAN.
;;; Two balanced reactions become recipe activities; the convex engine solves the
;;; FLUX distribution that meets a demand under conservation — flux-balance
;;; analysis through the planner we already have, no new solver. The pathway:
;;;   R1: 2 C + O2 → 2 CO      R2: 2 CO + O2 → 2 CO2     (demand CO2)
;;; CO is an intermediate (R1 makes it, R2 burns it); C and O2 are boundary
;;; inputs (stock); CO2 is the deliverable. A tiny per-reaction labour cost makes
;;; the fluxes the unique minimum-flux solution (parsimonious FBA).
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/planner/reaction-network-test.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet observation observer) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet knowledge catalogues substances)
             (goblins) (goblins vat)
             (srfi srfi-1))

;; build the network from balanced reactions (the chemistry→VF bridge)
(define-values (procs rxn-flows net)
  (reaction-network->records '(("r1" ("C" "o2") ("co"))
                               ("r2" ("co" "o2") ("co2")))
                             "carbon-net" "co2"))
;; parsimonious FBA: a vanishing labour cost per reaction → minimum-total-flux
;; (unique, no futile cycles). A shared "lab" skill, ample stock.
(define (wk id proc) (make-recipe-flow #:id id #:action 'work #:resource-conforms-to "lab"
                                       #:effort-quantity (make-measure 0.05 %effort-unit)
                                       #:recipe-input-of proc))
(define flows (append rxn-flows (list (wk "w-r1" "r1") (wk "w-r2" "r2"))))
(define recipes (list net))
(define agents (list (make-agent #:id "w" #:type 'person #:primary-location "town"
                                 #:classified-as '())))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define (raise-event id rid spec acct qty)
  (make-economic-event #:id id #:action 'raise #:resource-inventoried-as rid #:resource-conforms-to spec #:provider acct #:receiver acct
                       #:resource-quantity (make-measure qty "mol") #:at-location "town"))

(define plan
  (with-vat (spawn-vat #:name "rxnnet")
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ($ obs 'record-event (raise-event "ev-c"  "c-1"  "C"   "scope" 1000.0))   ; boundary inputs
      ($ obs 'record-event (raise-event "ev-o2" "o2-1" "o2"  "scope" 1000.0))
      ($ obs 'record-event (raise-event "ev-lab" "lab-1" "lab" "w"   1000.0))   ; pFBA labour stock
      (let* ((as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                                 (get-process-chain . ,(lambda (r) procs))
                                 (flows-for-process
                                  . ,(lambda (pid)
                                       (cons (filter (lambda (fl)
                                                       (or (equal? (recipe-flow-recipe-input-of fl) pid)
                                                           (equal? (recipe-flow-recipe-output-of fl) pid)))
                                                     flows)
                                             '()))))))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (plan-scope->alist scope #:demand '(("co2#town@0" . 10.0)))))))

(define mat (or (assq-ref plan 'material) '()))
(define (sum-qty action spec)
  (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) action) (equal? (assq-ref m 'conforms-to) spec))
                          (+ a (or (assq-ref m 'quantity) 0)) a))
        0 mat))
(define (pos action spec) (list-index (lambda (m) (and (eq? (assq-ref m 'action) action)
                                                       (equal? (assq-ref m 'conforms-to) spec))) mat))
(define (~= a b) (< (abs (- a b)) 1e-2))
;; atom counts of an element across the whole material list, by side
(define (atoms action elt)
  (fold (lambda (m a) (if (eq? (assq-ref m 'action) action)
                          (+ a (* (or (assq-ref m 'quantity) 0)
                                  (or (assq-ref (or (formula (assq-ref m 'conforms-to)) '()) elt) 0))) a))
        0 mat))

(display "\n── a reaction network solves as a flux/plan (FBA via the engine) ──\n")

;; the engine met the demand for the product
(check-pred "demand met (met = 1.0)" (~= (or (assq-ref plan 'met) 0) 1.0))
(check-pred "≥ 10 mol CO₂ delivered" (>= (sum-qty 'produce "co2") 9.99))

;; the network is COUPLED: R1 makes the intermediate CO, R2 burns it
(check-pred "R1 produces the intermediate CO (output-of r1)"
            (> (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'produce)
                                            (equal? (assq-ref m 'conforms-to) "co")
                                            (equal? (assq-ref m 'output-of) "r1")) (+ a (assq-ref m 'quantity)) a)) 0 mat) 0))
(check-pred "R2 consumes CO (input-of r2)"
            (> (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'consume)
                                            (equal? (assq-ref m 'conforms-to) "co")
                                            (equal? (assq-ref m 'input-of) "r2")) (+ a (assq-ref m 'quantity)) a)) 0 mat) 0))
(check-pred "CO is produced before it is consumed (R1 precedes R2)"
            (let ((p (pos 'produce "co")) (c (pos 'consume "co"))) (and p c (< p c))))

;; CONSERVATION — atoms in = atoms out, counting the deliverable AND any
;; accumulated intermediate (nothing is created or destroyed; carbon the network
;; over-makes as CO simply piles up — a stock, not a leak). Atom-exact, formula-
;; derived (CO₂=2 O, CO=1 O, O₂=2 O, C=1 C …).
(check-pred "carbon conserved: C consumed = C produced (CO + CO₂)"
            (~= (atoms 'consume "C") (atoms 'produce "C")))
(check-pred "oxygen conserved: O consumed (O₂) = O produced (CO + CO₂)"
            (~= (atoms 'consume "O") (atoms 'produce "O")))

(test-summary!)
