;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; solve/emphasis.scm — social desire, as a fold: the spec's one law for how a
;;; citizen's priorities become the plan's weight on a good.
;;;
;;; localchimera.typ §Desire as harmony / §The credit identity:
;;;
;;;   w_d^desire = Σ_p  v_p^cons · x̂_p(d)
;;;
;;; A citizen's emphasis is a SIMPLEX over their own rows — x̂_p(d) is the
;;; share of their attention on d, the shares summing to one — scaled by their
;;; consumer voice, and summed over citizens. Voice is a standing, never a
;;; stock: it is heard without being diminished (§Citizenship), and the
;;; conservation the mechanism needs (docs/planning/identity/truth-telling.md, stage 2)
;;; is the simplex itself — emphasis placed somewhere is emphasis withheld
;;; everywhere else, one budget over every decision at once.
;;;
;;; This module is the law and nothing else: no store, no intent, no engine.
;;; Rows and a voice reader come in; masses go out. The demand fold feeds it a
;;; scope's declared needs grouped by the citizen who holds them (the AID is
;;; known there, before anonymisation); the family solve feeds it a ledger.
;;; Both get the same numbers from the same lines.

(define-module (localchimera solve emphasis)
  #:use-module (srfi srfi-1)
  #:export (emphasis-masses fill-default))

(define (emphasis-masses rows voice-of scale)
  "ROWS ((owner key raw) …), RAW the owner's stated attachment on KEY (any
   positive number — the ladder's rungs, a legacy level's mass; a row at
   zero or #f states nothing and is dropped). VOICE-OF : owner → relative
   consumer voice, 1 = an equal citizen (#f reads as 1: no credit identity
   yet is no information, and no information is equality). SCALE is one
   citizen's whole emphasis in the engine's units.

   Returns ((owner key mass) …) with mass = SCALE · voice(owner) · share,
   share = raw / Σ of the owner's raws — so an owner's masses sum to
   SCALE · their voice whatever numbers they wrote, and doubling every
   attachment changes nothing. Linear in voice: a coalition's mass on a key
   is the sum of its members', however they split it."
  (let ((totals (make-hash-table))
        (voices (make-hash-table)))          ; one read per owner, however many rows
    (for-each (lambda (r)
                (let ((owner (car r)) (raw (caddr r)))
                  (when (and (number? raw) (> raw 0))
                    (unless (hash-ref voices owner #f)
                      (hash-set! voices owner (exact->inexact (or (voice-of owner) 1.0))))
                    (hash-set! totals owner (+ raw (hash-ref totals owner 0.0))))))
              rows)
    (filter-map
     (lambda (r)
       (let ((owner (car r)) (raw (caddr r)))
         (and (number? raw) (> raw 0)
              (list owner (cadr r)
                    (* scale (hash-ref voices owner) (/ raw (hash-ref totals owner)))))))
     rows)))

(define (fill-default keys weights)
  "WEIGHTS ((key . w) …) as stated; every key in KEYS gets one: its own where
   a citizen weighted it, else the mean of the stated ones — the spec's
   default (§Desire as harmony: where the citizen sets no weight, the
   previous aggregate signal stands). Empty when nothing is stated at all:
   the caller's own default is then the whole of the information."
  (if (null? weights)
      '()
      (let ((mean (/ (fold + 0.0 (map cdr weights)) (length weights))))
        (map (lambda (k) (cons k (or (assoc-ref weights k) mean))) keys))))
