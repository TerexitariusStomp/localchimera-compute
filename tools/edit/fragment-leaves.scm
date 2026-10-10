#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; fragment-leaves.scm — which planner fragments could become real modules
;;;
;;; The (playnet planner) umbrella assembles ~96 fragments by textual
;;; include-from-path.  That costs two things: no fragment has an interface, so
;;; nothing checks what it actually needs; and Guile's per-module .go freshness
;;; check cannot see an edited fragment, because the fragment's text is baked
;;; into the includer's .go and the includer's own mtime never moves.
;;;
;;; Both go away for any fragment that becomes a real module.  The question is
;;; which ones CAN, and in what order — a fragment that references names its
;;; siblings define cannot be lifted out until they are.
;;;
;;; HOW THIS ANSWERS THAT.  Not by hand-rolling scope analysis: this codebase
;;; leans on `match`, whose patterns bind variables, and a hand-rolled walker
;;; that missed one would report confident nonsense.  Instead each fragment is
;;; compiled ALONE, inside a probe module carrying the umbrella's own imports,
;;; and Guile's compiler is asked what it could not resolve.  Its
;;; `possibly unbound variable` warnings are exactly the free variables, computed
;;; by the implementation that defines what a free variable means here.
;;;
;;; Three outcomes per fragment:
;;;   LEAF     — nothing unresolved. Convertible on its own, today.
;;;   NEEDS n  — n names come from siblings. Convertible after those.
;;;   BLOCKED  — does not compile alone at all, usually a macro or record type
;;;              defined in another fragment. Expansion-time, not link-time.
;;;
;;; Usage: guile --no-auto-compile tools/edit/fragment-leaves.scm [--verbose]

(use-modules (system base compile)
             (ice-9 match)
             (ice-9 regex)
             (ice-9 rdelim)
             (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-13))

(define %umbrella "module/playnet/boot/prelude.scm")
(define %verbose? (member "--verbose" (command-line)))

;;; ── The umbrella: its imports, and what it includes, in order ───────────────

