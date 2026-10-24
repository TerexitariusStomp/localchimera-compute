#!/usr/bin/env -S guile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; tools/lint/check-bridge-arity.scm — the browser bridge takes as many arguments as the seam declares
;;;
;;;   guile -L module tools/lint/check-bridge-arity.scm
;;;
;;; protocol/seam.scm declares each handler's parameters once; browser/day-boot.js
;;; wires the plain ones with `bridge("name", N)`, which pads and cuts the page's
;;; arguments to N before the spine sees them. An N below the declaration drops an
;;; argument in silence (measured 2026-10-12: acceptInvite declared `scope, vfId`,
;;; bridged with 1, so the spine read the scope as the proposal id). This holds every
;;; bridged handler's N to the seam's count; a handler with a wrapper of its own is
;;; not bridged and is not checked here.

(use-modules ((localchimera protocol seam) #:select (%handlers handler-name handler-arity))
             (ice-9 regex) (ice-9 rdelim) (srfi srfi-1))

(define %bridge-rx (make-regexp "HANDLERS\\.([A-Za-z0-9_]+) *= *bridge\\(\"([A-Za-z0-9_]+)\", *([0-9]+)"))

(define (bridged path)
  "((name . arity) …) for every `bridge(\"name\", N)` line of PATH."
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((line (read-line port)))
          (if (eof-object? line) (reverse acc)
              (let ((m (regexp-exec %bridge-rx line)))
                (loop (if m (cons (cons (match:substring m 2) (string->number (match:substring m 3))) acc) acc)))))))))

(define (main)
  (let* ((declared (map (lambda (h) (cons (handler-name h) (handler-arity h))) %handlers))
         (wrong (filter-map (lambda (b)
                              (let ((d (assoc-ref declared (car b))))
                                (cond ((not d) (list (car b) 'undeclared (cdr b)))
                                      ((not (= d (cdr b))) (list (car b) d (cdr b)))
                                      (else #f))))
                            (bridged "browser/day-boot.js"))))
    (for-each (lambda (w) (format #t "check-bridge-arity: ~a: the seam declares ~a argument(s), the bridge takes ~a~%" (car w) (cadr w) (caddr w))) wrong)
    (if (null? wrong)
        (format #t "check-bridge-arity: every bridged handler takes what the seam declares~%")
        (exit 1))))
(main)
