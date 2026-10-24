;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; work-ids.scm — the id grammar of the work-intent families, written once.
;;;
;;; The solve lays work as intents, and a family is told apart by its id:
;;;
;;;   ni|PROCESS|SKILL|CELL   a NEED: an open shift, provider unbound (the solve's own cell)
;;;   oi|WORKER|SKILL|CELL    an OFFER: a worker's willingness, its status kept as meta under the id
;;;   mi|WORKER|SKILL|CELL    a MATERIALIZED suggestion: a willing worker laid onto an open need
;;;   offer:AGENT:PROCESS@WHEN  the bounded rung's hold: one person's own offer (doors/offers.scm)
;;;
;;; The constructors, each family's prefix and its membership test live here, and ONE
;;; reader takes a bar-family id apart. It reads the cell and the skill from the END, as
;;; vf/facts/located.scm reads a column key, so a process id with a bar in it is the
;;; subject whole. No caller spells a prefix or splits an id by position.
;;;
;;; Not to be confused with person-facts.scm's `need-id` (the `need:` grammar of a need a
;;; person DECLARES): that is a stored need, this a need the solve derives each run.
;;; Rank 1, so plan/, solve/, scope/ and doors/ read the one grammar.

(define-module (localchimera vf facts work-ids)
  #:use-module ((localchimera vf facts located) #:select (bar-fields))
  #:export (need-intent-id offer-intent-id materialized-intent-id bounded-offer-id
            intent-family-prefix intent-family? work-intent-id-terms))

(define (need-intent-id proc skill cell)         (string-append "ni|" proc "|" skill "|" cell))
(define (offer-intent-id worker skill cell)      (string-append "oi|" worker "|" skill "|" cell))
(define (materialized-intent-id worker skill cell) (string-append "mi|" worker "|" skill "|" cell))
(define (bounded-offer-id agent proc when)       (string-append "offer:" agent ":" proc "@" when))

(define (intent-family-prefix family)
  "The prefix every id of FAMILY (need, offer, materialized, bounded) carries."
  (case family ((need) "ni|") ((offer) "oi|") ((materialized) "mi|") ((bounded) "offer:")
    (else (error "intent-family-prefix: no such family" family))))

(define (intent-family? family id)
  "ID is an id of FAMILY."
  (let ((p (intent-family-prefix family)))
    (and (string? id) (>= (string-length id) (string-length p))
         (string=? (substring id 0 (string-length p)) p))))

(define (work-intent-id-terms id)
  "A need, offer or materialized id taken apart: ((family . need|offer|materialized)
   (subject . PROCESS or WORKER) (skill . S) (cell . C)), or #f for any other id. The
   cell and the skill are the last two fields; the subject is everything between."
  (and (string? id)
       (let* ((parts (bar-fields id))
              (n (length parts))
              (family (cond ((string=? (car parts) "ni") 'need)
                            ((string=? (car parts) "oi") 'offer)
                            ((string=? (car parts) "mi") 'materialized)
                            (else #f))))
         (and family (>= n 4)
              (let loop ((i 1) (acc '()))
                (if (= i (- n 2))
                    (list (cons 'family family)
                          (cons 'subject (let join ((fs (reverse acc)) (out ""))
                                           (cond ((null? fs) out)
                                                 ((string=? out "") (join (cdr fs) (car fs)))
                                                 (else (join (cdr fs) (string-append out "|" (car fs)))))))
                          (cons 'skill (list-ref parts (- n 2)))
                          (cons 'cell (list-ref parts (- n 1))))
                    (loop (+ i 1) (cons (list-ref parts i) acc))))))))
