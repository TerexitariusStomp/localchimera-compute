#!/usr/bin/env -S guile --no-auto-compile -e main -s
!#
;;; lint-recipes.scm — is every recipe in the tree ValueFlows the planner can run?
;;;
;;; Seeds every `seed-*` the planner umbrella exports into one recipe store
;;; (dsl/vf-lint.scm `seed-every-recipe!`) and runs (playnet knowledge
;;; vf-lint) over it. The tree is the registry: a seeder is swept by existing,
;;; and one wanting anything other than a store errors and is skipped, counted.
;;;
;;; Over the same store it says where each process's legal crossings come from
;;; (law/lint.scm `crossing-sources`): read off the records, or declared by a
;;; tag, and for a tag which fact the records lack.
;;;
;;; Exit 0 = clean (warnings and info allowed), 1 = errors.
;;; Run: guile --no-auto-compile -L module tools/lint-recipes.scm
(use-modules (ice-9 format) (srfi srfi-1) (srfi srfi-13)
             (playnet scope root) (playnet knowledge dsl vf-lint)
             (playnet knowledge dsl findings)
             ((playnet knowledge law lint) #:select (crossing-sources))
             (goblins))

(define (main args)
  (let* ((vat (spawn-vat #:name "lint-recipes"))
         (root (with-vat vat (spawn-scope-root "lint")))
         (rs (with-vat vat ($ root 'recipe-store)))
         (swept (with-vat vat (call-with-values (lambda () (seed-every-recipe! rs)) list)))
         (ran (car swept)) (seeders (cadr swept))
         ;; the seeders alone leave the substance and justice specs to the
         ;; scope that adopts them, so a spec the store lacks is an info line here
         (findings (append (with-vat vat (lint-recipe-store rs #:specs-complete? #f))
                           (with-vat vat (crossing-sources rs))))
         (errors (errors-only findings))
         (warns (filter (lambda (f) (eq? 'warning (finding-severity f))) findings)))
    (format #t "recipes: ~a of ~a seeders ran, ~a recipes~%"
            (length ran) (length seeders) (length (with-vat vat ($ rs 'all-recipes))))
    (if (null? findings) (format #t "  clean~%") (format #t "~a~%" (format-findings findings)))
    (format #t "~a error(s), ~a warning(s), ~a info~%"
            (length errors) (length warns) (- (length findings) (length errors) (length warns)))
    (exit (if (null? errors) 0 1))))
(main (command-line))
