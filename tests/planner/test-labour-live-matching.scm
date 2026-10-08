;;; test-labour-live-matching.scm — match-labour!: the roster meets the rising
;;; plans at the UC, and the descent lands each commitment where it belongs.
;;;
;;; The whole live circle in one test:
;;;   declare-skill/availability → the fold climbs (labour-pool-live-test)
;;;   a scope's rising proposal  → match-labour! solves over the UC pool
;;;   the flat deployment        → the descent routes by plan, and ONLY the
;;;                                owning scope's plan-store receives it
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/planner/test-labour-live-matching.scm

(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas) (playnet planner beyond schedules)
             (playnet planner doors service)
             (playnet planner federation plan-bundle)
             (playnet planner facts availability)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))

(define (window from to)
  (make-availability-window #f #f #f (list (make-time-range from to))))

(define vat (spawn-vat))

(with-vat vat

  (define scopeA (spawn-scope-root "Granary"))
  (define scopeB (spawn-scope-root "Table"))
  (define svc    (spawn ^planner-service (hashmap)))

  ($ ($ scopeA 'agent-store) 'add-agent
     (make-agent #:id "aid:ana" #:type 'person #:name "Ana" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "17:00")))
  ($ ($ scopeB 'agent-store) 'add-agent
     (make-agent #:id "aid:bo" #:type 'person #:name "Bo" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "13:00")))
  ($ svc 'add-scope! "Granary" scopeA)
  ($ svc 'add-scope! "Table"   scopeB)
  ($ svc 'declare-skill "Granary" "aid:ana" "spec-cook")

  ;; Granary raises a plan needing 4h of cooking: one work intent, published
  ;; by a rising proposal (plan-bundle.scm shapes).
  (define psA ($ scopeA 'plan-store))
  (define psB ($ scopeB 'plan-store))
  ($ psA 'add-intent
     (make-intent #:id "wi1" #:action 'work #:resource-conforms-to "spec-cook"
                  #:effort-quantity (make-measure 4.0 "hours") #:planned-within "plan-1"))
  ($ psA 'add-proposal (make-rising-proposal "prop-1" "plan-1" "Granary" '("wi1")))

  (display "\n── the UC matches the rising plan against the roster ──\n")
  (define result ($ svc 'match-labour!))
  (check "the match succeeds" (car result) 'ok)
  (check "one commitment, 4 hours"
         (list (assq-ref (cdr result) 'commitments)
               (assq-ref (cdr result) 'hours))
         '(1 4.0))

  (display "\n── the descent lands it in the owning scope alone ──\n")
  (define landed
    (filter (lambda (c) (equal? (commitment-planned-within c) "plan-1"))
            ($ psA 'all-commitments)))
  (check "Granary's plan-store holds the commitment" (length landed) 1)
  (check "on the body the roster named"
         (commitment-provider (car landed)) "aid:ana")
  (check "with the skill the plan asked for"
         (commitment-resource-conforms-to (car landed)) "spec-cook")
  (check "Table's plan-store holds none of it"
         (filter (lambda (c) (equal? (commitment-planned-within c) "plan-1"))
                 ($ psB 'all-commitments))
         '())
  (check "the descent's standing read answers the round's hours"
         (list ($ svc 'deployed-hours-of "Granary")
               ($ svc 'deployed-hours-of "Table"))
         '(4.0 0)))

(test-summary!)
