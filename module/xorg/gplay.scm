;;; module/xorg/gplay.scm — Goblins-based org actor system
;;; Compatible with both Guile and Hoot/WASM

(define-module (xorg gplay)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib sealers)
  #:use-module (goblins actor-lib ward)
  #:use-module ((goblins utils crypto) #:select (generate-key-pair key-pair->public-key))
  #:use-module (ice-9 match)
  #:use-module (ice-9 receive)
  #:export (^org
            evaluate
            make-initial-org
            make-persistent-org
            gplay-env
            default-validator
            next-version
            make-id
            *current-caller*
            set-ai-handler!
            set-ai-eval-handler!
            ^expressor-identity
            ^expressor-controller
            ^org-inbox
            create-expressor-pair
            make-org-with-inbox
            approve-membership
            *inbox*
            *inbox-incanter*
            ancestor-chain
            generate-key-pair
            key-pair->public-key))

;;; Hoot/WASM compatibility: eval and interaction-environment are not
;;; automatically available in Hoot's module system.
(cond-expand
  (hoot
   (define (%restore-eval expr env)
     (error "eval not available in WASM persistence restore"))
   (define (%restore-interaction-env)
     (error "interaction-environment not available in WASM")))
  (else
   (define %restore-eval eval)
   (define (%restore-interaction-env) (interaction-environment))))

;;; ── Helpers ─────────────────────────────────────────────────────────────────

(define *id-counter* 0)

(define (make-id name)
  (set! *id-counter* (+ *id-counter* 1))
  (string->symbol
   (string-append (symbol->string name) "-" (number->string *id-counter*))))

(define (extend-env base names vals)
  (if (null? names)
      base
      (cons (cons (car names) (car vals))
            (extend-env base (cdr names) (cdr vals)))))

(define (bind-params params vals base)
  (cond
   ((null? params) base)
   ((symbol? params) (cons (cons params vals) base))
   ((pair? params)
    (cons (cons (car params) (car vals))
          (bind-params (cdr params) (cdr vals) base)))))

(define (filter-serializable-bindings bindings)
  "Remove procedure-valued bindings (not serializable by Goblins persistence)."
  (let loop ((rest bindings) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((pair (car rest)))
          (if (procedure? (cdr pair))
              (loop (cdr rest) acc)
              (loop (cdr rest) (cons pair acc)))))))

;;; ── Version management ──────────────────────────────────────────────────────

(define *version-counter* 0)

(define (next-version)
  (set! *version-counter* (+ *version-counter* 1))
  *version-counter*)

;;; ── Defaults ────────────────────────────────────────────────────────────────

