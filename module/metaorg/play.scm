(library (metaorg play)
  (export make-expressor
          expressor?
          expressor-name
          expressor-key
          make-env
          env-bindings
          env-validator
          env-history
          env-expressor
          make-history-entry
          history-version
          history-expressor
          history-expr
          history-parent
          next-version
          env-modify
          env-enact
          env-rollback
          default-validator
          default-history
          make-initial-env
          with-expressors
          evaluate
          authenticate?
          env?
          *ai-handler*
          *ai-eval-handler*
          set-ai-handler!
          set-ai-eval-handler!)
  (import (guile)
          (ice-9 match))

;;; Identity management — alist-based expressor store (Hoot-compatible)

(define *expressor-store* '())

(define (expressor-store-ref id)
  (let loop ((store *expressor-store*))
    (cond
     ((null? store) #f)
     ((eq? (caar store) id) (cdar store))
     (else (loop (cdr store))))))

(define (expressor-store-set! id data)
  (set! *expressor-store* (cons (cons id data) *expressor-store*)))

;;; Counter-based unique ID generation (replaces gensym)

(define *id-counter* 0)

(define (make-id name)
  (set! *id-counter* (+ *id-counter* 1))
  (string->symbol
   (string-append (symbol->string name) "-" (number->string *id-counter*))))

(define (env-lookup env name)
  (match (assoc name (env-bindings env))
    ((_key . val) val)
    (_ (error "Variable unbound:" name))))

(define (extend-env base-bindings names vals)
  (if (null? names)
      base-bindings
      (cons (cons (car names) (car vals))
            (extend-env base-bindings (cdr names) (cdr vals)))))

(define (bind-params params vals base)
  (cond
   ((null? params) base)
   ((symbol? params) (cons (cons params vals) base))
   ((pair? params)
    (cons (cons (car params) (car vals))
          (bind-params (cdr params) (cdr vals) base)))))

(define (make-expressor name public-key)
  (let ((id (make-id name)))
    (expressor-store-set! id
                          `((id . ,id)
                            (name . ,name)
                            (public-key . ,public-key)))
    id))

(define (expressor? x) (expressor-store-ref x))
(define (expressor-name id)
  (let ((data (expressor-store-ref id)))
    (and data (assq-ref data 'name))))
(define (expressor-key id)
  (let ((data (expressor-store-ref id)))
    (and data (assq-ref data 'public-key))))

;;; Environment now tracks the current expressor
(define (make-env bindings validator history expressor)
  (list bindings validator history expressor))

(define (env-bindings env) (car env))
(define (env-validator env) (cadr env))
(define (env-history env) (caddr env))
(define (env-expressor env) (cadddr env))

;;; History entries: (version . (expressor . (expr . parent)))
(define (make-history-entry version expressor expr parent)
  (cons version (cons expressor (cons expr parent))))

(define (history-version entry) (car entry))
(define (history-expressor entry) (cadr entry))
(define (history-expr entry) (caddr entry))
(define (history-parent entry) (cdddr entry))

;;; Version management
(define *version-counter* 0)
(define (next-version)
  (set! *version-counter* (+ *version-counter* 1))
  *version-counter*)

;;; Caller tracking — global variable instead of make-parameter (Hoot-compatible)
(define *current-caller* #f)

;;; AI integration globals — set by (metaorg ai) at load time
(define *ai-handler* #f)
(define *ai-eval-handler* #f)

(define (set-ai-handler! fn) (set! *ai-handler* fn))
(define (set-ai-eval-handler! fn) (set! *ai-eval-handler* fn))

;;; Core operations now take explicit expressor
(define (env-modify env expressor name value expr)
  (let* ((validator (env-validator env))
         (history (env-history env))
         (version (next-version))
         (new-bindings (cons (cons name value) (env-bindings env)))
         (new-entry (make-history-entry version expressor expr (caar history)))
         (new-history (cons new-entry history))
         (post-env (make-env new-bindings validator new-history expressor)))
    (if (validator expressor name value env post-env)
        post-env
        (error "Validation failed:" expressor name value))))

(define (env-enact env expressor validator-expr expr)
  (let* ((new-validator (evaluate validator-expr env))
         (version (next-version))
         (new-entry (make-history-entry version expressor expr
                                       (caar (env-history env))))
         (new-history (cons new-entry (env-history env)))
         (post-env (make-env (env-bindings env)
                             new-validator
                             new-history
                             expressor)))
    (if (new-validator expressor 'validator new-validator env post-env)
        post-env
        (error "Validator rejected by itself:" expressor new-validator))))

;;; Default validator — now takes expressor as first argument
(define (default-validator expressor name value pre-env post-env)
  #t)

(define (default-history)
  (list (make-history-entry 0 'genesis '(quote initial) 0)))

(define (make-initial-env base-bindings)
  (let ((genesis (make-expressor 'genesis "genesis-key")))
    (make-env base-bindings default-validator
              (default-history) genesis)))

;;; The elegant part: "with-expressors" wraps expressions with identity
(define-syntax with-expressors
  (syntax-rules ()
    ((_ (expressor-id expr ...) body ...)
     (let ((current-expressor expressor-id))
       (evaluate '(begin expr ...)
                (make-env (env-bindings env)
                         (env-validator env)
                         (env-history env)
                         current-expressor))))))

(define (authenticate? expressor)
  #t)

;;; Predicate: is this value a play environment (vs a computed result)?
;;; Envs are always 4-element lists whose second element is a procedure (the validator).
(define (env? x)
  (and (list? x)
       (= (length x) 4)
       (procedure? (cadr x))
       (list? (caddr x))))

;;; Rollback with expressor identity (inline find, no SRFI-1)
(define (env-rollback env target-version expressor)
  (let* ((history (env-history env))
         (validator (env-validator env))
         (target-entry (let loop ((entries history))
                         (cond
                          ((null? entries) #f)
                          ((= (history-version (car entries)) target-version)
                           (car entries))
                          (else (loop (cdr entries)))))))
    (if (not target-entry)
        (error "Version not found:" target-version)
        (let replay ((vers (reverse history))
                    (current-env env))
          (if (null? vers)
              current-env
              (let* ((entry (car vers))
                     (ver (history-version entry))
                     (expr (history-expr entry))
                     (entry-expressor (history-expressor entry)))
                (if (= ver target-version)
                    current-env
                    (replay (cdr vers)
                           ;; Replay with original expressor!
                           (evaluate expr
                                    (make-env (env-bindings current-env)
                                             (env-validator current-env)
                                             (env-history current-env)
                                             entry-expressor))))))))))

;;; The enhanced evaluator — minimal changes, maximum power
(define (evaluate expr env)
  (match expr
    ((or #t #f (? number?) (? string?)) expr)
    (('quote quoted-expr) quoted-expr)
    ((? symbol? name) (env-lookup env name))
    ;; if — three-branch
    (('if test consequent alternate)
     (if (evaluate test env)
         (evaluate consequent env)
         (evaluate alternate env)))
    ;; if — two-branch (returns unspecified when false)
    (('if test consequent)
     (if (evaluate test env)
         (evaluate consequent env)
         (if #f #f)))

    ;; begin — evaluate in sequence, threading env changes, return last
    (('begin)
     (if #f #f))
    (('begin body body* ...)
     (let loop ((exprs (cons body body*)) (current-env env))
       (if (null? (cdr exprs))
           (evaluate (car exprs) current-env)
           (let ((result (evaluate (car exprs) current-env)))
             (loop (cdr exprs)
                   (if (env? result) result current-env))))))

    ;; named let — loop construct (uses host letrec, no set-cdr!)
    (('let (? symbol? name) ((vars vals) ...) body body* ...)
     (let* ((eval-inits (map (lambda (v) (evaluate v env)) vals))
            (full-body (if (null? body*) body `(begin ,body ,@body*))))
       (letrec ((loop-fn
                 (lambda args
                   (let ((call-env (make-env
                                    (extend-env
                                     (cons (cons name loop-fn) (env-bindings env))
                                     vars args)
                                    (env-validator env) (env-history env) (env-expressor env))))
                     (evaluate full-body call-env)))))
         (apply loop-fn eval-inits))))

    ;; let — parallel bindings with implicit begin body
    (('let ((names vals) ...) body body* ...)
     (let ((eval-vals (map (lambda (v) (evaluate v env)) vals)))
       (let ((let-env (make-env (extend-env (env-bindings env) names eval-vals)
                                (env-validator env)
                                (env-history env)
                                (env-expressor env))))
         (if (null? body*)
             (evaluate body let-env)
             (evaluate `(begin ,body ,@body*) let-env)))))

    ;; let* — sequential bindings with implicit begin body
    (('let* () body body* ...)
     (if (null? body*)
         (evaluate body env)
         (evaluate `(begin ,body ,@body*) env)))
    (('let* ((name val) rest ...) body body* ...)
     (let ((eval-val (evaluate val env)))
       (evaluate `(let* ,rest ,body ,@body*)
                 (make-env (cons (cons name eval-val) (env-bindings env))
                           (env-validator env)
                           (env-history env)
                           (env-expressor env)))))

    ;; letrec — mutually recursive bindings via vector boxes (Hoot-safe)
    (('letrec ((names vals) ...) body body* ...)
     (let* ((boxes (map (lambda (n) (make-vector 1 #f)) names))
            (wrappers (map (lambda (box)
                             (lambda args (apply (vector-ref box 0) args)))
                           boxes))
            (letrec-env (make-env (append (map cons names wrappers) (env-bindings env))
                                  (env-validator env) (env-history env) (env-expressor env)))
            (eval-vals (map (lambda (v) (evaluate v letrec-env)) vals))
            (full-body (if (null? body*) body `(begin ,body ,@body*))))
       (for-each (lambda (box val) (vector-set! box 0 val)) boxes eval-vals)
       (evaluate full-body letrec-env)))

    ;; define — governed binding (like modify! but with unquoted name)
    (('define ((? symbol? name) . params) body body* ...)
     (evaluate `(define ,name (lambda ,params ,@(if (null? body*) (list body) (cons body body*))))
               env))
    (('define (? symbol? name) value-expr)
     (env-modify env (env-expressor env)
                 name
                 (evaluate value-expr env)
                 `(define ,name ,value-expr)))

    ;; cond — multi-branch conditional
    (('cond)
     (if #f #f))
    (('cond (test body ...) rest ...)
     (cond
      ((eq? test 'else)
       (if (null? body) (if #f #f) (evaluate `(begin ,@body) env)))
      (else
       (let ((val (evaluate test env)))
         (cond
          ((not val) (evaluate `(cond ,@rest) env))
          ((null? body) val)
          (else (evaluate `(begin ,@body) env)))))))

    ;; case
    (('case key-expr clauses ...)
     (let ((key (evaluate key-expr env)))
       (let case-loop ((cls clauses))
         (match cls
           (() (if #f #f))
           ((('else body body* ...) . _)
            (evaluate `(begin ,body ,@body*) env))
           ((((datums ...) body body* ...) . rest)
            (if (let datum-loop ((ds datums))
                  (cond ((null? ds) #f) ((eqv? key (car ds)) #t) (else (datum-loop (cdr ds)))))
                (evaluate `(begin ,body ,@body*) env)
                (case-loop rest)))))))

    ;; and — short-circuit, returns last true value or #f
    (('and) #t)
    (('and expr) (evaluate expr env))
    (('and expr rest ...)
     (let ((val (evaluate expr env)))
       (if val
           (evaluate `(and ,@rest) env)
           #f)))

    ;; or — short-circuit, returns first true value or #f
    (('or) #f)
    (('or expr) (evaluate expr env))
    (('or expr rest ...)
     (let ((val (evaluate expr env)))
       (if val val (evaluate `(or ,@rest) env))))

    ;; when / unless
    (('when test body body* ...)
     (if (evaluate test env)
         (evaluate `(begin ,body ,@body*) env)
         (if #f #f)))
    (('unless test body body* ...)
     (if (not (evaluate test env))
         (evaluate `(begin ,body ,@body*) env)
         (if #f #f)))

    ;; do — desugar to named let
    (('do ((vars inits steps ...) ...) (test exit-body ...) cmd ...)
     (let ((step-exprs (map (lambda (v s) (if (null? s) v (car s))) vars steps)))
       (evaluate `(let loop ,(map list vars inits)
                    (if ,test
                        (begin ,@(if (null? exit-body) '((if #f #f)) exit-body))
                        (begin ,@(if (null? cmd) '() cmd) (loop ,@step-exprs))))
                 env)))

    ;; Lambda: capture the full closure env for bindings/validator/history,
    ;; but resolve the acting expressor at call time from *current-caller*.
    (('lambda params body body* ...)
     (let ((closure-env env)
           (full-body (if (null? body*) body `(begin ,body ,@body*))))
       (lambda vals
         (let* ((caller-expressor (or *current-caller*
                                      (env-expressor closure-env)))
                (call-env (make-env
                            (bind-params params vals (env-bindings closure-env))
                            (env-validator closure-env)
                            (env-history closure-env)
                            caller-expressor)))
           (evaluate full-body call-env)))))

    ;; Create an expressor (identity)
    (('defexpressor name key)
     (let* ((eval-name (evaluate name env))
            (eval-key  (evaluate key env))
            (id (make-expressor eval-name eval-key)))
       (env-modify env (env-expressor env)
                  eval-name id
                  `(defexpressor ,name ,key))))

    ;; Switch expressor (with authentication)
    (('as expressor-id expr)
     (let ((target-expressor (evaluate expressor-id env)))
       (if (and (expressor? target-expressor)
                (authenticate? target-expressor))
           (evaluate expr
                    (make-env (env-bindings env)
                             (env-validator env)
                             (env-history env)
                             target-expressor))
           (error "Authentication failed:" expressor-id))))

    ;; Modify — now records expressor
    (('modify! name value)
     (env-modify env (env-expressor env)
                 (evaluate name env)
                 (evaluate value env)
                 `(modify! ,name ,value)))

    ;; Enact — now records expressor
    (('enact! validator-expr)
     (env-enact env (env-expressor env)
                validator-expr
                `(enact! ,validator-expr)))

    ;; Rollback — now requires expressor validation
    (('rollback! version)
     (let* ((target-version (evaluate version env))
            (expressor (env-expressor env))
            (validator (env-validator env))
            (rolled-back (env-rollback env target-version expressor)))
       (if (validator expressor 'rollback target-version
                     (env-bindings rolled-back) env)
           rolled-back
           (error "Rollback rejected by validator:" target-version))))

    ;; Show history with expressors
    (('show-history)
     (let ((history (env-history env)))
       (for-each (lambda (entry)
                   (display "Version ")
                   (display (history-version entry))
                   (display " [")
                   (display (expressor-name (history-expressor entry)))
                   (display "] : ")
                   (display (history-expr entry))
                   (display " (parent: ")
                   (display (history-parent entry))
                   (display ")")
                   (newline))
                 (reverse history))
       env))

    ;; Show expressors (alist-based iteration)
    (('show-expressors)
     (for-each (lambda (pair)
                 (let ((data (cdr pair)))
                   (display (assq-ref data 'name))
                   (display " (")
                   (display (car pair))
                   (display ")\n")))
               *expressor-store*)
     env)

    ;; AI: call the registered handler, return a string
    (('ai prompt-expr)
     (let ((handler *ai-handler*))
       (unless handler (error "AI not available. Load (metaorg ai) module."))
       (handler (evaluate prompt-expr env) env)))

    ;; AI-eval: call the registered handler, evaluate the returned expression
    (('ai-eval prompt-expr)
     (let ((handler *ai-eval-handler*))
       (unless handler (error "AI not available. Load (metaorg ai) module."))
       (let ((expr (handler (evaluate prompt-expr env) env)))
         (evaluate expr env))))

    ;; Application: inject the caller's expressor so lambdas attribute actions
    ;; to whoever is actually invoking them, not to their defining author.
    ((proc-expr arg-exprs ...)
     (let ((proc (evaluate proc-expr env))
           (evaluated-args (map (lambda (arg) (evaluate arg env)) arg-exprs)))
       (let ((saved *current-caller*))
         (set! *current-caller* (env-expressor env))
         (let ((result (apply proc evaluated-args)))
           (set! *current-caller* saved)
           result)))))))
