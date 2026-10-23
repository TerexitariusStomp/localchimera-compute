;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; books.scm — a live scope's books, stated once for the suites.
;;;
;;; `(playnet test events)` holds the pure kernel's helpers (a state, an event, a
;;; fold). The suites that run a REAL scope (a persistent vat, the scope's observer,
;;; the doors that confirm a plan row) read and build the same few things, so they
;;; are here: a fresh scope, a resource, a plan row, what the books hold, and the
;;; confirmation of a row.
;;;
;;;   (let-values (((vat scope) (fresh-scope)))
;;;     (with-vat vat
;;;       (let ((obs ($ scope 'observer)))
;;;         ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
;;;         (confirm scope (flow-row "c1" 'consume "water" 30.0 "A" #:in "P"))
;;;         (onhand-of obs "w1"))))                    ; => 70.0

(define-module (playnet test books)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (goblins persistence-store memory)
  #:use-module (playnet scope root)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet scope live)
  #:use-module ((playnet vf formulas flows) #:select (make-flow-commitment))
  #:use-module (srfi srfi-1)
  #:export (fresh-scope res flow-row onhand-of spec-total resource-ids confirm mq ok? refused?))

(define* (fresh-scope #:optional (name "T"))
  "(values vat scope): a scope root in a persistent vat over a memory store."
  (define-values (vat scope)
    (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root name)) (make-memory-store)))
  (values vat scope))

(define* (res id spec qty place #:key (acct "commune") (unit "unit") contained stage state)
  "A resource ID of SPEC holding QTY UNIT at PLACE, accountable to ACCT."
  (make-economic-resource #:id id #:name id #:conforms-to spec #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
                          #:current-location place #:primary-accountable acct #:stage stage #:state state #:contained-in contained))

(define* (flow-row id act spec qty place #:key in out note (unit "unit"))
  "The plan's material row the confirming doors take: ACT of QTY SPEC at PLACE, a
   flow of the process IN or OUT — the record the solve emits (make-flow-commitment)."
  (make-flow-commitment #:id id #:action act #:spec spec #:qty qty #:unit unit #:place place
                        #:process (or in out) #:note note))

(define (mq m) (and m (measure-has-numerical-value m)))
(define (ok? r) (and (pair? r) (eq? (car r) 'ok)))
(define (refused? r) (and (pair? r) (eq? (car r) 'error)))

(define (onhand-of obs id)
  "What the books hold of resource ID, or #f for a resource they do not hold."
  (let ((r ($ obs 'get-resource id))) (and r (mq (economic-resource-onhand-quantity r)))))

(define* (spec-total obs spec #:key place)
  "What the books hold of SPEC in all, or of it at PLACE (where the holding itself sits)."
  (fold (lambda (r a)
          (if (and (equal? (economic-resource-conforms-to r) spec)
                   (or (not place) (equal? (economic-resource-current-location r) place)))
              (+ a (or (mq (economic-resource-onhand-quantity r)) 0))
              a))
        0.0 ($ obs 'all-resources)))

(define (resource-ids obs)
  "The ids of the resources the books hold, sorted."
  (sort (map economic-resource-id ($ obs 'all-resources)) string<?))

(define* (confirm scope row #:key (when-iso "2026-10-02T09:00:00"))
  "Record plan ROW as having happened at WHEN-ISO (record-flow-done): its event id."
  (record-flow-done scope row #:when-iso when-iso))
