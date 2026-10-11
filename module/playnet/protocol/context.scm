;;; module/playnet/protocol/context.scm — an actor's context: what its fragments share, as one record
;;;
;;; An actor composed of fragments (the scope, the governance service, the
;;; planner service) hands each fragment one record: the wiring it was spawned
;;; with, the cells a door writes, and the helpers the core defines and hands
;;; over. `define-context` states that record ONCE, by its field names, and
;;; derives everything the actor and its fragments use from that one list:
;;;
;;;   (define-context planner-ctx (ph-ok? (lambda (_aid) #t)) witness-door …)
;;;
;;;   <planner-ctx>, planner-ctx?              the record and its predicate
;;;   planner-ctx-FIELD, set-planner-ctx-FIELD!  an accessor and a setter per field
;;;   (make-planner-ctx #:FIELD value …)       every field a keyword; a field
;;;                                            written (FIELD default) takes that
;;;                                            default, any other #f
;;;   (with-planner-ctx ctx body …)            every field under its own name,
;;;                                            read through the accessor on each
;;;                                            use and written through the setter
;;;                                            on set!, so a cell one fragment
;;;                                            sets is set for every other
;;;   (planner-ctx-install! ctx NAME …)        each NAME's value into the field
;;;                                            of that name: the core's hand-over
;;;
;;; The body of `with-…` is a body: it may define, and a define of a field's
;;; name shadows the field, which is how a core defines its helpers under the
;;; names the fragments read them by and then installs them. The whole form
;;; stands wherever an expression may, including as an actor's last form.
;;;
;;; A fragment imports the `with-…` form alone: the accessors it expands to
;;; resolve in the module that defined the context, by hygiene.

(define-module (playnet protocol context)
  #:use-module (srfi srfi-9)
  #:export (define-context context-bind context-install))

(define (context-bind use ctx body home fields)
  "The `with-…` expansion for USE: every symbol of FIELDS bound at the use site
to the accessor and setter named after HOME, the context's name, over CTX; BODY a
body."
  (let ((prefix (syntax->datum home)))
    (with-syntax ((ctx ctx)
                  ((b ...) body)
                  ((name ...) (map (lambda (f) (datum->syntax use f)) fields))
                  ((ref ...)  (map (lambda (f) (datum->syntax home (symbol-append prefix '- f))) fields))
                  ((setr ...) (map (lambda (f) (datum->syntax home (symbol-append 'set- prefix '- f '!))) fields)))
      #'(let-syntax ((name (identifier-syntax (_ (ref ctx)) ((set! _ v) (setr ctx v)))) ...)
          (let () b ...)))))

(define (context-install ctx home names)
  "The `…-install!` expansion: each of NAMES, an identifier, into the field of
that name of CTX, through the setter named after HOME."
  (let ((prefix (syntax->datum home)))
    (with-syntax ((ctx ctx)
                  ((name ...) names)
                  ((setr ...) (map (lambda (n) (datum->syntax home (symbol-append 'set- prefix '- (syntax->datum n) '!))) names)))
      #'(begin (setr ctx name) ...))))

(define-syntax define-context
  (lambda (x)
    (syntax-case x ()
      ((_ ctx-name spec ...)
       (let* ((specs  (map (lambda (s) (let ((d (syntax->datum s))) (if (pair? d) d (list d #f)))) #'(spec ...)))
              (fields (map car specs))
              (sym    (syntax->datum #'ctx-name))
              (id     (lambda (s) (datum->syntax #'ctx-name s))))
         (with-syntax ((rtd          (id (symbol-append '< sym '>)))
                       (%make        (id (symbol-append '%make- sym)))
                       (make         (id (symbol-append 'make- sym)))
                       (pred         (id (symbol-append sym '?)))
                       (with-name    (id (symbol-append 'with- sym)))
                       (install-name (id (symbol-append sym '-install!)))
                       ((field ...)   (map id fields))
                       ((default ...) (map (lambda (s) (datum->syntax x (cadr s))) specs))
                       ((ref ...)     (map (lambda (f) (id (symbol-append sym '- f))) fields))
                       ((setr ...)    (map (lambda (f) (id (symbol-append 'set- sym '- f '!))) fields)))
           #'(begin
               (define-record-type rtd
                 (%make field ...)
                 pred
                 (field ref setr) ...)
               (define* (make #:key (field default) ...)
                 (%make field ...))
               (define-syntax with-name
                 (lambda (y)
                   (syntax-case y ()
                     ((_ c b (... ...))
                      (context-bind y #'c #'(b (... ...)) #'ctx-name '(field ...))))))
               (define-syntax install-name
                 (lambda (y)
                   (syntax-case y ()
                     ((_ c n (... ...))
                      (context-install #'c #'ctx-name #'(n (... ...))))))))))))))
