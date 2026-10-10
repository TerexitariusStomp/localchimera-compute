;;; test-count-anchor.scm — the ledger follows the latest count, whatever order
;;; the counts and the flows arrive in.
(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")
(use-modules (playnet test harness)
             (goblins) (goblins persistence-store memory) (goblins utils hashmap)
             (playnet scope root) (playnet vf schemas) (playnet doors service)
             ((playnet observation observer) #:select (void-event))
             (srfi srfi-1))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Commune")) store))
(define svc (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "org:commune" scope))))
(define (call m . a) (with-vat vat (apply $ svc m a)))
(define (obs m . a) (with-vat vat (apply $ ($ scope 'observer) m a)))
(define (onhand rid) (measure-qty (economic-resource-onhand-quantity (obs 'get-resource rid))))
(define (near? a b) (< (abs (- a b)) 1e-6))
(define %n 0)
(define (uid p) (set! %n (+ 1 %n)) (string-append p (number->string %n)))
(define (seed! rid spec qty)
  (obs 'seed-resource
       (make-economic-resource #:id rid #:name spec #:conforms-to spec #:classified-as '()
                               #:accounting-quantity (make-measure qty "kg") #:onhand-quantity (make-measure qty "kg")
                               #:current-location "place:pantry" #:primary-accountable "ada")))
(define (seed-in! rid spec qty in)
  (obs 'seed-resource
       (make-economic-resource #:id rid #:name spec #:conforms-to spec #:classified-as '()
                               #:accounting-quantity (make-measure qty "kg") #:onhand-quantity (make-measure qty "kg")
                               #:current-location "place:pantry" #:primary-accountable "ada" #:contained-in in)))
(define (iso hh mm) (format #f "2026-09-28T~2,'0d:~2,'0d:00Z" hh mm))
;; a flow: a consume (d < 0) or a raise-less produce stand-in via 'raise (d > 0)
(define (flow! rid d at)
  (obs 'record-event
       (make-economic-event
        #:id (uid "flow-") #:action (if (< d 0) 'consume 'raise)
        #:resource-inventoried-as rid #:resource-conforms-to "spec" #:provider "ada" #:receiver "ada" #:resource-quantity (make-measure (abs d) "kg") #:has-point-in-time at #:created at #:note "flow" #:in-scope-of '("org:commune"))))
(define (count! rid n at)
  (call 'count-stock "org:commune" "ada" rid (exact->inexact n) "kg" "stated" "" at "" "" ""))
(define (ok? r) (and (pair? r) (eq? (car r) 'ok)))
(define (sighting r) (and (ok? r) (assq-ref (cdr r) 'sighting)))


(display "\n── 7. a container's flow, logged late, and its jar ──\n")
(seed! "crate" "crate" 10.0)
(seed-in! "crate/jar" "jar" 4.0 "crate")
(count! "crate/jar" 3 (iso 10 0))            ; the jar counted at 10:00
(check "jar at 3" (onhand "crate/jar") 3.0)
(flow! "crate" -5 (iso 9 0))                   ; half the crate went at 09:00, logged after
(check "the crate gives up its five" (onhand "crate") 5.0)
(check "the jar's count already saw the crate's loss" (onhand "crate/jar") 3.0)

(display "\n── 8. a flow that states no instant follows the count ──\n")
(seed! "salt" "salt" 10.0)
(count! "salt" 6 (iso 10 0))
(flow! "salt" -2 #f)
(check "an undated use moves the counted stock" (onhand "salt") 4.0)

(display "\n── 9. a flow of the count's own instant stands in the order they landed ──\n")
(seed! "sugar" "sugar" 10.0)
(flow! "sugar" -1 (iso 10 0))                 ; landed before the count: in what it saw
(count! "sugar" 6 (iso 10 0))
(check "the count sets the ledger" (onhand "sugar") 6.0)
(flow! "sugar" -2 (iso 10 0))                 ; landed after it: follows it
(check "a flow of that instant that landed after follows the count" (onhand "sugar") 4.0)

(display "\n── 9b. tied counts add no rebase noise ──\n")
(define (rebases rid)
  (length (filter (lambda (e) (string-contains (economic-event-id e) "~rebases~"))
                  (obs 'events-for-resource rid))))
(seed! "malt" "malt" 10.0)
(count! "malt" 8 (iso 9 0))
(count! "malt" 9 (iso 9 0))
(count! "malt" 7 (iso 9 0))
(check "three counts of one instant: the last stands" (onhand "malt") 7.0)
(check "…and the ledger moved by the counts alone" (rebases "malt") 0)

(display "\n── 9c. the adjustments that follow a count are no readings ──\n")
(define (drift-n spec) (assq-ref (assq-ref (cdr (call 'scope-readings "org:commune" spec)) 'drift) 'n))
(seed! "wheat" "wheat" 10.0)
(count! "wheat" 8 (iso 9 0))
(define n1 (drift-n "wheat"))
(flow! "wheat" -1 (iso 8 0))                  ; logged late: the ledger follows the count, by a rebase
(check "the late flow landed a rebase" (rebases "wheat") 1)
(check "…and it is no reading: the drift is where the count left it" (drift-n "wheat") n1)
(display "\n── 10. a count that predates the stock's production is refused ──\n")
(obs 'record-event
     (make-economic-event
      #:id (uid "mk-") #:action 'produce #:output-of "proc-mk" #:resource-inventoried-as "fresh" #:resource-conforms-to "fresh-spec" #:provider "ada" #:receiver "ada"
      #:resource-quantity (make-measure 5 "kg") #:has-point-in-time (iso 11 0) #:created (iso 11 0) #:note "made" #:in-scope-of '("org:commune")))
(define r10 (count! "fresh" 3 (iso 9 0)))
(check "refused" (and (pair? r10) (eq? (car r10) 'error)) #t)
(define r10b (count! "fresh" 4 (iso 12 0)))
(check "a count after production lands" (onhand "fresh") 4.0)
(test-summary!)
