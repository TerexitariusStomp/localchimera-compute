;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/lang/evaluator.scm — Metacircular evaluator for Hoot/WASM
;;;
;;; Needed because Hoot doesn't have Guile's `eval` or module system.
;;; On native Guile, you can use `(eval expr module)` directly instead.
;;;
;;; The evaluator handles standard Scheme forms (if, let, lambda, etc.)
;;; plus org-specific forms: modify!, rollback!.

(define-module (localchimera lang evaluator)
  #:use-module (goblins)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (evaluate
            extend-env
            bind-params
            default-base-bindings
            make-io-bindings))

;;; ── Helpers ────────────────────────────────────────────────────────────────

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

;;; ── Default base bindings ─────────────────────────────────────────────────
;;;
;;; Pure computation — no IO. Needed for Hoot where the module system
;;; isn't available. On native Guile, use (eval expr module) instead.

(define default-base-bindings
  `((+ . ,+) (- . ,-) (* . ,*) (/ . ,/)
    (> . ,>) (< . ,<) (= . ,=) (>= . ,>=) (<= . ,<=)
    (abs . ,abs) (max . ,max) (min . ,min)
    (modulo . ,modulo) (remainder . ,remainder) (expt . ,expt)
    (not . ,not) (equal? . ,equal?) (eq? . ,eq?)
    (cons . ,cons) (car . ,car) (cdr . ,cdr)
    (list . ,list) (append . ,append) (reverse . ,reverse) (length . ,length)
    (map . ,map) (filter . ,filter) (for-each . ,for-each) (fold . ,fold)
    (assoc . ,assoc) (member . ,member) (apply . ,apply)
    (null? . ,null?) (pair? . ,pair?) (list? . ,list?)
    (number? . ,number?) (string? . ,string?) (symbol? . ,symbol?)
    (procedure? . ,procedure?) (boolean? . ,boolean?)
    (zero? . ,zero?) (positive? . ,positive?) (negative? . ,negative?)
    (even? . ,even?) (odd? . ,odd?)
    (string-append . ,string-append) (string-length . ,string-length)
    (substring . ,substring) (string->symbol . ,string->symbol)
    (symbol->string . ,symbol->string) (string->number . ,string->number)
    (number->string . ,number->string)
    (sqrt . ,sqrt) (floor . ,floor) (ceiling . ,ceiling) (round . ,round)
    (string=? . ,string=?) (string<? . ,string<?) (string>? . ,string>?)
    (string-ref . ,string-ref)
    (cadr . ,cadr) (caddr . ,caddr) (cddr . ,cddr)
    (caar . ,caar) (cdar . ,cdar) (eqv? . ,eqv?) (char? . ,char?)
    (void . ,(lambda () (if #f #f)))))

;;; ── IO bindings ───────────────────────────────────────────────────────────

(define* (make-io-bindings #:optional (port (current-output-port)))
  "IO as a capability — passed in, not ambient."
  `((display . ,(lambda (v) (display v port) (if #f #f)))
    (write   . ,(lambda (v) (write v port) (if #f #f)))
    (newline . ,(lambda () (newline port) (if #f #f)))
    (format  . ,(lambda (fmt . args) (apply format port fmt args) (if #f #f)))))

;;; ── Metacircular evaluator ────────────────────────────────────────────────
;;;
;;; evaluate: (expr, org-ref, local-bindings) → value
;;; org-ref is typically a logged-revocable proxy.

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

    ;; rollback!
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
