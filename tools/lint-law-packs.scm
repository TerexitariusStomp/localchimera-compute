#!/usr/bin/env -S guile --no-auto-compile -e main -s
!#
;;; lint-law-packs.scm — a rule that names a jurisdiction nobody places can
;;; never fire, and nothing at runtime will ever say so.
;;;
;;; Exit 0 = clean (warnings allowed), 1 = errors.
;;; Run: guile --no-auto-compile -L module tools/lint-law-packs.scm [DIR …]
(use-modules (ice-9 format) (srfi srfi-1)
             (playnet knowledge law lint)
             (playnet vf facts places))

(define %default-dirs '("docs/legal/contexts"))

(define (main args)
  (let* ((dirs (if (> (length args) 1) (cdr args) %default-dirs))
         ;; the built-in roots places.scm registers at load time count as known
         (known (all-place-ids))
         ;; the packs, then what the federation trips that no pack speaks of
         (findings (append (append-map (lambda (d) (lint-law-packs d #:known known)) dirs)
                           (law-coverage (federation-crossings)
                                         (append-map pack-crossings dirs))))
         (errors (filter (lambda (f) (eq? 'error (finding-severity f))) findings))
         (warns  (filter (lambda (f) (eq? 'warning (finding-severity f))) findings)))
    (format #t "law packs: ~a~%" (string-join dirs " "))
    (if (null? findings)
        (format #t "  clean~%")
        (format #t "~a~%" (format-findings findings)))
    (format #t "~a error(s), ~a warning(s), ~a info~%"
            (length errors) (length warns)
            (- (length findings) (length errors) (length warns)))
    (exit (if (null? errors) 0 1))))

(main (command-line))