(define (default-validator expressor name value pre post)
  #t)

;;; ── Caller tracking (global var, Guile + Hoot compatible) ──────────────────

(define *current-caller* #f)

;;; ── Inbox parameters ────────────────────────────────────────────────────────

(define *inbox* (make-parameter #f))
(define *inbox-incanter* (make-parameter #f))

;;; ── AI integration globals ──────────────────────────────────────────────────

(define *ai-handler* #f)
(define *ai-eval-handler* #f)

(define (set-ai-handler! fn) (set! *ai-handler* fn))
(define (set-ai-eval-handler! fn) (set! *ai-eval-handler* fn))

;;; ── Persistence base-bindings injection ─────────────────────────────────────

(define *restore-base-bindings* (make-parameter '()))

;;; ── Identity/controller actors ──────────────────────────────────────────────

(define (^expressor-identity bcom name unsealer sealed?
                              subscription-sealer subscription-unsealer)
  "Public face of an expressor. Freely shareable.
The subscription-sealer allows the host to seal capabilities (e.g. a controller)
so that only this identity's holder can unseal them."
  (methods
   [(name) name]
   [(unsealer) unsealer]
   [(sealed?) sealed?]
   [(subscription-sealer) subscription-sealer]
   [(subscription-unsealer) subscription-unsealer]))

;;; ── ^org actor ──────────────────────────────────────────────────────────────

(define-actor (^org bcom bindings validator-expr validator-proc
                    history expressor-store current-expressor base-bindings
                    head-version org-public-key)
  #:version 3
  #:portrait
  (lambda ()
    (list (filter-serializable-bindings bindings)
          validator-expr
          (map (lambda (entry)
                 (if (>= (length entry) 5)
                     (let ((snap (list-ref entry 4)))
                       (list (car entry) (cadr entry) (caddr entry) (cadddr entry)
                             (list (filter-serializable-bindings (car snap))
                                   (cadr snap))))
                     entry))
               history)
          expressor-store current-expressor
          head-version org-public-key))
  #:restore
  (lambda (version data-bindings vexpr history estore cur-exp . rest)
    (let* ((base (*restore-base-bindings*))
           (hv (if (null? rest) (car (car history)) (car rest)))
           (pk (if (and (not (null? rest)) (not (null? (cdr rest))))
                   (cadr rest) '(none)))
           (restored-history
            (map (lambda (entry)
                   (if (and (>= (length entry) 5)
                            (= (length (list-ref entry 4)) 2))
                       (let* ((snap (list-ref entry 4))
                              (snap-vexpr (cadr snap))
                              (snap-vproc (%restore-eval snap-vexpr
                                                         (%restore-interaction-env))))
                         (list (car entry) (cadr entry) (caddr entry) (cadddr entry)
                               (list (append (car snap) base)
                                     snap-vexpr snap-vproc)))
                       entry))
                 history)))
      (spawn ^org
             (append data-bindings base)
             vexpr
             (%restore-eval vexpr (%restore-interaction-env))
             restored-history estore cur-exp
             base hv pk)))

  (define (lookup name)
    (cond ((assq name bindings) => cdr)
          (else (error "Variable unbound:" name))))

  (define (expressor-ref id)
    (cond ((assq id expressor-store) => cdr)
          (else #f)))

  (methods
   [(lookup name) (lookup name)]
   [(bindings) bindings]
   [(history) history]
   [(current-expressor) current-expressor]
   [(validator-expr) validator-expr]
   [(validator-proc) validator-proc]
   [(expressor-store) expressor-store]
   [(base-bindings) base-bindings]
   [(head-version) head-version]
   [(public-key) org-public-key]
   [(expressor? id) (and (expressor-ref id) #t)]
   [(expressor-name id)
    (let ((d (expressor-ref id)))
      (and d (assq-ref d 'name)))]
   [(expressor-key id)
    (let ((d (expressor-ref id)))
      (and d (assq-ref d 'public-key)))]
   [(expressor-unsealer id)
    (let ((d (expressor-ref id)))
      (and d (assq-ref d 'unsealer)))]
   [(expressor-sealed? id)
    (let ((d (expressor-ref id)))
      (and d (assq-ref d 'sealed?)))]

   [(authenticate-sealer sealer)
    ;; Seal a nonce, then check each expressor's sealed? predicate.
    ;; Returns the matching expressor ID, or #f.
    (let ((nonce ($ sealer 'test-nonce)))
      (let loop ((store expressor-store))
        (cond ((null? store) #f)
              (($ (assq-ref (cdar store) 'sealed?) nonce)
               (caar store))
              (else (loop (cdr store))))))]

   [(modify! name value new-history-entry)
    (let* ((new-bindings (cons (cons name value) bindings))
           (snapshot (list new-bindings validator-expr validator-proc)))
      (bcom (^org bcom
                  new-bindings validator-expr validator-proc
                  (cons (append new-history-entry (list snapshot)) history)
                  expressor-store current-expressor base-bindings
                  (car new-history-entry) org-public-key)))]

   [(enact! new-validator-expr new-validator-proc new-history-entry)
    (let ((snapshot (list bindings new-validator-expr new-validator-proc)))
      (bcom (^org bcom bindings
                  new-validator-expr new-validator-proc
                  (cons (append new-history-entry (list snapshot)) history)
                  expressor-store current-expressor base-bindings
                  (car new-history-entry) org-public-key)))]

   [(register-expressor! id data new-history-entry)
    (let ((snapshot (list bindings validator-expr validator-proc)))
      (bcom (^org bcom
                  bindings validator-expr validator-proc
                  (cons (append new-history-entry (list snapshot)) history)
                  (cons (cons id data) expressor-store)
                  current-expressor base-bindings
                  (car new-history-entry) org-public-key)))]

   [(with-expressor exp)
    (bcom (^org bcom bindings validator-expr validator-proc
                history expressor-store exp base-bindings
                head-version org-public-key))]

   [(rollback! target-version)
    (let loop ((h history))
      (cond
       ((null? h) (error "Version not found:" target-version))
       ((= (car (car h)) target-version)
        (let ((snapshot (list-ref (car h) 4)))
          (bcom (^org bcom
                      (car snapshot) (cadr snapshot) (caddr snapshot)
                      history expressor-store current-expressor base-bindings
                      target-version org-public-key))))
       (else (loop (cdr h)))))]))

;;; ── Factory ─────────────────────────────────────────────────────────────────

(define* (make-initial-org base-bindings #:key (public-key #f))
  "Spawn a fresh ^org actor with a public key. Must be called within a vat.
The public key is accessible via the org's (public-key) method."
  (let* ((pk (or public-key '(none)))
         (genesis-id (make-id 'genesis))
         (genesis-data `((id . ,genesis-id)
                         (name . genesis)
                         (public-key . ,pk)))
         (initial-history (list (list 0 genesis-id '(quote initial) 0
                                      (list base-bindings
                                            '(lambda (e n v pre post) #t)
                                            default-validator))))
         (initial-store (list (cons genesis-id genesis-data))))
    (spawn ^org
           base-bindings
           '(lambda (e n v pre post) #t)
           default-validator
           initial-history
           initial-store
           genesis-id
           base-bindings
           0
           pk)))

;;; ── Persistence environment ─────────────────────────────────────────────────

(define gplay-env
  (make-persistence-env
   `((((xorg gplay) ^org) ,^org))))

(define (make-persistent-org name base-bindings store)
  "Create a persistent org vat. Returns (values vat org)."
  (parameterize ((*restore-base-bindings* base-bindings))
    (spawn-persistent-vat
     gplay-env
     (lambda () (make-initial-org base-bindings))
     store
     #:name name
     #:version 3)))

;;; ── Rollback helpers ────────────────────────────────────────────────────────

(define (ancestor-chain history target)
  "Walk parent pointers from target to version 0, return in chronological order."
  (define (find-entry ver)
    (let loop ((h history))
      (cond ((null? h) (error "Version not found:" ver))
            ((= (car (car h)) ver) (car h))
            (else (loop (cdr h))))))
  (let loop ((ver target) (chain '()))
    (let ((entry (find-entry ver)))
      (if (<= ver 0)
          (cons entry chain)
          (loop (cadddr entry) (cons entry chain))))))

;;; ── Evaluator ───────────────────────────────────────────────────────────────

(define (evaluate expr org local-bindings current-expressor)
  (match expr
    ;; Literals
    ((or #t #f (? number?) (? string?)) expr)
    (('quote quoted-expr) quoted-expr)

    ;; Symbol lookup: local-bindings first, then org
    ((? symbol? name)
     (cond ((assq name local-bindings) => cdr)
           (else ($ org 'lookup name))))

    ;; if — three-branch
    (('if test consequent alternate)
     (if (evaluate test org local-bindings current-expressor)
         (evaluate consequent org local-bindings current-expressor)
         (evaluate alternate org local-bindings current-expressor)))

    ;; if — two-branch
    (('if test consequent)
     (if (evaluate test org local-bindings current-expressor)
         (evaluate consequent org local-bindings current-expressor)
         (if #f #f)))

    ;; begin — evaluate in sequence, no env threading needed
    (('begin)
     (if #f #f))
    (('begin body body* ...)
     (let loop ((exprs (cons body body*)))
       (if (null? (cdr exprs))
           (evaluate (car exprs) org local-bindings current-expressor)
           (begin (evaluate (car exprs) org local-bindings current-expressor)
                  (loop (cdr exprs))))))

    ;; named let — loop construct
    (('let (? symbol? name) ((vars vals) ...) body body* ...)
     (let* ((eval-inits (map (lambda (v) (evaluate v org local-bindings current-expressor)) vals))
            (full-body (if (null? body*) body `(begin ,body ,@body*))))
       (letrec ((loop-fn
                 (lambda args
                   (let ((loop-bindings
                          (extend-env
                           (cons (cons name loop-fn) local-bindings)
                           vars args)))
                     (evaluate full-body org loop-bindings current-expressor)))))
         (apply loop-fn eval-inits))))

    ;; let — parallel bindings
    (('let ((names vals) ...) body body* ...)
     (let ((eval-vals (map (lambda (v) (evaluate v org local-bindings current-expressor)) vals)))
       (let ((let-bindings (extend-env local-bindings names eval-vals)))
         (if (null? body*)
             (evaluate body org let-bindings current-expressor)
             (evaluate `(begin ,body ,@body*) org let-bindings current-expressor)))))

    ;; let* — sequential bindings
    (('let* () body body* ...)
     (if (null? body*)
         (evaluate body org local-bindings current-expressor)
         (evaluate `(begin ,body ,@body*) org local-bindings current-expressor)))
    (('let* ((name val) rest ...) body body* ...)
     (let ((eval-val (evaluate val org local-bindings current-expressor)))
       (evaluate `(let* ,rest ,body ,@body*)
                 org
                 (cons (cons name eval-val) local-bindings)
                 current-expressor)))

    ;; letrec — mutually recursive bindings via vector boxes
    (('letrec ((names vals) ...) body body* ...)
     (let* ((boxes (map (lambda (_) (make-vector 1 #f)) names))
            (wrappers (map (lambda (box)
                             (lambda args (apply (vector-ref box 0) args)))
                           boxes))
            (letrec-bindings (append (map cons names wrappers) local-bindings))
            (eval-vals (map (lambda (v) (evaluate v org letrec-bindings current-expressor)) vals))
            (full-body (if (null? body*) body `(begin ,body ,@body*))))
       (for-each (lambda (box val) (vector-set! box 0 val)) boxes eval-vals)
       (evaluate full-body org letrec-bindings current-expressor)))

    ;; define — function shorthand
    (('define ((? symbol? name) . params) body body* ...)
     (evaluate `(define ,name (lambda ,params ,@(if (null? body*) (list body) (cons body body*))))
               org local-bindings current-expressor))

    ;; define — value binding (governed)
    (('define (? symbol? name) value-expr)
     (let* ((value (evaluate value-expr org local-bindings current-expressor))
            (pre-bindings ($ org 'bindings))
            (post-bindings (cons (cons name value) pre-bindings))
            (validator ($ org 'validator-proc))
            (version (next-version))
            (entry (list version current-expressor `(define ,name ,value-expr)
                         ($ org 'head-version))))
       (if (validator current-expressor name value pre-bindings post-bindings)
           (begin ($ org 'modify! name value entry)
                  (if #f #f))
           (error "Validation failed:" current-expressor name value))))

    ;; cond
    (('cond)
     (if #f #f))
    (('cond (test body ...) rest ...)
     (cond
      ((eq? test 'else)
       (if (null? body)
           (if #f #f)
           (evaluate `(begin ,@body) org local-bindings current-expressor)))
      (else
       (let ((val (evaluate test org local-bindings current-expressor)))
         (cond
          ((not val) (evaluate `(cond ,@rest) org local-bindings current-expressor))
          ((null? body) val)
          (else (evaluate `(begin ,@body) org local-bindings current-expressor)))))))

    ;; case
    (('case key-expr clauses ...)
     (let ((key (evaluate key-expr org local-bindings current-expressor)))
       (let case-loop ((cls clauses))
         (match cls
           (() (if #f #f))
           ((('else body body* ...) . _)
            (evaluate `(begin ,body ,@body*) org local-bindings current-expressor))
           ((((datums ...) body body* ...) . rest)
            (if (let datum-loop ((ds datums))
                  (cond ((null? ds) #f)
                        ((eqv? key (car ds)) #t)
                        (else (datum-loop (cdr ds)))))
                (evaluate `(begin ,body ,@body*) org local-bindings current-expressor)
                (case-loop rest)))))))

    ;; and
    (('and) #t)
    (('and expr) (evaluate expr org local-bindings current-expressor))
    (('and expr rest ...)
     (let ((val (evaluate expr org local-bindings current-expressor)))
       (if val (evaluate `(and ,@rest) org local-bindings current-expressor)
           #f)))

    ;; or
    (('or) #f)
    (('or expr) (evaluate expr org local-bindings current-expressor))
    (('or expr rest ...)
     (let ((val (evaluate expr org local-bindings current-expressor)))
       (if val val (evaluate `(or ,@rest) org local-bindings current-expressor))))

    ;; when / unless
    (('when test body body* ...)
     (if (evaluate test org local-bindings current-expressor)
         (evaluate `(begin ,body ,@body*) org local-bindings current-expressor)
         (if #f #f)))
    (('unless test body body* ...)
     (if (not (evaluate test org local-bindings current-expressor))
         (evaluate `(begin ,body ,@body*) org local-bindings current-expressor)
         (if #f #f)))

    ;; do — desugar to named let
    (('do ((vars inits steps ...) ...) (test exit-body ...) cmd ...)
     (let ((step-exprs (map (lambda (v s) (if (null? s) v (car s))) vars steps)))
       (evaluate `(let loop ,(map list vars inits)
                    (if ,test
                        (begin ,@(if (null? exit-body) '((if #f #f)) exit-body))
                        (begin ,@(if (null? cmd) '() cmd) (loop ,@step-exprs))))
                 org local-bindings current-expressor)))

    ;; lambda — captures local-bindings; org is shared (live lookup)
    (('lambda params body body* ...)
     (let ((closure-bindings local-bindings)
           (full-body (if (null? body*) body `(begin ,body ,@body*))))
       (lambda vals
         (let ((caller (or *current-caller* current-expressor)))
           (evaluate full-body org
                     (bind-params params vals closure-bindings)
                     caller)))))

    ;; defexpressor — create expressor identity with sealer triplet
    (('defexpressor name-expr key-expr)
     (let* ((eval-name (evaluate name-expr org local-bindings current-expressor))
            (eval-key (evaluate key-expr org local-bindings current-expressor))
            (id (make-id eval-name)))
       (receive (sealer unsealer sealed?)
         (spawn-sealer-triplet)
         (let* ((data `((id . ,id) (name . ,eval-name) (public-key . ,eval-key)
                        (unsealer . ,unsealer) (sealed? . ,sealed?)))
                (bindings ($ org 'bindings))
                (validator ($ org 'validator-proc))
                (version (next-version))
                (entry (list version current-expressor
                             `(defexpressor ,name-expr ,key-expr)
                             ($ org 'head-version))))
           (if (validator current-expressor eval-name id bindings bindings)
               (begin ($ org 'register-expressor! id data entry)
                      sealer)
               (error "Validation failed:" current-expressor eval-name))))))

    ;; as — switch expressor for body (requires sealer capability)
    (('as sealer-expr body-expr)
     (let* ((sealer (evaluate sealer-expr org local-bindings current-expressor))
            (id ($ org 'authenticate-sealer sealer)))
       (unless id
         (error "Invalid expressor credential — must provide the sealer returned by defexpressor"))
       (evaluate body-expr org local-bindings id)))

    ;; modify! — validated binding mutation
    (('modify! name-expr value-expr)
     (let* ((name (evaluate name-expr org local-bindings current-expressor))
            (value (evaluate value-expr org local-bindings current-expressor))
            (pre-bindings ($ org 'bindings))
            (post-bindings (cons (cons name value) pre-bindings))
            (validator ($ org 'validator-proc))
            (version (next-version))
            (entry (list version current-expressor
                         `(modify! ,name-expr ,value-expr)
                         ($ org 'head-version))))
       (if (validator current-expressor name value pre-bindings post-bindings)
           (begin ($ org 'modify! name value entry)
                  (if #f #f))
           (error "Validation failed:" current-expressor name value))))

    ;; enact! — install new validator
    (('enact! validator-expr)
     (let* ((new-proc (evaluate validator-expr org local-bindings current-expressor))
            (version (next-version))
            (entry (list version current-expressor
                         `(enact! ,validator-expr)
                         ($ org 'head-version))))
       (if (new-proc current-expressor 'validator new-proc
                     ($ org 'bindings) ($ org 'bindings))
           (begin ($ org 'enact! validator-expr new-proc entry)
                  (if #f #f))
           (error "Validator rejected by itself:" current-expressor new-proc))))

    ;; rollback! — restore snapshot at target version
    (('rollback! version-expr)
     (let* ((target (evaluate version-expr org local-bindings current-expressor))
            (validator ($ org 'validator-proc)))
       (unless (validator current-expressor 'rollback target
                          ($ org 'bindings) ($ org 'bindings))
         (error "Rollback rejected:" target))
       ($ org 'rollback! target)
       (if #f #f)))

    ;; show-history — return string showing current branch
    (('show-history)
     (let ((out (open-output-string)))
       (for-each (lambda (entry)
                   (display "Version " out)
                   (display (car entry) out)
                   (display " [" out)
                   (display ($ org 'expressor-name (cadr entry)) out)
                   (display "] : " out)
                   (write (caddr entry) out)
                   (display " (parent: " out)
                   (display (cadddr entry) out)
                   (display ")" out)
                   (newline out))
                 (ancestor-chain ($ org 'history) ($ org 'head-version)))
       (get-output-string out)))

    ;; show-expressors — return string so WASM REPL can display it
    ;; Indicates AI-powered expressors by checking for name:prompt bindings
    (('show-expressors)
     (let ((out (open-output-string))
           (org-bindings ($ org 'bindings)))
       (for-each (lambda (pair)
                   (let* ((data (cdr pair))
                          (name (assq-ref data 'name))
                          (prompt-key (and name (string->symbol
                                                 (string-append
                                                  (symbol->string name) ":prompt"))))
                          (prompt-entry (and prompt-key
                                             (assq prompt-key org-bindings))))
                     (display name out)
                     (display " (" out)
                     (display (car pair) out)
                     (display ")" out)
                     (when prompt-entry
                       (let* ((prompt (cdr prompt-entry))
                              (truncated (if (and (string? prompt)
                                                  (> (string-length prompt) 40))
                                             (string-append
                                              (substring prompt 0 40) "...")
                                             prompt)))
                         (display " [ai: " out)
                         (write truncated out)
                         (display "]" out)))
                     (newline out)))
                 ($ org 'expressor-store))
       (get-output-string out)))

    ;; public-key — return this org's Ed25519 public key
    (('public-key)
     ($ org 'public-key))

    ;; ai
    (('ai prompt-expr)
     (let ((handler *ai-handler*))
       (unless handler (error "AI not available. Load (xorg ai) module."))
       (handler (evaluate prompt-expr org local-bindings current-expressor)
                org current-expressor)))

    ;; ai-eval
    (('ai-eval prompt-expr)
     (let ((handler *ai-eval-handler*))
       (unless handler (error "AI not available. Load (xorg ai) module."))
       (let ((result-expr
              (handler (evaluate prompt-expr org local-bindings current-expressor)
                       org current-expressor)))
         (evaluate result-expr org local-bindings current-expressor))))

    ;; process-message — process an inbox message and evaluate its expression
    (('process-message msg-id-expr)
     (unless (*inbox*)
       (error "No inbox bound. Use *inbox* and *inbox-incanter* parameters."))
     (let* ((msg-id (evaluate msg-id-expr org local-bindings current-expressor))
            (expr ($ (*inbox-incanter*) (*inbox*) 'process msg-id)))
       (evaluate expr org local-bindings current-expressor)))

    ;; retract-message — retract a pending inbox message
    (('retract-message msg-id-expr sender-expr)
     (unless (*inbox*)
       (error "No inbox bound. Use *inbox* and *inbox-incanter* parameters."))
     (let* ((msg-id (evaluate msg-id-expr org local-bindings current-expressor))
            (sender (evaluate sender-expr org local-bindings current-expressor)))
       ($ (*inbox-incanter*) (*inbox*) 'retract msg-id sender)
       (if #f #f)))

    ;; Application — caller tracking via save/restore (Hoot compatible)
    ((proc-expr arg-exprs ...)
     (let ((proc (evaluate proc-expr org local-bindings current-expressor))
           (args (map (lambda (a) (evaluate a org local-bindings current-expressor))
                      arg-exprs)))
       (let ((saved *current-caller*))
         (set! *current-caller* current-expressor)
         (let ((result (apply proc args)))
           (set! *current-caller* saved)
           result))))))

;;; ── Expressor controller ───────────────────────────────────────────────────

(define (^expressor-controller bcom org-ref expressor-id sealer)
  "Private controller for an expressor. Held only by the authorized party."
  (methods
   [(evaluate expr)
    (evaluate expr org-ref '() expressor-id)]
   [(evaluate-with-locals expr locals)
    (evaluate expr org-ref locals expressor-id)]
   [(seal content) ($ sealer content)]
   [(expressor-id) expressor-id]))

;;; ── Warded inbox actor ─────────────────────────────────────────────────────

(define (^org-inbox bcom org-ref entries next-id inbox-warden inbox-incanter)
  (define (find-entry msg-id)
    (let loop ((es entries))
      (cond ((null? es) (error "Message not found:" msg-id))
            ((= (assq-ref (car es) 'id) msg-id) (car es))
            (else (loop (cdr es))))))

  (define (update-status msg-id new-status)
    (map (lambda (e)
           (if (= (assq-ref e 'id) msg-id)
               (map (lambda (pair)
                      (if (eq? (car pair) 'status)
                          (cons 'status new-status)
                          pair))
                    e)
               e))
         entries))

  (define controller-methods
    (methods
     [(process msg-id)
      (let ((entry (find-entry msg-id)))
        (bcom (^org-inbox bcom org-ref
                          (update-status msg-id 'processed)
                          next-id inbox-warden inbox-incanter)
              (assq-ref entry 'expr)))]
     [(retract msg-id sender-ref)
      (let ((entry (find-entry msg-id)))
        (unless (equal? (assq-ref entry 'sender) sender-ref)
          (error "Not your message"))
        (bcom (^org-inbox bcom org-ref
                          (update-status msg-id 'retracted)
                          next-id inbox-warden inbox-incanter)))]))

  (define public-methods
    (methods
     [(submit expr sender-identity)
      (bcom (^org-inbox bcom org-ref
                        (cons `((id . ,next-id) (sender . ,sender-identity)
                                (expr . ,expr) (status . pending))
                              entries)
                        (+ next-id 1) inbox-warden inbox-incanter)
            next-id)]
     [(pending)
      (let loop ((es entries) (acc '()))
        (cond ((null? es) (reverse acc))
              ((eq? (assq-ref (car es) 'status) 'pending)
               (loop (cdr es) (cons (car es) acc)))
              (else (loop (cdr es) acc))))]
     [(all-entries) entries]))

  (ward inbox-warden controller-methods
        #:extends public-methods))

;;; ── Expressor pair factory ─────────────────────────────────────────────────

(define (create-expressor-pair org name public-key)
  "Create an identity/controller pair for an expressor. Must be called within a vat.
Returns (identity . controller). The identity carries a subscription-sealer for
the sealed membership handshake."
  (receive (sealer unsealer sealed?)
    (spawn-sealer-triplet)
    (receive (sub-sealer sub-unsealer sub-sealed?)
      (spawn-sealer-triplet)
      (let* ((id (make-id name))
             (identity (spawn ^expressor-identity name unsealer sealed?
                              sub-sealer sub-unsealer))
             (controller (spawn ^expressor-controller org id sealer))
             (data `((id . ,id) (name . ,name) (public-key . ,public-key)
                     (unsealer . ,unsealer) (sealed? . ,sealed?)
                     (identity . ,identity)))
           (version (next-version))
           (entry (list version ($ org 'current-expressor)
                        `(defexpressor ',name ,public-key)
                        ($ org 'head-version))))
      ($ org 'register-expressor! id data entry)
      (cons identity controller)))))

;;; ── Org-with-inbox factory ─────────────────────────────────────────────────

(define (make-org-with-inbox base-bindings)
  "Spawn org + inbox pair. Returns (org . inbox . incanter) triple."
  (let ((org (make-initial-org base-bindings)))
    (receive (warden incanter)
      (spawn-warding-pair)
      (let ((inbox (spawn ^org-inbox org '() 0 warden incanter)))
        (cons org (cons inbox incanter))))))

;;; ── Membership handshake ───────────────────────────────────────────────────

(define (approve-membership inbox incanter msg-id org name public-key
                            applicant-identity)
  "Approve a membership request. Returns a sealed controller only the applicant
can unseal."
  ($ incanter inbox 'process msg-id)
  (let* ((pair (create-expressor-pair org name public-key))
         (controller (cdr pair))
         (sub-sealer ($ applicant-identity 'subscription-sealer))
         (sealed-controller ($ sub-sealer controller)))
    sealed-controller))
