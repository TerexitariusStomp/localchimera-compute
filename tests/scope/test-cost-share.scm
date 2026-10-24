;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-cost-share.scm — a cost of a lent thing, read off the records.
;;;
;;; docs/legal/structure.md §5: the commune may bear a lent thing's running
;;; cost as a fixed sum by period (a cost share), and never as a sum that
;;; tracks the use (a lease, which the law reads as rent). The records tell
;;; the two apart (legal/crossings.scm, record level): a money commitment
;;; that is a clause of an agreement whose primary clause moves custody and
;;; not rights is `cost-share`; a money claim triggered by a use of the thing
;;; is `metered-use`. A plain purchase is neither. A body paid by the use is
;;; warned as a lessor on admission (legal/bodies.scm).
;;;
;;; Run: guile -L module tests/scope/test-cost-share.scm

(use-modules (localchimera test harness)
             (localchimera vf schemas)
             (localchimera legal crossings)
             (localchimera legal bodies)
             (localchimera scope agents)
             (localchimera observation observer)
             (localchimera knowledge dsl findings)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

;;; ─── the records, in hand ─────────────────────────────────────────────────
(define money (make-resource-specification #:id "spec-eur" #:name "Euro" #:medium-of-exchange #t
                                           #:resource-classified-as '("vf:money") #:default-unit-of-resource "EUR"))
(define van   (make-resource-specification #:id "spec-van" #:name "Van"
                                           #:resource-classified-as '("vf:vehicle") #:default-unit-of-resource "unit"))
(define specs (list money van))
(define (resolve-spec id) (find (lambda (s) (equal? (resource-specification-id s) id)) specs))

;; the lend: the owner grants custody of the van (the primary clause), the
;; commune promises it back and a flat share of its upkeep
(define grant  (make-commitment #:id "c-grant" #:action 'transfer-custody #:resource-conforms-to "spec-van"
                                #:provider "aid:owner" #:receiver "scope:k" #:clause-of "agr-van"))
(define return (make-commitment #:id "c-return" #:action 'transfer-custody #:resource-conforms-to "spec-van"
                                #:provider "scope:k" #:receiver "aid:owner" #:clause-of "agr-van"))
(define share  (make-commitment #:id "c-share" #:action 'transfer #:resource-conforms-to "spec-eur"
                                #:resource-quantity (make-measure 40 "EUR") #:due "2026-11-01"
                                #:provider "scope:k" #:receiver "aid:owner" #:clause-of "agr-van"))
(define lend   (make-agreement #:id "agr-van" #:name "the van" #:stipulates '("c-grant")
                               #:stipulates-reciprocal '("c-return" "c-share")))
;; a sale: rights move in the primary clause, money comes back
(define sale-out (make-commitment #:id "c-sale" #:action 'transfer #:resource-conforms-to "spec-van"
                                  #:provider "aid:owner" #:receiver "scope:k" #:clause-of "agr-sale"))
(define sale-pay (make-commitment #:id "c-pay" #:action 'transfer #:resource-conforms-to "spec-eur"
                                  #:resource-quantity (make-measure 9000 "EUR")
                                  #:provider "scope:k" #:receiver "aid:owner" #:clause-of "agr-sale"))
(define sale     (make-agreement #:id "agr-sale" #:name "the van, bought" #:stipulates '("c-sale")
                                 #:stipulates-reciprocal '("c-pay")))
;; a use of the van, and money claimed because of it
(define drove  (make-economic-event #:id "ev-drive" #:action 'use #:resource-conforms-to "spec-van"
                                    #:provider "scope:k" #:receiver "scope:k" #:resource-quantity (make-measure 1 "unit")))
(define per-use (make-claim #:id "cl-km" #:action 'transfer #:resource-conforms-to "spec-eur"
                            #:resource-quantity (make-measure 12 "EUR") #:triggered-by "ev-drive"
                            #:provider "scope:k" #:receiver "aid:owner"))
;; a purchase: money for fuel, no agreement, no trigger
(define fuel   (make-economic-event #:id "ev-fuel" #:action 'transfer #:resource-conforms-to "spec-eur"
                                    #:provider "scope:k" #:receiver "aid:station" #:resource-quantity (make-measure 60 "EUR")))

(define records (list grant return share sale-out sale-pay drove per-use fuel))
(define (resolve-record id)
  (find (lambda (r) (equal? id (cond ((commitment? r) (commitment-id r))
                                     ((economic-event? r) (economic-event-id r))
                                     ((claim? r) (claim-id r)) (else #f))))
        records))
(define (resolve-agreement id) (find (lambda (a) (equal? id (agreement-id a))) (list lend sale)))
(define (read r) (record-crossings r resolve-spec #:resolve-agreement resolve-agreement #:resolve-record resolve-record))

(display "\n── the records tell a share from a rent ──\n")
(check-pred "a fixed money clause of a lend is a cost share, not metered use"
            (and (memq 'cost-share (read share)) (not (memq 'metered-use (read share)))))
(check-pred "the same money as a clause of a sale is no cost share (rights moved)"
            (not (memq 'cost-share (read sale-pay))))
(check-pred "money claimed because the van was used is metered use"
            (and (memq 'metered-use (read per-use)) (not (memq 'cost-share (read per-use)))))
(check-pred "fuel bought from a station is neither"
            (null? (lset-intersection eq? '(cost-share metered-use) (read fuel))))
(check-pred "with no resolvers the readings stay silent, never guessed"
            (null? (lset-intersection eq? '(cost-share metered-use)
                                      (append (record-crossings share resolve-spec)
                                              (record-crossings per-use resolve-spec)))))
(check-pred "both readings are in the catalogue, by choice"
            (and (eq? 'by-choice (crossing-kind 'cost-share)) (eq? 'by-choice (crossing-kind 'metered-use))))

;;; ─── a body paid by the use is a lessor ───────────────────────────────────
(display "\n── admission: a lessor in all but name ──\n")
(define vat (spawn-vat))
(define (findings-for claim?)
  (with-vat vat
    (let ((as (spawn ^agent-store (hashmap) (hashmap) (hashmap) '()))
          (obs (spawn ^observer (empty-observer-state) '())))
      ($ obs 'seed-resource (make-economic-resource #:id "res-van" #:name "Van" #:conforms-to "spec-van"
                                                    #:classified-as '("vf:vehicle") #:onhand-quantity (make-measure 1 "unit")
                                                    #:primary-accountable "aid:owner"))
      (declare-body! as "scope:k" "body:garage" "Garage" '((role . host) (jurisdiction . "france")))
      ($ obs 'record-event drove)
      (admission-findings as obs "scope:k" #:resolve-spec resolve-spec
                          #:claims (if claim?
                                       (list (make-claim #:id "cl-km" #:action 'transfer #:resource-conforms-to "spec-eur"
                                                         #:resource-quantity (make-measure 12 "EUR") #:triggered-by "ev-drive"
                                                         #:provider "scope:k" #:receiver "body:garage"))
                                       '())))))
(define (kinds fs) (map finding-kind fs))
(check-pred "a body that lends and claims nothing is no lessor" (not (memq 'lessor (kinds (findings-for #f)))))
(check-pred "a body paid per use of what it lent is warned as a lessor"
            (let ((f (find (lambda (f) (eq? 'lessor (finding-kind f))) (findings-for #t))))
              (and f (eq? 'warning (finding-severity f)))))

(test-summary!)
