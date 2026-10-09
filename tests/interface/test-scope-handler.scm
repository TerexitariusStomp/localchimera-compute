;;; test-scope-handler.scm — the scope backend's commands and its record door.
;;;
;;; backends/scope.scm named resource and event accessors and record-and-monitor
;;; without importing them (the umbrella used to supply them), so `resources`,
;;; `events` and `record-event` all raised on first use. This drives each over a
;;; real scope root.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/interface/test-scope-handler.scm

(use-modules (playnet test harness)
             (goblins)
             (goblins persistence-store memory)
             (ice-9 match)
             (srfi srfi-1) (srfi srfi-13)
             (playnet planner scope root)
             (playnet planner vf schemas)
             (playnet interface backends scope)
             (playnet interface command-dispatch))

(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Handler Test")) (make-memory-store)))

(define-values (handler sink)
  (with-vat vat (make-scope-handler scope #f)))

(define (command name)
  (with-vat vat
    ((hashmap-ref* (standard-command-table) name) `((scope-ref . ,scope)) "")))
(define (hashmap-ref* table name) ((@ (goblins utils hashmap) hashmap-ref) table name #f))

(display "\n── record-event through the handler ──\n")
(with-vat vat
  ($ scope 'observer))
(define bread-event
  (make-economic-event #:id "ev-bread" #:action 'raise #:resource-inventoried-as "res-bread"
                       #:resource-conforms-to "spec-bread" #:resource-quantity (make-measure 12 "loaf")
                       #:provider "org:test" #:receiver "org:test" #:at-location "place:hall"))
(check-pred "an event is recorded through the observer, monitors firing through the tee"
            (begin (with-vat vat ($ handler 'record-event bread-event)) #t))
(check "the observer holds the event"
       (map economic-event-id (with-vat vat ($ ($ scope 'observer) 'all-events)))
       '("ev-bread"))

(display "\n── the commands that print what the observer holds ──\n")
(check-pred "`resources` lists the resource by id, name and location"
            (let ((out (command "resources")))
              (and (string-contains out "res-bread") (string-contains out "place:hall"))))
(check-pred "`events` lists the event by id, action and quantity"
            (let ((out (command "events")))
              (and (string-contains out "ev-bread") (string-contains out "raise"))))

(test-summary!)
