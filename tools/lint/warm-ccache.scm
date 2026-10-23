#!/usr/bin/env -S guile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; tools/lint/warm-ccache.scm — compile every module of the tree into the cache the emits load from.
;;;
;;;   guile -L module tools/lint/warm-ccache.scm        (make warm-ccache)
;;;
;;; The emits and the freshness checks run with --no-auto-compile: a module with no fresh
;;; compiled file is INTERPRETED there, and what a module draws at load (the demo
;;; recording's ids and label codes come from the process's random state, in load order)
;;; differs between an interpreted and a compiled load. `make lint-compile` compiles every
;;; module too, but into a directory of its own, so it warms only what those compilations
;;; import. This resolves every module of module/ with auto-compile ON, so the cache holds
;;; a fresh compiled file for each, and the emits that follow read the tree as the checks
;;; that follow them will. A module that cannot load here (a Hoot-only import) is counted,
;;; not fatal: the gate's own checks say whether it should.

(use-modules (ice-9 ftw) (ice-9 rdelim) (ice-9 match) (srfi srfi-1) (srfi srfi-13))

(define (module-files dir)
  (define out '())
  (ftw dir (lambda (path stat flag)
             (when (and (eq? flag 'regular) (string-suffix? ".scm" path) (not (string-contains path "/deprecated/")))
               (set! out (cons path out)))
             #t))
  (sort out string<?))

(define (module-name path)
  "The module a file under module/ names, or #f for a fragment (no define-module)."
  (call-with-input-file path
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (cond ((eof-object? line) #f)
                ((string-prefix? "(define-module (" line)
                 (let ((form (with-input-from-string (string-drop line 15) read)))
                   (and (list? form) (every symbol? form) form)))
                (else (loop))))))))

(define failed 0)
(define total 0)
(for-each
 (lambda (path)
   (let ((name (module-name path)))
     (when name
       (set! total (+ total 1))
       (catch #t
         (lambda () (resolve-interface name))
         (lambda (key . args)
           (set! failed (+ failed 1)))))))
 (module-files "module"))
(format #t "warm-ccache: ~a modules resolved, ~a not loadable here~%" (- total failed) failed)
