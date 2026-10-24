;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tools/lint/check-record-exports.scm — every name a record declaration defines is in its module's export list.
;;;
;;; `define-vf-record` (utils/records.scm) defines a type, its predicate and one
;;; accessor per field, named off the type name and the field list. Hoot reads a
;;; module's exports from its `define-module` alone (hoot/library-group.scm) and
;;; provides no run-time `export`, so the declaring module names them there, and
;;; this check holds that list to the declarations: a name a declaration defines
;;; and the export list lacks, or a `#:prefix` the two read differently, is a
;;; refusal. The rule for the names is the macro's, read here from the same forms.
;;;
;;;   guile --no-auto-compile tools/lint/check-record-exports.scm            ; the check
;;;   guile --no-auto-compile tools/lint/check-record-exports.scm --print    ; FILE NAME… per module

(use-modules (ice-9 ftw) (ice-9 match) (srfi srfi-1))

(define (forms-of path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((acc '()))
        (let ((f (read p)))
          (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))

(define (record-names form)
  "The names (type pred acc …) a define-vf-record FORM defines, by the macro's rule."
  (match form
    (('define-vf-record type name (field ...) . opts)
     (let* ((s    (symbol->string type))
            (tpfx (if (and (> (string-length s) 2) (char=? #\< (string-ref s 0))
                           (char=? #\> (string-ref s (- (string-length s) 1))))
                      (substring s 1 (- (string-length s) 1)) s))
            (p    (let loop ((o opts)) (cond ((or (null? o) (null? (cdr o))) #f)
                                             ((eq? (car o) #:prefix) (cadr o))
                                             (else (loop (cddr o))))))
            (pfx  (if p (symbol->string p) tpfx))
            (fname (lambda (f) (if (pair? f) (cadr f) f))))
       (cons* type (string->symbol (string-append tpfx "?"))
              (map (lambda (f) (string->symbol (string-append pfx "-" (symbol->string (fname f))))) field))))
    (_ '())))

(define (export-list forms)
  (let loop ((fs forms))
    (cond ((null? fs) '())
          ((and (pair? (car fs)) (eq? 'define-module (caar fs)))
           (let scan ((args (cddar fs)) (acc '()))
             (cond ((or (null? args) (null? (cdr args))) acc)
                   ((memq (car args) '(#:export #:export-syntax)) (scan (cddr args) (append acc (cadr args))))
                   (else (scan (cddr args) acc)))))
          (else (loop (cdr fs))))))

(define (scm-files dir)
  (let ((acc '()))
    (ftw dir (lambda (f st flag)
               (when (and (eq? flag 'regular) (string-suffix? ".scm" f)) (set! acc (cons f acc))) #t))
    (sort acc string<?)))

(define (main args)
  (let* ((print? (member "--print" args))
         (bad 0))
    (for-each
     (lambda (path)
       (let* ((forms (forms-of path))
              (decls (filter (lambda (f) (and (pair? f) (eq? 'define-vf-record (car f)))) forms)))
         (unless (null? decls)
           (let* ((names (append-map record-names decls))
                  (exports (export-list forms))
                  (missing (filter (lambda (n) (not (memq n exports))) names)))
             (cond (print? (format #t "~a ~{~a ~}~%" path missing))
                   ((pair? missing)
                    (set! bad (+ bad (length missing)))
                    (format #t "~a: ~a record name~p not in #:export: ~{~a ~}~%"
                            path (length missing) (length missing) missing)))))))
     (scm-files "module/localchimera"))
    (unless print?
      (if (zero? bad)
          (format #t "check-record-exports: every record name is in its module's export list~%")
          (begin (format #t "check-record-exports: ~a name~p to add~%" bad bad) (exit 1))))))

(main (command-line))
