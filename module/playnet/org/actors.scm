;;; module/playnet/org/actors.scm — Goblins actors for governed state
;;;
;;; Heart of Spritely patterns, expressed as reusable actors.
;;; Works everywhere: native Guile, Hoot/WASM, across OCapN.
;;;
;;; On native Guile these are optional — you can write the same
;;; patterns inline. On Hoot they're the foundation for the evaluator.
;;;
;;; Patterns used:
;;;   §3.2.2  State as updating behavior (bcom)
;;;   §3.3.4  Revocation and accountability (^logger, proxy pair)
;;;   actor-lib: ^facet (attenuation), ^cell (mutable state)

(define-module (playnet org actors)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib cell)
  #:use-module (goblins actor-lib facet)
  #:export (^org
            ^logger
            spawn-logger
            spawn-logged-revocable-proxy-pair
            filter-serializable-bindings
            *restore-base-bindings*
            org-env))

;;; ── Helpers ────────────────────────────────────────────────────────────────

(define (filter-serializable-bindings bindings)
  "Remove procedure-valued bindings (can't persist)."
  (filter (lambda (pair) (not (procedure? (cdr pair)))) bindings))

(define *restore-base-bindings* (make-parameter '()))

;;; ── ^org — pure state ─────────────────────────────────────────────────────
;;;
;;; Just bindings. No history, no identity, no IO.
;;; Mutation via bcom (§3.2.2). Accountability via proxy layer.

(define-actor (^org bcom bindings)
  #:version 1
  #:portrait
  (lambda () (list (filter-serializable-bindings bindings)))
  #:restore
  (lambda (version data-bindings)
    (let ((base (*restore-base-bindings*)))
      (spawn ^org (append data-bindings base))))

  (methods
   [(lookup name)
    (cond ((assq name bindings) => cdr)
          (else (error "Variable unbound:" name)))]
   [(bindings) bindings]
   [(modify! name value)
    (let ((new (cons (cons name value)
                     (filter (lambda (p) (not (eq? (car p) name)))
                             bindings))))
      (bcom (^org bcom new)))]
   [(snapshot) (filter-serializable-bindings bindings)]
   [(restore! snapshot)
    (let ((base (*restore-base-bindings*)))
      (bcom (^org bcom (append snapshot base))))]))

;;; ── ^logger — accountability (Heart of Spritely §3.3.4) ──────────────────
;;;
;;; Was a plain `define`, not `define-actor` — the audit trail this actor
;;; exists to provide had no #:portrait/#:restore at all and could not
;;; survive a restart. Log entries used to live in a nested ^cell sub-actor;
;;; now threaded directly through bcom as this actor's own state, so a
;;; straight portrait covers it (entries are plain data — the `snapshot`
;;; captured from OBJECT at append-time, not a live ref).

(define-actor (^logger bcom log)
  #:portrait
  (lambda () (list log))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^logger data))
      (else (error "Unknown ^logger version" version))))

  (methods
   ((append-to-log username object args)
    (bcom (^logger bcom
            (cons `(*entry* user ,username args ,args
                            snapshot ,($ object 'snapshot))
                  log))))
   ((get-log) log)
   ((get-log-for user)
    (filter (lambda (e) (equal? (cadr (memq 'user e)) user))
            log))))

(define (spawn-logger) (spawn ^logger '()))

;;; ── Logged revocable proxy (Heart of Spritely §3.3.4) ────────────────────

(define (spawn-logged-revocable-proxy-pair username object log)
  "Wrap OBJECT in a proxy that logs every call and can be revoked.
   Returns (values proxy revoked?-cell)."
  (define revoked? (spawn ^cell #f))
  (define (^proxy bcom)
    (lambda args
      (when ($ revoked?)
        (error "Access revoked for" username))
      ($ log 'append-to-log username object args)
      (apply $ object args)))
  (values (spawn ^proxy) revoked?))

;;; ── Persistence environment ───────────────────────────────────────────────

(define org-env
  (make-persistence-env
   `((((playnet org actors) ^org) ,^org)
     (((playnet org actors) ^logger) ,^logger))
   #:extends (list facet-env cell-env)))
