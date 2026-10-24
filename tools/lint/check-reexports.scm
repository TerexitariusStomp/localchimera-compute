#!/usr/bin/env -S guile --no-auto-compile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; check-reexports.scm — every name a module re-exports is exported by another.
;;;
;;;   guile --no-auto-compile tools/lint/check-reexports.scm [ROOT]
;;;
;;; The pre-commit hook runs it over the INDEX's module/ tree (Guard 1, second
;;; half), so a commit cannot contain a library naming what its parts lack.
;;;
;;; A library module such as (localchimera boot prelude) re-exports names its parts
;;; define. When the parts and the library are committed apart, the library can
;;; name something the committed parts do not yet export, and the failure is a
;;; boot-time "Undefined variable" the first time anything loads the library:
;;; the gateway named the missing variable and stopped on every start.
;;;
;;; This reads every `define-module` form under ROOT/module (reading only; no
;;; module is loaded) and refuses a #:re-export name that no OTHER module exports
;;; or re-exports. A module's own list never vouches for itself.

(use-modules (ice-9 ftw) (ice-9 match) (srfi srfi-1))

(define root (match (command-line) ((_ r . _) r) (_ ".")))

(define (scm-files dir)
  (let loop ((d dir) (acc '()))
    (fold (lambda (n acc)
            (let ((p (string-append d "/" n)))
              (cond ((member n '("." "..")) acc)
                    ((eq? 'directory (stat:type (stat p))) (loop p acc))
                    ((string-suffix? ".scm" n) (cons p acc))
                    (else acc))))
          acc (scandir d))))

(define (keyword-list form kw)
  (let loop ((l form))
    (cond ((null? l) '())
          ((and (eq? (car l) kw) (pair? (cdr l)) (list? (cadr l))) (cadr l))
          (else (loop (cdr l))))))

;; names only: `(rename old new)` exports NEW, anything else nested is flattened
(define (names l)
  (append-map (lambda (e)
                (match e
                  ((? symbol?) (list e))
                  (('rename _ new) (list new))
                  ((? pair?) (names e))
                  (_ '())))
              l))

(define (read-forms file)
  (call-with-input-file file
    (lambda (port)
      (let loop ((acc '()))
        (let ((x (catch #t (lambda () (read port)) (lambda _ the-eof))))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

;; module file → (exports . re-exports)
(define modules
  (append-map
   (lambda (file)
     (filter-map
      (match-lambda
        (('define-module _ . rest)
         (list file
               (names (keyword-list rest #:export))
               (names (keyword-list rest #:re-export))))
        (_ #f))
      (read-forms file)))
   (scm-files (string-append root "/module"))))

;; name → the files that export or re-export it
(define offered (make-hash-table))
(for-each (match-lambda
            ((file exports re-exports)
             (for-each (lambda (s) (hash-set! offered s (cons file (hash-ref offered s '()))))
                       (append exports re-exports))))
          modules)

(define bad
  (append-map
   (match-lambda
     ((file _ re-exports)
      (filter-map (lambda (s)
                    (and (null? (delete file (hash-ref offered s '())))
                         (format #f "~a: re-exports ~a, which no other module exports" file s)))
                  re-exports)))
   modules))

(for-each (lambda (m) (display m) (newline)) bad)
(format #t "check-reexports: ~a module~:p, ~a re-export~:p checked, ~a unmatched\n"
        (length modules)
        (fold + 0 (map (lambda (m) (length (caddr m))) modules))
        (length bad))
(exit (if (null? bad) 0 1))
