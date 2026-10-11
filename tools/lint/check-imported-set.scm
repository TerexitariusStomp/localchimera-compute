#!/usr/bin/env guile
!#
;;; check-imported-set.scm — no module assigns a binding it imported.
;;;
;;;   guile tools/lint/check-imported-set.scm [FILE …]   exit 1 and name each site
;;;                                                      (default: module hoot, minus deprecated/)
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
;;; (playnet protocol context, `define-context … #:cell`): the write is then a
;;; setter call on the one instance, not an assignment of an import.

(use-modules (ice-9 ftw) (ice-9 match) (srfi srfi-1)
             (system base compile) (system base language) (language tree-il))

(define %roots '("module" "hoot"))

(define (scm-files root)
  (let ((acc '()))
    (ftw root (lambda (path stat flag)
                (when (and (eq? flag 'regular)
                           (string-suffix? ".scm" path)
                           (not (string-contains path "/deprecated/")))
                  (set! acc (cons path acc)))
                #t))
    acc))

(define (module-file? path)
  (call-with-input-file path
    (lambda (p)
      (let lp ()
        (let ((f (catch #t (lambda () (read p)) (lambda _ (eof-object)))))
          (cond ((eof-object? f) #f)
                ((and (pair? f) (eq? (car f) 'define-module)) #t)
                (else (lp))))))))

(define (tree-il-of path)
  "The whole file as one Tree-IL, expanded as compile-file expands it."
  (save-module-excursion
   (lambda ()
     (call-with-input-file path
       (lambda (port)
         (set-port-encoding! port "UTF-8")
         (read-and-compile port #:from 'scheme #:to 'tree-il
                           #:env (current-module) #:opts '()))))))

(define (sites path)
  "((name . line) …): each set! of a toplevel the file does not define."
  (let ((defined '()) (sets '()))
    (pre-order (lambda (x)
                 (cond ((toplevel-define? x) (set! defined (cons (toplevel-define-name x) defined)))
                       ((toplevel-set? x)
                        (set! sets (cons (cons (toplevel-set-name x)
                                               (let ((src (tree-il-srcv x))) (and src (1+ (vector-ref src 1)))))
                                         sets))))
                 x)
               (tree-il-of path))
    (filter (lambda (s) (not (memq (car s) defined))) (reverse sets))))

(define (main args)
  (let* ((files (if (null? (cdr args))
                    (sort (append-map scm-files %roots) string<?)
                    (cdr args)))
         (bad 0))
    (for-each
     (lambda (f)
       (when (module-file? f)
         (catch #t
           (lambda ()
             (for-each (lambda (s)
                         (set! bad (1+ bad))
                         (format #t "~a:~a: set! of imported ~a~%" f (or (cdr s) "?") (car s)))
                       (sites f)))
           (lambda (k . a)
             (format #t "~a: did not expand (~a ~s)~%" f k a)))))
     files)
    (if (zero? bad)
        (format #t "check-imported-set: ok (~a files)~%" (length files))
        (begin (format #t "check-imported-set: ~a sites~%" bad) (exit 1)))))

(main (command-line))
