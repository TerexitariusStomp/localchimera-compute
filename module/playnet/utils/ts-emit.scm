;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; ts-emit.scm — the two ways a generated TypeScript file writes a value.
;;;
;;; tools/emit/nutrition-emit.scm, housing-emit.scm and rest-emit.scm turn a
;;; catalogue's tables into ui/app/*-catalogue.ts. They write numbers and
;;; strings the same way, from here: a whole number as an integer (15.0 ⇒ 15),
;;; and a string quoted with its backslashes and quotes escaped, so a source
;;; line that quotes a phrase cannot end the literal early.

(define-module (playnet utils ts-emit)
  #:export (ts-num ts-str))

(define (ts-num x)
  (cond ((and (exact? x) (integer? x)) (number->string x))
        ((exact? x) (ts-num (exact->inexact x)))
        ((integer? x) (number->string (inexact->exact x)))
        (else (number->string x))))

(define (ts-str s)
  (string-append
   "\""
   (list->string
    (let loop ((cs (string->list s)))
      (cond ((null? cs) '())
            ((memv (car cs) '(#\\ #\")) (cons #\\ (cons (car cs) (loop (cdr cs)))))
            (else (cons (car cs) (loop (cdr cs)))))))
   "\""))
