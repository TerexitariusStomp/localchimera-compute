;;; test-federation-scope-record.scm — the planner service's `scope-record`:
;;; the record a peer of the federated solve is built over, from the live
;;; service, with a crossing column for each good that crosses.
;;;
;;; Two communes seeded as federation-snapshot's are (Granary flour-rich, Table
;;; flour-poor); the service answers each one's record; both share flour, and
;;; what each can give of it is read off what it holds — Granary its 300 kg,
;;; Table nothing. Which supplies and which draws is left to the solve.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-federation-scope-record.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes federation-demo) (playnet planner federation store-registry) (playnet planner scope root)
             (playnet planner scope live)
             (playnet planner doors service)
             ((playnet planner solve engine) #:select (make-boundary-oracle))
             (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define scope-root-env-full
  (make-persistence-env '() #:extends (list scope-root-env store-registry-env)))
(define store (make-memory-store))
(define-values (vat scopeA)
  (spawn-persistent-vat scope-root-env-full (lambda () (spawn-scope-root "Granary")) store))
(define scopeB (with-vat vat (spawn-scope-root "Table")))
(define svc (with-vat vat (spawn ^planner-service (hashmap))))
(with-vat vat
  (seed-fed-commune! scopeA "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
  (seed-fed-commune! scopeB "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)
  ($ svc 'add-scope! "Granary" scopeA)
  ($ svc 'add-scope! "Table"   scopeB))

(define rec-a (with-vat vat ($ svc 'scope-record "Granary" '("flour") (cons "bread#venue-granary@0" 5.0))))
(define rec-b (with-vat vat ($ svc 'scope-record "Table" '("flour") (cons "bread#venue-table@0" 40.0))))
(check "the service answers Granary's record" (eq? (car rec-a) 'ok))
(check "the service answers Table's record" (eq? (car rec-b) 'ok))
(when (and (eq? (car rec-a) 'ok) (eq? (car rec-b) 'ok))
  (let ((links-a ((make-boundary-oracle (cdr rec-a)) 'links))
        (links-b ((make-boundary-oracle (cdr rec-b)) 'links)))
    (format #t "   Granary ~a   Table ~a~%" links-a links-b)
    (check "both share flour, and the record says no side" (list links-a links-b) '(("flour") ("flour")))
    (check "Granary can give the flour it holds; Table, holding none, can give none"
           (list (assoc-ref (assq-ref (cdr rec-a) 'gives) "flour") (assoc-ref (assq-ref (cdr rec-b) 'gives) "flour"))
           '(300.0 0.0))
    (check "a scope not on the roster is a failure, not a record"
           (eq? (car (with-vat vat ($ svc 'scope-record "Nowhere" '("flour")))) 'error))))
(test-summary!)
