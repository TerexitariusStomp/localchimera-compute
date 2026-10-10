#!/usr/bin/env -S guile --no-auto-compile -e main -s
!#
;;; lint-discipline.scm — voice/CCF + recomputability code-discipline linter
;;;
;;; Phase 5 of HARDENING.md. Catches the two principal discipline
;;; failures at build time:
;;;
;;;   1. Voice/CCF orthogonality — the voice computation path
;;;      (async.scm, snapshot.scm, anything matching *voice*) must
;;;      not reference set-ccf or any CCF-amplifying helper.
;;;
;;;   2. Recomputability — federation modules must not store
;;;      aggregates as actor-fields. Names matching *-cache,
;;;      cached-*, *-stored-aggregate*, etc. are flagged unless
;;;      explicitly whitelisted.
;;;
;;; Exit code 0 = clean, 1 = violations.
;;; Run: guile --no-auto-compile -L module tools/lint-discipline.scm

(use-modules (ice-9 rdelim)
             (ice-9 ftw)
             (ice-9 regex)
             (srfi srfi-1)
             (srfi srfi-13))


(define (file->string path)
  (let ((port (open-input-file path)))
    (let loop ((acc ""))
      (let ((line (read-line port)))
        (cond
         ((eof-object? line) (close-port port) acc)
         (else (loop (string-append acc line "\n"))))))))


(define (find-files dir pattern)
  (let ((matches '()))
    (file-system-tree
     dir
     (lambda (name stat)
       (when (and (eq? (stat:type stat) 'regular)
                  (string-match pattern name))
         (set! matches (cons name matches)))
       #t))
    (reverse matches)))


;; ── Voice/CCF discipline ────────────────────────────────────────────────────

(define *voice-paths*
  '("module/playnet/governance/async.scm"
    "module/playnet/governance/snapshot.scm"
    "module/playnet/governance/rules.scm"))

;; Forbidden in voice paths. set-ccf is the canonical violation;
;; the others would emerge from a "voice-weighted-by-ccf" refactor.
(define *forbidden-in-voice*
  '("set-ccf"
    "account-ccf"
    "voice-weighted-by-ccf"
    "ccf-multiplier"))

(define (lint-voice-ccf)
  (let ((violations '()))
    (for-each
     (lambda (path)
       (when (file-exists? path)
         (let ((text (file->string path)))
           (for-each
            (lambda (forbidden)
              (when (string-contains text forbidden)
                (set! violations
                      (cons (list path forbidden) violations))))
            *forbidden-in-voice*))))
     *voice-paths*)
    violations))


;; ── Recomputability discipline ──────────────────────────────────────────────

(define *federation-paths*
  '("module/playnet/planner/relational/federation-result.scm"
    "module/playnet/planner/relational/federation.scm"
    "module/playnet/planner/relational/plan-actor.scm"
    "module/playnet/governance/scope.scm"))

;; Pattern: a stored-aggregate field name. We're conservative and
;; only flag specific shapes; whitelist any legitimate uses.
(define *stored-aggregate-pattern*
  (make-regexp "(define-record-type|define-actor)[^)]*\\b(cached-aggregate|stored-aggregate|aggregate-cache|federation-cache)\\b"))

(define (lint-recomputability)
  (let ((violations '()))
    (for-each
     (lambda (path)
       (when (file-exists? path)
         (let ((text (file->string path)))
           (let ((m (regexp-exec *stored-aggregate-pattern* text)))
             (when m
               (set! violations
                     (cons (list path (match:substring m)) violations)))))))
     *federation-paths*)
    violations))


;; ── Reporting ──────────────────────────────────────────────────────────────

(define (report-violations title violations)
  (cond
   ((null? violations)
    (format #t "  ✓ ~a: clean~%" title))
   (else
    (format #t "  ✗ ~a: ~a violation(s)~%" title (length violations))
    (for-each
     (lambda (v)
       (format #t "      ~a: ~a~%" (car v) (cadr v)))
     violations))))

;; 3. Membership is never containment (patchwork-scopes-containment.md §3.2):
;;    a commune is a MEMBER of a federation, never INSIDE it — scope-tree walks
;;    the tree membership makes, containment.scm the tree containment makes.
;;    The modules that carry the membership tree must therefore never read the
;;    containment relations; a climb appearing here is a category error about
;;    to become an ownership proxy.
(define %membership-files
  '("module/playnet/vf/aggregation/scope-tree.scm"
    "module/playnet/governance/scope-graph.scm"
    "module/playnet/governance/scope.scm"
    "module/playnet/keys/scope-witness.scm"
    "module/playnet/scope/recovery.scm"))
(define %containment-idents
  (make-regexp "(spatial-thing-contained-in|economic-resource-contained-in|containment-chain|containment-first)"))
(define (lint-membership-containment)
  (append-map
   (lambda (f)
     (if (not (file-exists? f)) '()
         (let ((hits (filter-map
                      (lambda (line n)
                        (and (regexp-exec %containment-idents line)
                             (not (string-prefix? ";" (string-trim line)))
                             (format #f "~a:~a: membership module reads a containment relation" f n)))
                      (string-split (file->string f) #\newline)
                      (iota 100000 1))))
           hits)))
   %membership-files))

(define (main args)
  (let* ((vio-voice (lint-voice-ccf))
         (vio-recomp (lint-recomputability))
         (vio-member (lint-membership-containment))
         (any? (or (pair? vio-voice) (pair? vio-recomp) (pair? vio-member))))
    (format #t "~%── Discipline lint ──~%")
    (report-violations "Voice/CCF orthogonality" vio-voice)
    (report-violations "Recomputability"         vio-recomp)
    (report-violations "Membership≠containment"  vio-member)
    (format #t "~%")
    (exit (if any? 1 0))))

(main (command-line))
