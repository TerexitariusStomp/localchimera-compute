;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; utils/keyed-id.scm — the id that names WHAT a record is.
;;;
;;; A commitment's id is built from its terms (a claim: spec, claimant, place,
;;; when; a material flow: action, spec, process, places, instant; a work
;;; commitment: need and offer), so a re-solve that restates a commitment
;;; restates the same one, and different terms never share an id. One function
;;; joins them, in a module with no process or file dependencies so the browser
;;; build carries it too.

(define-module (localchimera utils keyed-id)
  #:export (keyed-id))

(define (keyed-id kind . parts)
  "KIND, then each of PARTS (a string, a symbol, or #f for an empty field),
   joined by |. An absent part is an empty field, so positions never shift."
  (string-join (cons kind (map (lambda (p) (cond ((not p) "") ((symbol? p) (symbol->string p)) (else p)))
                               parts))
               "|"))
