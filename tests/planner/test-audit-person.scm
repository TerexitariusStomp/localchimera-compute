;;; test-audit-person.scm — the audit of a kind reads what a person took anywhere.
;;;
;;; A held need is checked ex post: what the log says its citizen took of the
;;; spec since the grant, against what they declared. Consumption is recorded
;;; where it happened, which need not be the citizen's home, so the audit reads
;;; the person's events across the roster (joined by event id). A citizen who
;;; took what they declared at another scope is confirmed, and the grant stands.
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/planner/test-audit-person.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas)
             (playnet doors service)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat))

(with-vat vat
  (let* ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
         (svc (spawn ^planner-service (hashmap)))
         (ob ($ b 'observer))
         (grants (lambda () (assq-ref (cdr ($ svc 'ratified-kinds "Granary")) 'grants))))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    ($ svc 'ratify-kind "Granary" "ben" "spec-insulin" "held")
    ($ svc 'declare-need "Granary" "ada" "spec-insulin" 1 %count-unit "" "" "" "💉" #f #f
       "insulin" "" "" "held" 100)
    (check "ada's home is the Granary, where the grant and the need stand"
           (list ($ svc 'home-of "ada") (length (grants))) '("Granary" 1))
    ;; she took it while she was at the Table: the event is the Table's
    ($ ob 'record-event
       (make-economic-event #:id "ev-ins-t" #:action 'consume #:resource-conforms-to "spec-insulin" #:provider "ada"
                            #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2099-01-01T08:00:00Z"))

    (display "\n── consumption at another scope counts ──\n")
    (let ((r (cdr ($ svc 'audit-kinds "Granary" "cy"))))
      (check "one row examined" (assq-ref r 'examined) 1)
      (check "taken as declared, at the Table: confirmed, not padded" (assq-ref r 'padded) 0)
      (check "the observed quantity is the one event" (assq-ref (car (assq-ref r 'findings)) 'observed) 1.0))
    (check "and the grant stands" (length (grants)) 1)

    (display "\n── an event told to two scopes is one event ──\n")
    ($ ($ a 'observer) 'record-event
       (make-economic-event #:id "ev-ins-t" #:action 'consume #:resource-conforms-to "spec-insulin" #:provider "ada"
                            #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2099-01-01T08:00:00Z"))
    (let ((r (cdr ($ svc 'audit-kinds "Granary" "cy"))))
      (check "told at both, it is still one hour of taking" (assq-ref (car (assq-ref r 'findings)) 'observed) 1.0))))

(test-summary!)
