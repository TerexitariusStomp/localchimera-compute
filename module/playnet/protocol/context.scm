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
;;;   (copy-planner-ctx ctx)                   a value of its own: each table
;;;                                            copied, each other field shared
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
;;;
;;; A context a MODULE holds, rather than an actor: `(define-context settings
;;; #:cell %settings spec …)` adds the cell, holding one instance from load, each
;;; field as a top-level name over that cell (the engine's `*emp-rho*` reads
;;; `(settings-*emp-rho* %settings)` and `(set! *emp-rho* v)` writes it), and
;;; `reset-settings!`, a fresh instance. An importer of such a name reads and
;;; writes the one instance without assigning an imported binding, which Hoot
;;; refuses and Guile would let diverge.
;;;
;;; A context a module holds PER DYNAMIC EXTENT: `(define-context world #:fluid
;;; %world spec …)` is the same surface over a fluid. The instance is a value:
;;; `(current-world)` is the one in hand, `(call-with-world w thunk)` runs the
;;; thunk with W as the world and leaves the caller's standing, and
;;; `reset-world!` puts a fresh one in hand. Two solves in two extents hold
;;; two worlds; a test that holds one across another's is holding a value.

(define-module (playnet protocol context)
  #:use-module (srfi srfi-9)
  #:export (define-context context-cell context-bind context-install))

;; the names derived from a context's, spelled once; `symbol-append` is Guile's
;; alone, and these run at expand time under Hoot too
(define (symbol-append . syms) (string->symbol (apply string-append (map symbol->string syms))))

(define (copy-table v)
  "V itself, or a new table (or vector) holding V's entries when V is one; a
table held as an entry is copied in turn, so a copy shares no table at any depth."
  (cond ((hash-table? v) (let ((n (make-hash-table)))
                           (hash-for-each (lambda (k x) (hash-set! n k (copy-table x))) v)
                           n))
        ((vector? v) (let* ((n (vector-copy v)) (len (vector-length n)))
                       (let lp ((i 0))
                         (when (< i len) (vector-set! n i (copy-table (vector-ref n i))) (lp (+ i 1))))
                       n))
        (else v)))

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
      ((_ ctx-name #:cell cell spec ...)
       #'(begin
           (define-context ctx-name spec ...)
           (context-cell ctx-name cell spec ...)))
      ((_ ctx-name #:fluid cell spec ...)
       #'(begin
           (define-context ctx-name spec ...)
           (context-cell ctx-name #:fluid cell spec ...)))
      ((_ ctx-name spec ...)
       (let* ((specs  (map (lambda (s) (let ((d (syntax->datum s))) (if (pair? d) d (list d #f)))) #'(spec ...)))
              (fields (map car specs))
              (sym    (syntax->datum #'ctx-name))
              (id     (lambda (s) (datum->syntax #'ctx-name s))))
         (with-syntax ((rtd          (id (symbol-append '< sym '>)))
                       (%make        (id (symbol-append '%make- sym)))
                       (%raw         (id (symbol-append '%raw- sym)))
                       (%fields      (id (symbol-append '% sym '-fields)))
                       (make         (id (symbol-append 'make- sym)))
                       (copy         (id (symbol-append 'copy- sym)))
                       (pred         (id (symbol-append sym '?)))
                       (with-name    (id (symbol-append 'with- sym)))
                       (install-name (id (symbol-append sym '-install!)))
                       ((field ...)   (map id fields))
                       ((idx ...)     (iota (length fields)))
                       ((default ...) (map (lambda (s) (datum->syntax x (cadr s))) specs))
                       ((ref ...)     (map (lambda (f) (id (symbol-append sym '- f))) fields))
                       ((setr ...)    (map (lambda (f) (id (symbol-append 'set- sym '- f '!))) fields)))
           #'(begin
               ;; the fields in ONE vector behind a one-field record: a context of
               ;; many fields stays one type deep (Hoot types a struct of N fields
               ;; as a subtype of the N-1 struct, and wasm engines cap that depth)
               (define-record-type rtd
                 (%raw %fields)
                 pred
                 (%fields %fields))
               (define (%make field ...) (%raw (vector field ...)))
               (define (ref c) (vector-ref (%fields c) idx)) ...
               (define (setr c v) (vector-set! (%fields c) idx v)) ...
               (define* (make #:key (field default) ...)
                 (%make field ...))
               ;; a value of its own: every table (and vector) a new one holding
               ;; the same entries, to any depth; every other field the same
               ;; value. A holder writes the copy and leaves the original standing.
               (define (copy c)
                 (let* ((v (vector-copy (%fields c))) (n (vector-length v)))
                   (let lp ((i 0))
                     (when (< i n) (vector-set! v i (copy-table (vector-ref v i))) (lp (+ i 1))))
                   (%raw v)))
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

;; `(define-context NAME #:cell CELL spec …)`: the module holds ONE instance in
;; CELL, and every field stands at top level under its own name, reading the
;; cell's field and writing it on set!. A module that exports a field's name
;; hands its importers the same read and the same write: the expansion names
;; the cell and the accessor of the defining module, by hygiene, so an importer
;; never assigns a binding it imported, which is the one write Hoot refuses
;; (hoot/library-group.scm: "set! to imported binding") and Guile lets through
;; in silence. `reset-NAME!` makes the cell a fresh instance: every default
;; evaluated again, so a table is a new table.
;;
;; `(define-context NAME #:fluid CELL spec …)`: the same names over a fluid, so
;; the instance in hand is the dynamic extent's. `(current-NAME)` answers it,
;; `(call-with-NAME v thunk)` runs THUNK with V in hand and the caller's instance
;; standing after, and `reset-NAME!` puts a fresh instance in hand. A fluid
;; stands in Guile and in Hoot alike; a fiber or a thread starts from a snapshot
;; of its parent's, so an instance declared in one is the one its own extent
;; reads.
(define-syntax context-cell
  (lambda (x)
    (define (names ctx-name specs)
      (let* ((fields (map (lambda (s) (let ((d (syntax->datum s))) (if (pair? d) (car d) d))) specs))
             (sym    (syntax->datum ctx-name))
             (id     (lambda (s) (datum->syntax ctx-name s))))
        (list (id (symbol-append 'make- sym))
              (id (symbol-append 'reset- sym '!))
              (id (symbol-append 'current- sym))
              (id (symbol-append 'call-with- sym))
              (map id fields)
              (map (lambda (f) (id (symbol-append sym '- f))) fields)
              (map (lambda (f) (id (symbol-append 'set- sym '- f '!))) fields))))
    (syntax-case x ()
      ((_ ctx-name #:fluid cell spec ...)
       (with-syntax (((make reset-name current-name call-with-name (field ...) (ref ...) (setr ...))
                      (names #'ctx-name #'(spec ...))))
         #'(begin
             (define cell (make-fluid (make)))
             (define-syntax field (identifier-syntax (_ (ref (fluid-ref cell))) ((set! _ v) (setr (fluid-ref cell) v)))) ...
             (define (current-name) (fluid-ref cell))
             (define (call-with-name v thunk) (with-fluid* cell v thunk))
             (define (reset-name) (fluid-set! cell (make))))))
      ((_ ctx-name cell spec ...)
       (with-syntax (((make reset-name current-name call-with-name (field ...) (ref ...) (setr ...))
                      (names #'ctx-name #'(spec ...))))
         #'(begin
             (define cell (make))
             (define-syntax field (identifier-syntax (_ (ref cell)) ((set! _ v) (setr cell v)))) ...
             (define (reset-name) (set! cell (make)))))))))
