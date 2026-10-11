#!/usr/bin/env guile
!#
;;; check-goblins-spawn.scm — every `(spawn …)` in a Goblins module is Goblins' spawn.
;;;
;;;   guile tools/lint/check-goblins-spawn.scm [FILE …]   exit 1 and name each file that is not
;;;                                                      (default: module tests tools server)
;;;
;;; Guile 3.0.10 binds `spawn` in its core (a process spawn). A module that imports
;;; (goblins) selectively and leaves `spawn` out of the list still compiles and
;;; still runs: its `(spawn ^actor …)` reaches the process spawn and fails later,
;;; at the call, with "Wrong type argument in position 2". The compiler cannot see
;;; it, since the name IS bound. This check can: a file that imports any
;;; (goblins …) module, calls `spawn`, and takes `spawn` from no import is refused.
;;;
;;; `spawn` comes from (goblins) or (goblins core), plain, with a #:select naming
;;; it, or with a #:hide not naming it. A file that defines `spawn` itself is its
;;; own provider. A file with no Goblins import is outside the question: its
;;; `spawn` is the process spawn, meant.

(use-modules (ice-9 ftw) (ice-9 match) (srfi srfi-1))

(define %roots '("module" "tests" "tools" "server"))

(define (scm-files root)
  (let ((acc '()))
    (ftw root (lambda (path stat flag)
                (when (and (eq? flag 'regular)
                           (string-suffix? ".scm" path)
                           (not (string-contains path "/deprecated/")))
                  (set! acc (cons path acc)))
                #t))
    acc))

(define (read-forms path)
  (call-with-input-file path
    (lambda (port)
      (let lp ((acc '()))
        (let ((form (catch #t (lambda () (read port)) (lambda _ (eof-object)))))
          (if (eof-object? form) (reverse acc) (lp (cons form acc))))))))

;; an import spec: (goblins), ((goblins) #:select (…)), ((goblins core) #:hide (…)) …
(define (goblins-module? name) (and (pair? name) (eq? (car name) 'goblins)))
(define (spawn-module? name) (member name '((goblins) (goblins core))))
(define (spec-module spec) (if (and (pair? spec) (pair? (car spec))) (car spec) spec))
(define (spec-gives-spawn? spec)
  (and (spawn-module? (spec-module spec))
       (let ((opts (if (pair? (car spec)) (cdr spec) '())))
         (let ((sel (memq #:select opts)) (hide (memq #:hide opts)))
           (cond (sel (any (lambda (s) (or (eq? s 'spawn) (and (pair? s) (eq? (car s) 'spawn))))
                           (cadr sel)))
                 (hide (not (memq 'spawn (cadr hide))))
                 (else (not (memq #:prefix opts))))))))

;; every import spec a file states, from define-module and use-modules forms
(define (import-specs forms)
  (append-map
   (lambda (form)
     (match form
       (('define-module _ . opts)
        (let lp ((o opts) (acc '()))
          (match o
            ((#:use-module spec . rest) (lp rest (cons spec acc)))
            ((_ . rest) (lp rest acc))
            (() acc))))
       (('use-modules . specs) specs)
       (_ '())))
   forms))

(define (calls-spawn? forms)
  (let walk ((x forms))
    (and (pair? x)
         (or (eq? (car x) 'spawn)
             (any walk (let lp ((x x) (acc '())) (if (pair? x) (lp (cdr x) (cons (car x) acc)) acc)))))))

(define (defines-spawn? forms)
  (any (lambda (f) (match f
                     (('define ('spawn . _) . _) #t)
                     (('define 'spawn . _) #t)
                     (_ #f)))
       forms))

(define (finding path)
  (let* ((forms (read-forms path))
         (specs (import-specs forms)))
    (and (any (lambda (s) (goblins-module? (spec-module s))) specs)
         (calls-spawn? forms)
         (not (any spec-gives-spawn? specs))
         (not (defines-spawn? forms))
         path)))

(define (files-named args)
  (if (null? args)
      (append-map scm-files (filter file-exists? %roots))
      (append-map (lambda (a) (if (file-is-directory? a) (scm-files a) (list a))) args)))

(let ((bad (filter-map finding (files-named (cdr (command-line))))))
  (for-each (lambda (p) (format #t "~a: calls spawn with Goblins imported and spawn taken from no import\n" p))
            (sort bad string<?))
  (if (null? bad)
      (display "check-goblins-spawn: every spawn in a Goblins module is Goblins'\n")
      (exit 1)))
