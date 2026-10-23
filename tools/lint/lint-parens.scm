#!/usr/bin/env -S guile --no-auto-compile -s
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; lint-parens.scm — every .scm file in the tree parses as Scheme
;;;
;;; The cheapest possible structural gate: hand each file to Guile's own
;;; reader and require that it reaches EOF.  This catches the one failure
;;; mode that text-level editing (by a human or a tool) produces and that
;;; nothing else in the build notices — an unbalanced form in a file no
;;; test happens to import.
;;;
;;; That gap is real: (playnet utils parse-unit-definitions) is a
;;; standalone generator script, so no module imports it, so no compiler
;;; ever read it, so a missing close paren sat in it from its first
;;; commit onward.  A linter that only sees what the tests load would
;;; never have found it; the reader finds it in milliseconds.
;;;
;;; Semantics deliberately stop at "reads cleanly".  Unbound variables,
;;; bad arity and wrong module imports are the compiler's job — this is
;;; about the file being a well-formed s-expression at all.
;;;
;;; Usage:
;;;   guile --no-auto-compile tools/lint/lint-parens.scm            ; whole tree
;;;   guile --no-auto-compile tools/lint/lint-parens.scm FILE ...   ; named files
;;;
;;; Exit code 0 = every file read to EOF, 1 = at least one did not.

(use-modules (ice-9 ftw)
             (ice-9 match)
             (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13))

;;; ── Reader syntax we must tolerate ──────────────────────────────────────────
;;;
;;; deploy/ is Guix code: gexps (#~), ungexps (#$) and native-ungexps (#+)
;;; are reader extensions installed by (guix gexp), which is not on the
;;; ambient load path and which we do not want to depend on just to count
;;; parens.  Register throwaway handlers so the reader walks through them.
;;; They read the following datum and discard the distinction — balance is
;;; all we are asserting, not meaning.

(for-each (lambda (chr)
            (read-hash-extend chr (lambda (c port) (list 'gexp (read port)))))
          '(#\~ #\$ #\+))

;;; ── What to walk ────────────────────────────────────────────────────────────

;;; Scope: files this repo *authors*, which `git ls-files` states exactly.
;;; Vendored upstream checkouts (docs/minikanren/* — Racket `#lang` and
;;; Chez `#!chezscheme` sources that Guile's reader rightly rejects) and
;;; generated local state (.dev-data/) are untracked, so tracking is
;;; the boundary already; no hand-maintained exclusion list drifts out of
;;; date behind it.  The ftw walk below is the fallback for environments
;;; without git, and there the skip lists do the same job approximately.

(define %skip-dirs
  ;; Directory basenames never descended into (fallback walk only).
  '(".git" "node_modules" ".valhalla" ".dev" ".dev-data" "docs/minikanren"))

(define %skip-paths
  ;; Repo-relative prefixes holding files that end in .scm but are not
  ;; Guile Scheme.  tree-sitter query files use s-expression-ish syntax
  ;; with capture names (@name) that the reader rejects, by design.
  '("tooling/tree-sitter-wisp/queries/"
    "docs/minikanren/"))

(define (skipped-path? rel)
  (any (lambda (prefix) (string-prefix? prefix rel)) %skip-paths))

(define (scheme-file? name)
  (string-suffix? ".scm" name))

(define (git-tracked-scm)
  "Repo-relative paths of tracked .scm files, or #f when git is unavailable."
  (false-if-exception
   (let* ((port (open-pipe* OPEN_READ "git" "ls-files" "--" "*.scm"))
          (lines (let loop ((acc '()))
                   (let ((line (read-line port)))
                     (if (eof-object? line) (reverse acc) (loop (cons line acc))))))
          (status (close-pipe port)))
     (and (zero? (status:exit-val status))
          (pair? lines)
          (remove skipped-path? lines)))))

(define (collect-scm root)
  "Repo-relative paths of every readable .scm file under ROOT."
  (let ((prefix-len (1+ (string-length root))))
    (sort
     (file-system-fold
      ;; enter?
      (lambda (path stat result)
        (not (member (basename path) %skip-dirs)))
      ;; leaf
      (lambda (path stat result)
        (let ((rel (substring path prefix-len)))
          (if (and (scheme-file? path) (not (skipped-path? rel)))
              (cons rel result)
              result)))
      ;; down / up / skip
      (lambda (path stat result) result)
      (lambda (path stat result) result)
      (lambda (path stat result) result)
      ;; error — a dangling symlink lands here; report it as its own fault
      (lambda (path stat errno result)
        (if (scheme-file? path)
            (cons (cons 'unreadable (substring path prefix-len)) result)
            result))
      '()
      root)
     (lambda (a b)
       (string< (if (pair? a) (cdr a) a)
                (if (pair? b) (cdr b) b))))))

;;; ── The check ───────────────────────────────────────────────────────────────

(define (read-all path)
  "Read every datum in PATH.  Return #f on success, or an error string."
  (catch #t
    (lambda ()
      (call-with-input-file path
        (lambda (port)
          (let loop ()
            (if (eof-object? (read port))
                #f
                (loop))))))
    (lambda (key . args)
      ;; Guile's read-error carries its own "file:line:col: message" text
      ;; in the format string + args; render it rather than re-deriving.
      (match args
        ((_ fmt fmt-args . _)
         (or (false-if-exception (apply format #f fmt fmt-args))
             (format #f "~a: ~s" key args)))
        (_ (format #f "~a: ~s" key args))))))

(define (main args)
  (let* ((root (getcwd))
         (targets (cond
                   ((pair? (cdr args)) (cdr args))
                   ((git-tracked-scm))
                   (else (collect-scm root))))
         (failures
          (fold (lambda (target acc)
                  (match target
                    ;; A path the walker could not even stat (dangling symlink).
                    (('unreadable . rel)
                     (cons (cons rel "dangling symlink or unreadable file") acc))
                    (path
                     (let ((err (read-all path)))
                       (if err (cons (cons path err) acc) acc)))))
                '()
                targets)))
    (for-each (lambda (f)
                (format #t "FAIL ~a~%     ~a~%" (car f) (cdr f)))
              (reverse failures))
    (format #t "~a file~:p checked, ~a unreadable~%"
            (length targets) (length failures))
    (exit (if (null? failures) 0 1))))

(main (command-line))