(define (read-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((f (read port)))
          (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))

(define (umbrella-imports forms)
  "The #:use-module clauses of the umbrella's define-module, verbatim."
  (let scan ((fs forms))
    (match fs
      (() '())
      ((('define-module _ . rest) . _)
       (let loop ((tail rest) (acc '()))
         (match tail
           ((#:use-module clause . more) (loop more (cons clause acc)))
           ((_ . more) (loop more acc))
           (() (reverse acc)))))
      ((_ . more) (scan more)))))

(define (umbrella-includes forms)
  "Included fragment paths, in load order."
  (let walk ((f forms) (acc '()))
    (cond
     ((not (pair? f)) acc)
     ((and (eq? (car f) 'include-from-path) (pair? (cdr f)) (string? (cadr f)))
      (cons (cadr f) acc))
     (else (fold (lambda (x a) (walk x a)) acc (reverse f))))))

;;; ── What each fragment defines ──────────────────────────────────────────────

(define (form-defines form)
  "Top-level names bound by FORM."
  (match form
    ((('or 'define 'define* 'define-public 'define-inlinable) . _) '())
    (_ '())))

(define (defined-names path)
  (catch #t
    (lambda ()
      (append-map
       (lambda (form)
         (match form
           (((or 'define 'define* 'define-public 'define-inlinable
                 'define-syntax 'define-syntax-rule)
             (? pair? spec) . _)
            (list (car spec)))
           (((or 'define 'define* 'define-public 'define-inlinable
                 'define-syntax 'define-syntax-rule)
             (? symbol? name) . _)
            (list name))
           (('define-values (? pair? names) . _) (filter symbol? names))
           (('define-record-type _ ctor pred . fields)
            (append (if (pair? ctor) (list (car ctor)) '())
                    (if (symbol? pred) (list pred) '())
                    (append-map (lambda (f) (if (pair? f) (filter symbol? (cdr f)) '()))
                                fields)))
           (_ '())))
       (read-forms path)))
    (lambda _ '())))

;;; ── Probing one fragment ────────────────────────────────────────────────────

(define %unbound-rx
  (make-regexp "possibly unbound variable `([^']+)'"))

(define (probe-fragment frag imports index tmpdir)
  "Compile FRAG alone under the umbrella's IMPORTS.
   Returns (values status unbound-names) where status is 'ok or 'blocked."
  (let* ((probe (format #f "~a/probe-~a.scm" tmpdir index))
         (out   (format #f "~a/probe-~a.go" tmpdir index)))
    (call-with-output-file probe
      (lambda (port)
        (format port "(define-module (probe-~a)~%" index)
        (for-each (lambda (clause) (format port "  #:use-module ~s~%" clause))
                  imports)
        (format port "  )~%(include-from-path ~s)~%" frag)))
    (let ((warnings ""))
      (catch #t
        (lambda ()
          (set! warnings
                (call-with-output-string
                 (lambda (wp)
                   (parameterize ((current-warning-port wp))
                     (compile-file probe
                                   #:output-file out
                                   #:opts '(#:warnings (unbound-variable)))))))
          (values 'ok
                  (delete-duplicates
                   (let loop ((start 0) (acc '()))
                     (let ((m (false-if-exception
                               (regexp-exec %unbound-rx warnings start))))
                       (if m
                           (loop (match:end m) (cons (match:substring m 1) acc))
                           (reverse acc)))))))
        (lambda (key . args)
          (values 'blocked (list (format #f "~a" key))))))))

;;; ── Report ──────────────────────────────────────────────────────────────────

(define (main args)
  (let* ((forms    (read-forms %umbrella))
         (imports  (umbrella-imports forms))
         (frags    (reverse (umbrella-includes forms)))
         (tmpdir   (or (getenv "TMPDIR") "/tmp"))
         (probedir (string-append tmpdir "/frag-probe")))
    (system* "mkdir" "-p" probedir)
    (format #t "~a fragments, probed under ~a umbrella imports~%~%"
            (length frags) (length imports))

    ;; Which fragment defines what — so an unresolved name can be attributed.
    (define provider
      (let ((tbl (make-hash-table)))
        (for-each
         (lambda (frag)
           (let ((path (string-append "module/" frag)))
             (when (file-exists? path)
               (for-each (lambda (n)
                           (unless (hash-ref tbl n)
                             (hash-set! tbl n frag)))
                         (defined-names path)))))
         frags)
        tbl))

    (let loop ((rest frags) (index 0) (results '()))
      (match rest
        (()
         (let* ((results (reverse results))
                (leaves  (filter (lambda (r) (and (eq? (cadr r) 'ok)
                                                  (null? (caddr r))))
                                 results))
                (needs   (filter (lambda (r) (and (eq? (cadr r) 'ok)
                                                  (pair? (caddr r))))
                                 results))
                (blocked (filter (lambda (r) (eq? (cadr r) 'blocked)) results)))

           (format #t "~%════ LEAVES — convertible on their own (~a) ════~%~%"
                   (length leaves))
           (for-each (lambda (r) (format #t "  ~a~%" (car r))) leaves)

           (format #t "~%════ NEEDS SIBLINGS (~a) ════~%~%" (length needs))
           (for-each
            (lambda (r)
              (let* ((unbound (caddr r))
                     (froms (delete-duplicates
                             (filter-map (lambda (n) (hash-ref provider (string->symbol n)))
                                         unbound))))
                (format #t "  ~a~%      ~a name~p: ~a~%"
                        (car r) (length unbound) (length unbound)
                        (string-join (if %verbose? unbound
                                         (list-head unbound (min 6 (length unbound))))
                                     ", "))
                (when (pair? froms)
                  (format #t "      from: ~a~%" (string-join froms ", ")))))
            (sort needs (lambda (a b) (< (length (caddr a)) (length (caddr b))))))

           (format #t "~%════ BLOCKED — will not compile alone (~a) ════~%~%"
                   (length blocked))
           (for-each (lambda (r) (format #t "  ~a~%" (car r))) blocked)

           (format #t "~%summary: ~a leaves, ~a need siblings, ~a blocked, of ~a~%"
                   (length leaves) (length needs) (length blocked) (length frags))))
        ((frag . more)
         (let ((path (string-append "module/" frag)))
           (if (not (file-exists? path))
               (loop more (1+ index) results)
               (begin
                 (when %verbose?
                   (format (current-error-port) "probing ~a~%" frag))
                 (call-with-values
                     (lambda () (probe-fragment frag imports index probedir))
                   (lambda (status unbound)
                     (loop more (1+ index)
                           (cons (list frag status unbound) results))))))))))))

(main (command-line))
