#!/usr/bin/env -S guile --no-auto-compile -L module
!#
;;; scm-index.scm — CLI over (playnet tools scm-index): scope-aware caller
;;; search and duplicate-shape detection.
;;;
;;;   tools/scm-index.scm callers  <file> <name>   every genuine (unshadowed) use of NAME
;;;   tools/scm-index.scm dupes    <file>           top-level defines with identical body shape
;;;   tools/scm-index.scm defines  <file>           every top-level define, in file order
;;;
;;; Read-only, like `tools/sexp.scm origin`/`publishes`. Use `find-callers`
;;; before changing a signature or deleting a definition — it is scope-aware
;;; (a shadowed local of the same name is not a call site, but a recursive
;;; self-call is), unlike a plain grep. Use `find-duplicate-shapes` before
;;; writing a new helper — something with the same shape may already exist.
;;;
;;; Reports (top-level-index . sub-path) for each hit, not a line number:
;;; pair that top-level-index against `tools/sexp.scm list`'s output to find
;;; the enclosing definition, then read it with `tools/sexp.scm read`.

(use-modules (playnet tools scm-index)
             (ice-9 match)
             (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-13))

(define (read-file-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((forms '()))
        (let ((f (read port)))
          (if (eof-object? f) (reverse forms) (loop (cons f forms))))))))

(define (cmd-callers path name)
  (let* ((forms (read-file-forms path))
         (sym (string->symbol name))
         (hits (find-callers forms sym)))
    (if (null? hits)
        (format #t "no unshadowed references to ~a in ~a~%" name path)
        (for-each (lambda (h) (format #t "~a~%" h)) hits))))

(define (cmd-dupes path)
  (let* ((forms (read-file-forms path))
         (groups (find-duplicate-shapes forms)))
    (if (null? groups)
        (format #t "no duplicate-shaped top-level defines in ~a~%" path)
        (for-each
         (lambda (g)
           (format #t "same shape: ~a~%"
                   (string-join (map (lambda (nd) (symbol->string (car nd))) g) ", ")))
         groups))))

(define (cmd-defines path)
  (for-each (lambda (nd) (format #t "~4d  ~a~%" (cdr nd) (car nd)))
            (list-defines (read-file-forms path))))

(match (cdr (command-line))
  (("callers" path name) (cmd-callers path name))
  (("dupes" path)        (cmd-dupes path))
  (("defines" path)      (cmd-defines path))
  (_ (display "usage: scm-index.scm callers <file> <name> | dupes <file> | defines <file>\n"
              (current-error-port))
     (exit 1)))
