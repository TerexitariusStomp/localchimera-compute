#!/usr/bin/env -S guile --no-auto-compile -e main -s
!#
;;; check-crossing-catalogue.scm — the spec's crossing table and the code's
;;; crossing catalogue name the same crossings, each of the same kind.
;;;
;;; docs/playnet.typ renders its crossings table and its by-branch grid from one
;;; Typst array, `crossing-catalogue`. The array's prose (the wrapper, the stand)
;;; is the spec's own; what it shares with the code is each row's `id` and
;;; `kind`, which are `*default-crossings*` (module/playnet/planner/legal/crossings.scm).
;;; This reads both and reports a crossing one of them lacks, or a kind on which
;;; they differ.
;;;
;;; Exit 0 = they agree, 1 = they differ.
;;; Run: guile --no-auto-compile -L module tools/check-crossing-catalogue.scm [SPEC]   (make check-crossing-catalogue)
(use-modules (ice-9 rdelim) (ice-9 regex) (ice-9 format) (srfi srfi-1)
             (playnet planner legal crossings))

(define %spec "docs/playnet.typ")

(define (spec-rows path)
  "((id . kind) …) read off the `crossing-catalogue` array in PATH."
  (call-with-input-file path
    (lambda (port)
      (set-port-encoding! port "UTF-8")
      (let loop ((line (read-line port)) (in? #f) (id #f) (rows '()))
        (cond ((eof-object? line) (reverse rows))
              ((string-prefix? "#let crossing-catalogue = (" line)
               (loop (read-line port) #t #f rows))
              ((and in? (string=? line ")")) (reverse rows))
              ((and in? (string-match "^ *id: \"([^\"]+)\"" line))
               => (lambda (m) (loop (read-line port) #t (match:substring m 1) rows)))
              ((and in? id (string-match "^ *kind: \"([^\"]+)\"" line))
               => (lambda (m)
                    (loop (read-line port) #t #f
                          (cons (cons (string->symbol id) (string->symbol (match:substring m 1)))
                                rows))))
              (else (loop (read-line port) in? id rows)))))))

(define (main args)
  (let* ((path (if (> (length args) 1) (cadr args) %spec))
         (spec (spec-rows path))
         (code (map (lambda (row) (cons (car row) (cadr row))) *default-crossings*))
         (problems
          (append
           (filter-map (lambda (c) (and (not (assq (car c) spec))
                                        (format #f "~a is in legal/crossings.scm and has no row in the spec" (car c))))
                       code)
           (filter-map (lambda (s)
                         (let ((c (assq (car s) code)))
                           (cond ((not c) (format #f "~a has a row in the spec and is not in legal/crossings.scm" (car s)))
                                 ((not (eq? (cdr c) (cdr s)))
                                  (format #f "~a is ~a in the spec and ~a in legal/crossings.scm" (car s) (cdr s) (cdr c)))
                                 (else #f))))
                       spec))))
    (if (null? problems)
        (format #t "check-crossing-catalogue: ~a agrees with legal/crossings.scm on ~a crossings~%" path (length spec))
        (begin (for-each (lambda (p) (format #t "check-crossing-catalogue: ~a~%" p)) problems)
               (exit 1)))))

(main (command-line))
