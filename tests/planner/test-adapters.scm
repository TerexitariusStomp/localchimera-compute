;;; test-adapters.scm — the adapter as a fold: spawn cheaply, retire cleanly, rotate.
;;;
;;; Proves the operational substrate the property/law appendix assumes: a legal
;;; shell is mintable (Agent + rendered applications from canonical data),
;;; retire-able (a programmatic proof it holds nothing worth keeping), and
;;; rotatable (regenerate the same filings against a fresh Agent). Pure data ⇒
;;; no blake3.
;;;
;;; Run: guile -L module tests/planner/test-adapters.scm

(use-modules (playnet test harness) (playnet observation observer) (playnet vf schemas)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal compliance)) (use-modules (playnet legal filings))
(use-modules (playnet legal adapters)) (use-modules (playnet knowledge recipes compliance-food))

;; the door this mask opens: public food-vending in foodville.
(define crossings '(food-vending))
(define place-path '("foodville" "world"))
(define rules (list (compliance-food-rule)))
;; one filing template, keyed by demand-name (the join key).
(define templates
  (list (cons "Food Establishment Permit"
              (filing-template "Food Establishment Permit Application"
                #:jurisdiction 'foodville #:demand-name "Food Establishment Permit"
                #:version "2026.1"
                #:render (lambda (c) `((applicant . ,(assq-ref c 'adapter-name))
                                       (site      . ,(assq-ref c 'site))))
                #:source "foodville Health Code" #:confidence 'verified))))
(define canonical '((site . "12 Market St")))

;; a held credential / a substantive resource (a means of production), by class.
(define (held id spec holder class)
  (make-economic-resource #:id id #:name spec #:conforms-to spec #:classified-as (list class)
    #:onhand-quantity (make-measure 1 "u") #:current-location (make-measure 1 "u") #:primary-accountable holder #:state "active"))

;;; ─── SPAWN ────────────────────────────────────────────────────────────────
(define spawned
  (spawn-adapter #:id "mask:foodco-1" #:name "FoodCo Adapter 1" #:jurisdiction 'foodville
                 #:crossings crossings #:place-path place-path #:act 'food
                 #:rules rules #:templates templates #:canonical canonical))
(define ag   (adapter-spawn-agent spawned))
(define apps (adapter-spawn-applications spawned))

(display "\n── SPAWN cheaply: Agent + applications rendered from canonical data ──\n")
(format #t "  agent: ~a   entity-needs: ~s\n" (agent-id ag) (adapter-spawn-entity-needs spawned))
(check-pred "the spawned mask is an adapter Agent" (adapter? ag))
(check "the bill named the entity door it must clear"
       (adapter-spawn-entity-needs spawned) '("Food Establishment Permit"))
(check "one application was rendered from canonical data" (length apps) 1)
(check-pred "…a deterministic, content-addressed filing document"
            (let ((doc (cdar apps)))
              (and (equal? (economic-resource-conforms-to doc) "filing")
                   (string-prefix? "E" (economic-resource-id doc)))))

;;; ─── RETIRE + ROTATE, over a live observer ──────────────────────────────────
(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ;; grant the permit into mask 1's custody
      ($ obs 'seed-resource (held "res:permit-1" "Food Establishment Permit" "mask:foodco-1" "credential"))
      (let* (;; while the door is OPEN, the permit is required → not stale
             (stale-open (held-but-not-required obs "mask:foodco-1" '("Food Establishment Permit")))
             ;; retiring the door → the permit is now held-but-not-required
             (retire-1 (call-with-values
                         (lambda () (retire-adapter obs "mask:foodco-1" #:required-spec-ids '())) list))
             ;; now give the mask a SUBSTANTIVE holding (a means of production)
             (_ ($ obs 'seed-resource (held "res:oven" "Commercial Oven" "mask:foodco-1" "means-of-production")))
             (retire-2 (call-with-values
                         (lambda () (retire-adapter obs "mask:foodco-1" #:required-spec-ids '())) list))
             ;; ROTATE: same door, fresh Agent
             (rot (call-with-values
                    (lambda () (rotate-adapter #:old-id "mask:foodco-1" #:new-id "mask:foodco-2"
                                               #:jurisdiction 'foodville #:crossings crossings
                                               #:place-path place-path #:act 'food #:rules rules
                                               #:templates templates #:canonical canonical))
                    list)))
        (list stale-open retire-1 retire-2 rot)))))

(define stale-open (list-ref out 0))
(define retire-1   (list-ref out 1))     ; (hollow? stale substance) while it holds only the permit
(define retire-2   (list-ref out 2))     ; …after it also holds an oven
(define rot        (list-ref out 3))     ; (fresh-spawn subject-at)

(display "\n── RETIRE cleanly: the hollow check + held-but-not-required ──\n")
(check-pred "while its door is open, the permit is NOT stale" (null? stale-open))
(check "retiring the door frees exactly the permit (held-but-not-required)"
       (map economic-resource-id (cadr retire-1)) '("res:permit-1"))
(check-pred "an adapter holding only credentials is HOLLOW — safe to dissolve" (car retire-1))
(check-pred "…but once it holds a means of production it is NOT hollow"
            (not (car retire-2)))
(check "…and the oven is named as the substance that blocks a clean dissolution"
       (map economic-resource-id (caddr retire-2)) '("res:oven"))

(display "\n── ROTATE at will: same filings, fresh Agent, re-pointed custody ──\n")
(define fresh (car rot))
(define subject-at (cadr rot))
(check-pred "rotation mints a fresh adapter Agent" (adapter? (adapter-spawn-agent fresh)))
(check "…with the same door to clear"
       (adapter-spawn-entity-needs fresh) '("Food Establishment Permit"))
(check "…and re-renders the application (one, from the same template)"
       (length (adapter-spawn-applications fresh)) 1)
(check "the returned subject-at re-points the decorate's custody at the new mask"
       (subject-at "rp-cf-vend" "foodville@0") "mask:foodco-2")

(display "\n")
(test-summary!)
