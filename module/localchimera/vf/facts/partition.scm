;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; partition.scm — one record, one program.
;;;
;;; A decomposed solve (the federated ADMM, the tree of folds) equals the
;;; pooled solve of the real economy on one condition the solver cannot see:
;;; the programs PARTITION the economy's people and records. A body named in
;;; two communes' programs spends its hours twice and carries its floor twice;
;;; the consensus converges, correctly, to the solution of a different economy.
;;; Nothing in the numbers says so — the duplicate is a missing structure, so
;;; the check is made from the structure: who holds what, and does anything
;;; appear under two holders.
;;;
;;; This module is the pure half, shared by the governance auditor
;;; (records-held-twice, over leaves of a federation) and the solve's entry
;;; (communes-partition, over the communes of one call): the accumulate-then-
;;; count over HOLDINGS, an association of owner → the keys that owner holds.

(define-module (localchimera vf facts partition)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (localchimera vf schemas)
  #:use-module ((localchimera vf facts person-facts) #:select (declared-need?))
  #:export (held-twice root-holdings))

(define (held-twice holdings)
  "HOLDINGS is ((owner key …) …). Returns ((key owner …) …) — every key held by
   more than one distinct owner, with its owners in the order they appear.
   Empty = the holders partition the keys. A key an owner lists twice is its
   own business and counts once."
  (let ((seen (make-hash-table)) (order '()))
    (for-each
     (lambda (h)
       (let ((owner (car h)))
         (for-each
          (lambda (k)
            (let ((owners (hash-ref seen k '())))
              (cond ((null? owners)
                     (set! order (cons k order))
                     (hash-set! seen k (list owner)))
                    ((not (member owner owners))
                     (hash-set! seen k (append owners (list owner)))))))
          (cdr h))))
     holdings)
    (filter-map (lambda (k)
                  (let ((owners (hash-ref seen k)))
                    (and (pair? (cdr owners)) (cons k owners))))
                (reverse order))))

(define (root-holdings root)
  "((kind . id) …) — the records the stores of the scope root ROOT hold: its
   agents, its economic resources and its declared needs (`need:AID:SPEC`, the
   carrier of a person's hand in the demand fold, so a person who has declared
   a need and no profile is a record too). The keys `held-twice` counts."
  (let ((rows (lambda (kind id-of thunk)
                (map (lambda (x) (cons kind (id-of x))) (or (false-if-exception (thunk)) '())))))
    (append
     (rows 'agent agent-id (lambda () ($ ($ root 'agent-store) 'all-agents)))
     (rows 'resource economic-resource-id (lambda () ($ ($ root 'observer) 'all-resources)))
     (rows 'need intent-id (lambda ()
                             (filter declared-need? ($ ($ root 'plan-store) 'all-intents)))))))
