;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; utils/wire-shapes.scm — the two shapes a door's reply takes on the way to a
;;; page: a list crosses as a vector, a symbol as its name. Stated once for every
;;; door that writes string-keyed alists for `scm->json-canonical`.

(define-module (playnet utils wire-shapes)
  #:export (vec sym->str))

(define (vec l)
  "L as a vector; anything that is no list is the empty vector."
  (list->vector (if (list? l) l '())))

(define (sym->str x)
  "A symbol's name, a string itself, anything else the empty string."
  (cond ((symbol? x) (symbol->string x)) ((string? x) x) (else "")))
