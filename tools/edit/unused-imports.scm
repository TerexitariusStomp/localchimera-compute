#!/usr/bin/env -S guile --no-auto-compile -L module -s
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; unused-imports.scm — an import a module does not read.
;;;
;;;   tools/edit/unused-imports.scm --check FILE…    list each #:use-module clause the file never reads
;;;   tools/edit/unused-imports.scm --apply FILE…    remove them
;;;
;;; A split or a move carries a module's whole import list into each part, and
;;; most of it supplies nothing the part names. The question has a static
;;; answer the module system gives directly: resolve each clause's interface
;;; and ask whether it binds any symbol the file's forms mention, quoted data
;;; included. A symbol mentioned anywhere counts, so the answer over-keeps,
;;; which is the safe direction. Who-provides.scm asks the inverse question.
;;;
;;; A clause kept for its side effect at load (a module that registers schemas
;;; or claim indexes) reads as unused; mark it `;; load:` on its line and it is
;;; kept. --apply rewrites only the define-module form's #:use-module lines
;;; that stand alone on a line; a clause on a shared line is reported and left.

(use-modules (ice-9 match) (ice-9 rdelim) (ice-9 regex) (ice-9 format) (srfi srfi-1))

(define (forms path)
  (call-with-input-file path
    (lambda (p) (set-port-encoding! p "UTF-8")
      (let loop ((acc '())) (let ((f (read p))) (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))

(define (symbols-of x acc)
  (cond ((symbol? x) (cons x acc))
        ((pair? x) (symbols-of (cdr x) (symbols-of (car x) acc)))
        ((vector? x) (symbols-of (vector->list x) acc))
        (else acc)))

(define (spec-module s) (if (and (pair? s) (pair? (car s))) (car s) s))

(define (clauses mod)
  (let loop ((o (cddr mod)) (acc '()))
    (match o ((#:use-module s . r) (loop r (cons s acc))) ((_ . r) (loop r acc)) (() (reverse acc)))))

(define (unused-in path)
  "The #:use-module specs of PATH's define-module that bind nothing the file names."
  (let* ((fs (forms path))
         (mod (find (lambda (f) (and (pair? f) (eq? (car f) 'define-module))) fs)))
    (if (not mod) '()
        (let ((syms (delete-duplicates (symbols-of (delete mod fs) '()))))
          (filter (lambda (s)
                    (let ((iface (catch #t (lambda () (resolve-interface (spec-module s))) (lambda _ #f))))
                      (and iface (not (any (lambda (n) (module-variable iface n)) syms)))))
                  (clauses mod))))))

(define (spec->string s) (with-output-to-string (lambda () (write s))))

(define (apply! path specs)
  "Drop each line of PATH that is one #:use-module of a spec in SPECS, unless it says ;; load:."
  (let* ((lines (call-with-input-file path (lambda (p) (set-port-encoding! p "UTF-8")
                                               (let loop ((acc '())) (let ((l (read-line p))) (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))
         (dropped 0)
         (kept (filter (lambda (l)
                         (let ((m (string-match "^[ \t]*#:use-module[ \t]+(.*[^ \t])[ \t]*$" l)))
                           (cond ((not m) #t)
                                 ((string-contains l ";; load:") #t)
                                 (else
                                  (let* ((text (match:substring m 1))
                                         (text (if (string-contains text ";") (string-trim-right (substring text 0 (string-index text #\;))) text))
                                         (spec (catch #t (lambda () (with-input-from-string text read)) (lambda _ #f))))
                                    (if (and spec (member (spec-module spec) (map spec-module specs)))
                                        (begin (set! dropped (+ dropped 1)) #f)
                                        #t))))))
                       lines)))
    (call-with-output-file path
      (lambda (p) (set-port-encoding! p "UTF-8") (for-each (lambda (l) (display l p) (newline p)) kept)))
    (format #t "~a: ~a clause~:p dropped~a~%" path dropped
            (if (< dropped (length specs)) (format #f ", ~a on a shared line left" (- (length specs) dropped)) ""))))

(define (main args)
  (match args
    ((_ "--check" . files)
     (let ((n 0))
       (for-each (lambda (f) (let ((u (unused-in f)))
                               (for-each (lambda (s) (set! n (+ n 1)) (format #t "~a: ~a~%" f (spec->string (spec-module s)))) u)))
                 files)
       (format #t "unused-imports: ~a clause~:p over ~a file~:p~%" n (length files))))
    ((_ "--apply" . files)
     (for-each (lambda (f) (let ((u (unused-in f))) (unless (null? u) (apply! f u)))) files))
    (_ (format (current-error-port) "usage: unused-imports.scm --check|--apply FILE…~%") (exit 2))))

(main (command-line))
