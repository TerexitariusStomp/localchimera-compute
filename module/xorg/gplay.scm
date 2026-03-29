;;; module/xorg/gplay.scm — Governance kernel
;;;
;;; An org is pure state: bindings + mutation + snapshot + restore.
;;; Accountability is separate: ^logger + logged-revocable proxies.
;;; Follows the Heart of Spritely pattern (section 3.3.4).

(define-module (xorg gplay)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib cell)
  #:use-module (goblins actor-lib facet)
  #:use-module (ice-9 match)
  #:export (^org
            ^logger
            ^output-port
            spawn-logged-revocable-proxy-pair
            evaluate
            filter-serializable-bindings
            *restore-base-bindings*
            org-env))

;;; ── Helpers ────────────────────────────────────────────────────────────────

(define (filter-serializable-bindings bindings)
  (filter (lambda (pair) (not (procedure? (cdr pair)))) bindings))

(define (extend-env env names vals)
  (append (map cons names vals) env))

(define (bind-params params vals env)
  (match params
    (() env)
    ((? symbol? rest-param) (cons (cons rest-param vals) env))
    ((p . ps)
     (if (null? vals)
         (error "Too few arguments")
         (bind-params ps (cdr vals) (cons (cons p (car vals)) env))))))

(define *restore-base-bindings* (make-parameter '()))

;;; ── ^output-port ──────────────────────────────────────────────────────────

(define-actor (^output-port bcom port)
  #:version 1
  #:portrait (lambda () (list 'stdout))
  #:restore (lambda (version _) (spawn ^output-port (current-output-port)))
  (methods
   [(display val)       (display val port)           (if #f #f)]
   [(write val)         (write val port)             (if #f #f)]
   [(newline)           (newline port)               (if #f #f)]
   [(format fmt . args) (apply format port fmt args) (if #f #f)]
   [(port)              port]))

;;; ── ^org ──────────────────────────────────────────────────────────────────
;;;
;;; Pure state. Bindings + output-cap. No history, no identity, no logging.
;;; The org doesn't know who calls it or why. Accountability is handled
;;; by the proxy layer (^logger + spawn-logged-revocable-proxy-pair).

(define-actor (^org bcom bindings output-cap)
  #:version 1
  #:portrait
  (lambda ()
    (list (filter-serializable-bindings bindings) output-cap))
  #:restore
  (lambda (version data-bindings oc)
    (let ((base (*restore-base-bindings*)))
      (spawn ^org (append data-bindings base) oc)))

  (define (lookup name)
    (cond ((assq name bindings) => cdr)
          ((and output-cap (memq name '(display write newline format)))
           (case name
             ((display) (lambda (v) ($ output-cap 'display v)))
             ((write)   (lambda (v) ($ output-cap 'write v)))
             ((newline)  (lambda () ($ output-cap 'newline)))
             ((format)   (lambda (fmt . args) (apply $ output-cap 'format fmt args)))))
          (else (error "Variable unbound:" name))))

  (methods
   [(lookup name) (lookup name)]
   [(bindings)    bindings]

   [(modify! name value)
    (let ((new-bindings (cons (cons name value)
                              (filter (lambda (p) (not (eq? (car p) name)))
                                      bindings))))
      (bcom (^org bcom new-bindings output-cap)))]

   [(snapshot)
    (filter-serializable-bindings bindings)]

   [(restore! snapshot)
    (let ((base (*restore-base-bindings*)))
      (bcom (^org bcom (append snapshot base) output-cap)))]))

;;; ── ^logger ───────────────────────────────────────────────────────────────
;;;
;;; From Heart of Spritely, section 3.3.4.
;;; Accumulates log entries. Separate from the objects it observes.

(define (^logger bcom)
  (define log (spawn ^cell '()))

  (methods
   ((append-to-log username object args)
    (let* ((current ($ log))
           (entry (list '*entry*
                        'user username
                        'args args
                        'snapshot ($ object 'snapshot)))
           (new-log (cons entry current)))
      ($ log new-log)))

   ((get-log) ($ log))

   ((get-log-for user)
    (filter (lambda (entry)
              (equal? (cadr (memq 'user entry)) user))
            ($ log)))))

;;; ── spawn-logged-revocable-proxy-pair ─────────────────────────────────────
;;;
;;; From Heart of Spritely, section 3.3.4.
;;; Wraps any object in a proxy that logs every call and can be revoked.
;;; The proxy IS the identity — "username" is baked in, unforgeable.

(define (spawn-logged-revocable-proxy-pair username object log)
  (define revoked? (spawn ^cell #f))

  (define (^proxy bcom)
    (lambda args
      (when ($ revoked?)
        (error "Access revoked for" username))
      ($ log 'append-to-log username object args)
      (apply $ object args)))

  (values (spawn ^proxy) revoked?))

;;; ── Evaluator ─────────────────────────────────────────────────────────────
;;;
;;; evaluate: (expr, org-ref, local-bindings) → value
;;; org-ref is typically a logged-revocable proxy — logging is transparent.

(define (evaluate expr org local-bindings)
  (match expr
    ;; Literals
    ((or #t #f (? number?) (? string?)) expr)
    (('quote x) x)

    ;; Symbol lookup
    ((? symbol? name)
     (cond ((assq name local-bindings) => cdr)
           (else ($ org 'lookup name))))

    ;; if
    (('if test then else-branch)
     (if (evaluate test org local-bindings)
         (evaluate then org local-bindings)
         (evaluate else-branch org local-bindings)))
    (('if test then)
     (when (evaluate test org local-bindings)
       (evaluate then org local-bindings)))

    ;; begin
    (('begin) (if #f #f))
    (('begin body rest ...)
     (let loop ((exprs (cons body rest)))
       (if (null? (cdr exprs))
           (evaluate (car exprs) org local-bindings)
           (begin (evaluate (car exprs) org local-bindings)
                  (loop (cdr exprs))))))

    ;; lambda
    (('lambda params body rest ...)
     (let ((closed local-bindings)
           (full (if (null? rest) body `(begin ,body ,@rest))))
       (lambda vals
         (evaluate full org (bind-params params vals closed)))))

    ;; let (named and plain)
    (('let (? symbol? name) ((vars vals) ...) body rest ...)
     (let* ((evaled (map (lambda (v) (evaluate v org local-bindings)) vals))
            (full (if (null? rest) body `(begin ,body ,@rest))))
       (letrec ((loop-fn
                 (lambda args
                   (evaluate full org
                             (extend-env (cons (cons name loop-fn) local-bindings)
                                         vars args)))))
         (apply loop-fn evaled))))
    (('let ((names vals) ...) body rest ...)
     (let ((evaled (map (lambda (v) (evaluate v org local-bindings)) vals)))
       (evaluate (if (null? rest) body `(begin ,body ,@rest))
                 org (extend-env local-bindings names evaled))))

    ;; let*
    (('let* () body rest ...)
     (evaluate (if (null? rest) body `(begin ,body ,@rest)) org local-bindings))
    (('let* ((name val) more ...) body rest ...)
     (evaluate `(let* ,more ,body ,@rest) org
               (cons (cons name (evaluate val org local-bindings)) local-bindings)))

    ;; letrec
    (('letrec ((names vals) ...) body rest ...)
     (let* ((boxes (map (lambda (_) (make-vector 1 #f)) names))
            (wrappers (map (lambda (b) (lambda args (apply (vector-ref b 0) args))) boxes))
            (env (append (map cons names wrappers) local-bindings))
            (evaled (map (lambda (v) (evaluate v org env)) vals))
            (full (if (null? rest) body `(begin ,body ,@rest))))
       (for-each (lambda (b v) (vector-set! b 0 v)) boxes evaled)
       (evaluate full org env)))

    ;; define — function shorthand
    (('define ((? symbol? name) . params) body rest ...)
     (evaluate `(define ,name (lambda ,params ,@(if (null? rest) (list body) (cons body rest))))
               org local-bindings))

    ;; define — value binding
    (('define (? symbol? name) value-expr)
     (let ((value (evaluate value-expr org local-bindings)))
       ($ org 'modify! name value)
       (if #f #f)))

    ;; modify!
    (('modify! name-expr value-expr)
     (let ((name (evaluate name-expr org local-bindings))
           (value (evaluate value-expr org local-bindings)))
       ($ org 'modify! name value)
       (if #f #f)))

    ;; rollback! — restores a snapshot from the log
    ;; Requires the log to be available as a binding
    (('rollback! log-entry-index-expr)
     (let* ((idx (evaluate log-entry-index-expr org local-bindings))
            (log-ref ($ org 'lookup '*log*))
            (log-entries ($ log-ref 'get-log))
            (entry (list-ref log-entries idx))
            (snapshot (cadr (memq 'snapshot entry))))
       ($ org 'restore! snapshot)
       (if #f #f)))

    ;; cond
    (('cond) (if #f #f))
    (('cond (test body ...) rest ...)
     (cond
      ((eq? test 'else)
       (evaluate (if (null? body) '(if #f #f) `(begin ,@body)) org local-bindings))
      (else
       (let ((val (evaluate test org local-bindings)))
         (cond
          ((not val) (evaluate `(cond ,@rest) org local-bindings))
          ((null? body) val)
          (else (evaluate `(begin ,@body) org local-bindings)))))))

    ;; case
    (('case key-expr clauses ...)
     (let ((key (evaluate key-expr org local-bindings)))
       (let loop ((cls clauses))
         (match cls
           (() (if #f #f))
           ((('else body rest ...) . _)
            (evaluate `(begin ,body ,@rest) org local-bindings))
           ((((datums ...) body rest ...) . more)
            (if (memv key datums)
                (evaluate `(begin ,body ,@rest) org local-bindings)
                (loop more)))))))

    ;; and / or
    (('and) #t)
    (('and expr) (evaluate expr org local-bindings))
    (('and expr rest ...)
     (and (evaluate expr org local-bindings)
          (evaluate `(and ,@rest) org local-bindings)))
    (('or) #f)
    (('or expr) (evaluate expr org local-bindings))
    (('or expr rest ...)
     (or (evaluate expr org local-bindings)
         (evaluate `(or ,@rest) org local-bindings)))

    ;; when / unless
    (('when test body rest ...)
     (when (evaluate test org local-bindings)
       (evaluate `(begin ,body ,@rest) org local-bindings)))
    (('unless test body rest ...)
     (unless (evaluate test org local-bindings)
       (evaluate `(begin ,body ,@rest) org local-bindings)))

    ;; do
    (('do ((vars inits steps ...) ...) (test exit-body ...) cmds ...)
     (let ((step-exprs (map (lambda (v s) (if (null? s) v (car s))) vars steps)))
       (evaluate `(let loop ,(map list vars inits)
                    (if ,test
                        (begin ,@(if (null? exit-body) '((if #f #f)) exit-body))
                        (begin ,@(if (null? cmds) '() cmds) (loop ,@step-exprs))))
                 org local-bindings)))

    ;; Application
    ((proc-expr args ...)
     (let ((proc (evaluate proc-expr org local-bindings))
           (vals (map (lambda (a) (evaluate a org local-bindings)) args)))
       (apply proc vals)))

    (_ (error "Cannot evaluate:" expr))))

;;; ── Persistence environment ───────────────────────────────────────────────

(define org-env
  (make-persistence-env
   `((((xorg gplay) ^org) ,^org)
     (((xorg gplay) ^output-port) ,^output-port))
   #:extends (list facet-env cell-env)))
