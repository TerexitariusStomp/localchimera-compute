#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; wasm-deps.scm — transitive (playnet …) source closure of a wasm entry point
;;;
;;; The browser/*.wasm rules in the Makefile carry hand-written prerequisite
;;; lists.  A hand-written list drifts silently in the worst possible
;;; direction: a MISSING entry means make believes a stale artifact is fresh,
;;; so a broken module never triggers a rebuild and the breakage surfaces
;;; later, attributed to whoever next edits a listed file.
;;;
;;; That is not hypothetical here. (playnet crypto shamir) is imported by
;;; hoot/repl.scm and was absent from repl.wasm's prerequisites, so when it
;;; started using a procedure Hoot lacks, `make` went on reporting the wasm up
;;; to date.
;;;
;;; This walks the import graph from an entry file and prints every
;;; (playnet …) module reachable from it, as repo-relative .scm paths, one per
;;; line, sorted.  `make check-wasm-deps` diffs that against what the Makefile
;;; declares.
;;;
;;; Scope: (playnet …) modules only.  Third-party libraries (hoot, goblins,
;;; fibers, srfi, rnrs) live in the store at pinned versions and change only
;;; when a pin moves, which is a rebuild-everything event anyway.
;;;
;;; Usage:
;;;   guile --no-auto-compile tools/lint/wasm-deps.scm hoot/repl.scm

(use-modules (ice-9 match)
             (ice-9 optargs)
             (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-13))

;;; ── Two ways a file depends on another ──────────────────────────────────────
;;;
;;; Imports are one.  `include-from-path` is the other, and it is equally
;;; static: all 141 include sites in this repo (98 in the (playnet planner)
;;; umbrella alone) name their target as a literal string, so a walker can
;;; follow them exactly as it follows an import.  Includes are therefore
;;; treated as real edges here, not as a limitation to warn about.
;;;
;;; The one genuinely unfollowable case is a computed include path.  That gets
;;; collected below and turned into a hard error, because silently skipping it
;;; would let `check-wasm-deps` report "all declared" while a real edge went
;;; unrecorded — the exact stale-artifact failure the check exists to prevent.
;;; A visible "I cannot analyse this" beats an invisible omission.

(define *opaque* '())

(define (note-opaque! path what)
  (set! *opaque* (cons (cons path what) *opaque*)))

;;; ── Reading import forms ────────────────────────────────────────────────────

(define (module-name->path name)
  "Repo-relative source path for a (playnet …) module NAME, or #f."
  (and (pair? name)
       (eq? (car name) 'playnet)
       (let ((path (string-append "module/"
                                  (string-join (map symbol->string name) "/")
                                  ".scm")))
         (and (file-exists? path) path))))

(define (clause->module-name clause)
  "Extract a module name from an import CLAUSE.  Handles the bare form
   (playnet a b) and the selecting form ((playnet a b) #:select …)."
  (cond
   ((not (pair? clause)) #f)
   ;; ((playnet a b) #:select …) — head is itself a module name
   ((pair? (car clause)) (car clause))
   ;; (playnet a b) — a bare module name
   ((symbol? (car clause)) clause)
   (else #f)))

(define (form->imports form)
  "Every module name imported by FORM, whatever import shape it uses."
  (match form
    ;; (use-modules clause ...)
    (('use-modules . clauses)
     (filter-map clause->module-name clauses))
    ;; (import clause ...) — R7RS
    (('import . clauses)
     (filter-map clause->module-name clauses))
    ;; (define-module (name) #:use-module clause #:export ... )
    (('define-module _ . rest)
     (let loop ((tail rest) (acc '()))
       (match tail
         ((#:use-module clause . more)
          (loop more (cons (clause->module-name clause) acc)))
         ((_ . more) (loop more acc))
         (() (filter identity acc)))))
    (_ '())))

(define (form->includes form path)
  "Repo-relative paths of files textually included by FORM.
   (include-from-path \"playnet/x/y.scm\") resolves against module/;
   (include \"y.scm\") resolves against the including file's directory.
   A non-literal path is recorded as opaque — it cannot be followed."
  (match form
    (('include-from-path (? string? p))
     (let ((resolved (string-append "module/" p)))
       (if (file-exists? resolved) (list resolved) '())))
    (('include (? string? p))
     (let ((resolved (string-append (dirname path) "/" p)))
       (if (file-exists? resolved) (list resolved) '())))
    (((or 'include 'include-from-path) . _)
     (note-opaque! path (format #f "~s" (car form)))
     '())
    ;; `load`/`primitive-load` are deliberately NOT tracked. They are runtime
    ;; loads, not textual inclusion, so they add nothing to a compiled bundle
    ;; — and the symbol `load` also occurs as ordinary data (hoot/repl.scm
    ;; carries an SXML iframe attribute `(load ,(lambda (e) …))`), so matching
    ;; on it anywhere in a nested form yields false positives, which in a gate
    ;; is worse than the omission. A test that primitive-loads a fragment
    ;; (comms/metabolism.scm, a farm seed) makes a runtime edge this way, and
    ;; that is irrelevant to the wasm prerequisite lists this serves.
    (_ '())))

(define (walk-form form path)
  "Imports and includes contributed by FORM and everything nested in it."
  (let loop ((f form) (imports '()) (includes '()))
    (if (not (pair? f))
        (values imports includes)
        (let ((imports (append (form->imports f) imports))
              (includes (append (form->includes f path) includes)))
          ;; Recurse: includes and cond-expand-wrapped imports nest arbitrarily.
          (let inner ((rest f) (i imports) (n includes))
            (cond
             ((not (pair? rest)) (values i n))
             (else
              (call-with-values (lambda () (loop (car rest) i n))
                (lambda (i* n*) (inner (cdr rest) i* n*))))))))))

(define (file-deps path)
  "Two values: module names imported by PATH, and files it includes."
  (catch #t
    (lambda ()
      (call-with-input-file path
        (lambda (port)
          (let loop ((imports '()) (includes '()))
            (let ((form (read port)))
              (if (eof-object? form)
                  (values (reverse imports) (reverse includes))
                  (call-with-values (lambda () (walk-form form path))
                    (lambda (i n)
                      (loop (append i imports) (append n includes))))))))))
    (lambda (key . args)
      (note-opaque! path (format #f "unreadable (~a)" key))
      (values '() '()))))

;;; ── Closure ─────────────────────────────────────────────────────────────────

(define* (closure entry #:key (includes-only? #f))
  "Every (playnet …) source file transitively reachable from ENTRY, by import
   or by textual include.  Both are real build edges: editing an included
   fragment changes the including unit just as surely as editing an imported
   module, so both belong in a prerequisite list.

   With INCLUDES-ONLY?, follow include edges alone.  That is the set whose
   staleness Guile does NOT track — an imported module re-checks its own .go
   independently, so it needs no help; an included fragment is baked into the
   includer's .go and goes unnoticed.  tools/test/stale-go-sweep.sh wants exactly
   this narrower set, because invalidating the planner engine's .go on every
   ordinary import edit would cost a 30-second recompile for nothing."
  (let walk ((queue (list entry)) (seen '()))
    (match queue
      (() (sort (delete entry seen string=?) string<))
      ((path . rest)
       (if (member path seen)
           (walk rest seen)
           (call-with-values (lambda () (file-deps path))
             (lambda (imports includes)
               (let ((deps (if includes-only?
                               includes
                               (append (filter-map module-name->path imports)
                                       includes))))
                 (walk (append deps rest) (cons path seen))))))))))

(define (main args)
  (match (cdr args)
    (((or "--includes-only") entry)
     (unless (file-exists? entry)
       (format (current-error-port) "wasm-deps: no such entry: ~a~%" entry)
       (exit 2))
     (for-each (lambda (p) (format #t "~a~%" p))
               (closure entry #:includes-only? #t))
     (unless (null? *opaque*)
       (for-each (lambda (o)
                   (format (current-error-port) "  ~a: ~a~%" (car o) (cdr o)))
                 (reverse *opaque*))
       (exit 3)))
    ((entry)
     (unless (file-exists? entry)
       (format (current-error-port) "wasm-deps: no such entry: ~a~%" entry)
       (exit 2))
     (let ((deps (closure entry)))
       ;; Report before failing, so a run that hits an unfollowable form still
       ;; shows what it did manage to resolve.
       (for-each (lambda (p) (format #t "~a~%" p)) deps)
       (unless (null? *opaque*)
         (format (current-error-port)
                 "~%wasm-deps: ~a unfollowable form(s) — the dependency list above may~%~
                    be INCOMPLETE, so this is an error rather than a note:~%"
                 (length *opaque*))
         (for-each (lambda (o)
                     (format (current-error-port) "  ~a: ~a~%" (car o) (cdr o)))
                   (reverse *opaque*))
         (exit 3))))
    (_
     (format (current-error-port) "usage: wasm-deps.scm ENTRY.scm~%")
     (exit 2))))

(main (command-line))
