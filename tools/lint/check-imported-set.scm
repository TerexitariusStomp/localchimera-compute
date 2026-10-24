#!/usr/bin/env guile
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; check-imported-set.scm — no module assigns a binding it imported.
;;;
;;;   guile tools/lint/check-imported-set.scm [FILE …]   exit 1 and name each site
;;;                                                      (default: module/, minus deprecated/)
;;;
;;; Hoot compiles a whole program and refuses `(set! x …)` where x is a toplevel
;;; the module did not define itself (hoot/library-group.scm: "set! to imported
;;; binding"). Guile accepts the same write and, when the owner is declarative,
;;; lets the owner's compiled code keep the value it inlined, so the two builds
;;; diverge without a message. This check is Hoot's rule, stated once for both:
;;; every module is expanded to Tree-IL and each `toplevel-set` of a name that
;;; no `toplevel-define` of the same file binds is a site. A fragment (a file
;;; with no define-module) defines into its includer and is outside the
;;; question; so is deprecated/.
;;;
;;; A module that holds state other modules write states it as a context cell
;;; (localchimera protocol context, `define-context … #:cell`): the write is then a
;;; setter call on the one instance, not an assignment of an import.
;;;
;;; A module that imports a `(hoot …)` module is the browser's alone and does
;;; not expand under Guile; it is listed as such, and Hoot's own refusal is its
;;; check, as it is for the programs under hoot/, which this check does not
;;; read: expanding a wasm program under Guile loads the tree in an order no
;;; boot takes, and a module cycle then leaves a module half made. Any other
;;; module that does not expand is a refusal: a file this check cannot read is
;;; not a file it has checked. A `set!` of a name the Guile core itself binds
;;; (`*random-state*`) is the language's own dial, not an import of ours.

(use-modules (ice-9 ftw) (ice-9 match) (srfi srfi-1)
             (system base compile) (system base language) (language tree-il))

(define %roots '("module"))

(define (scm-files root)
  (let ((acc '()))
    (ftw root (lambda (path stat flag)
                (when (and (eq? flag 'regular)
                           (string-suffix? ".scm" path))
                  (set! acc (cons path acc)))
                #t))
    acc))

(define (module-form path)
  "The file's define-module form, or #f for a fragment."
  (call-with-input-file path
    (lambda (p)
      (let lp ()
        (let ((f (catch #t (lambda () (read p)) (lambda _ (eof-object)))))
          (cond ((eof-object? f) #f)
                ((and (pair? f) (eq? (car f) 'define-module)) f)
                (else (lp))))))))

(define (hoot-only? form)
  "The define-module imports a (hoot …) module."
  (let lp ((f (cddr form)))
    (match f
      ((#:use-module ((or ('hoot . _) (('hoot . _) . _)) . _) . _) #t)
      ((#:use-module ('hoot . _) . _) #t)
      ((_ . rest) (lp rest))
      (() #f))))

(define (tree-il-of path name)
  "The whole file as one Tree-IL, expanded as compile-file expands it. Expanding
   a file evaluates its define-module and nothing else, so the module it names
   would stand registered and empty afterwards, and a module loaded later in
   the same process that imports it would read an empty interface and fail at
   its own top level, far from the cause. So the module is loaded whole first,
   as any importer loads it, and the expansion re-states a module that stands."
  (when name (resolve-module name #t))
  (save-module-excursion
   (lambda ()
     (call-with-input-file path
       (lambda (port)
         (set-port-encoding! port "UTF-8")
         (read-and-compile port #:from 'scheme #:to 'tree-il
                           #:env (current-module) #:opts '()))))))

(define (sites path name)
  "((name . line) …): each set! of a toplevel the file does not define."
  (let ((defined '()) (sets '()))
    (pre-order (lambda (x)
                 (cond ((toplevel-define? x) (set! defined (cons (toplevel-define-name x) defined)))
                       ((toplevel-set? x)
                        (set! sets (cons (cons (toplevel-set-name x)
                                               (let ((src (tree-il-srcv x))) (and src (1+ (vector-ref src 1)))))
                                         sets))))
                 x)
               (tree-il-of path name))
    (filter (lambda (s) (not (or (memq (car s) defined)
                                 (module-variable (resolve-module '(guile)) (car s)))))
            (reverse sets))))

(define (main args)
  (let* ((files (if (null? (cdr args))
                    (sort (append-map scm-files %roots) string<?)
                    (cdr args)))
         (bad 0))
    (for-each
     (lambda (f)
       (let ((form (module-form f)))
         (cond ((not form))
               ((hoot-only? form) (format #t "~a: the browser's alone, Hoot's own check~%" f))
               (else
                (catch #t
                  (lambda ()
                    (for-each (lambda (s)
                                (set! bad (1+ bad))
                                (format #t "~a:~a: set! of imported ~a~%" f (or (cdr s) "?") (car s)))
                              (sites f (cadr form))))
                  (lambda (k . a)
                    (set! bad (1+ bad))
                    (format #t "~a: did not expand (~a ~s)~%" f k a)))))))
     files)
    (if (zero? bad)
        (format #t "check-imported-set: ok (~a files)~%" (length files))
        (begin (format #t "check-imported-set: ~a sites~%" bad) (exit 1)))))

(main (command-line))
