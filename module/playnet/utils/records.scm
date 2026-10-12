;;; records.scm — record types with identity, across the load seam.
;;;
;;; `make-record-type` mints a FRESH type on every evaluation. The planner's
;;; schemas are reached two ways — imported as a module by `(playnet boot prelude)`,
;;; and `primitive-load`ed directly by the solver engine when it runs standalone
;;; — so the same definition was evaluated twice and produced two types that
;;; share a name and nothing else.
;;;
;;; Nothing warns you. `time-range?` from one side answers #f for the other
;;; side's value, and an accessor raises "wrong type". The arithmetic in
;;; `utils/clock.scm` lives at the STRING layer for exactly this reason: strings
;;; have identity, and records did not.
;;;
;;; A type is its name here. The first evaluation mints it, every later one finds
;;; it, and both sides hold the same object — so a value made on either side is
;;; the same kind of thing.
;;;
;;; The registry is a module, so it is instantiated once per process however many
;;; paths reach it. That is the whole mechanism: identity by name, held somewhere
;;; both loaders can see.
;;;
;;; Redefining a name with DIFFERENT fields is the one case that cannot be
;;; silently reconciled — two shapes under one name is a real disagreement, so it
;;; raises rather than handing back a type whose accessors do not fit.
;;
;; Hoot (the browser build) has no runtime record reflection — no
;; `make-record-type`, `record-constructor` or `record-accessor` — so this module
;; also carries the five reflective operations the schemas use, under `vf-` names.
;; On Guile each is the core procedure itself. On Hoot they are a small generic
;; record: an instance is the type plus a vector of its field values, an accessor
;; is an index into it. Every caller states its record operations through here,
;; so the two builds read one surface.


(define-module (playnet utils records)
  #:use-module (srfi srfi-9)
  #:export (vf-record-type vf-record-type-names
            vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier
            vf-record-type-name vf-record-type-fields vf-record? vf-record-copier vf-record-maker
            vf-record-from-list define-vf-record))

(define (field-name f)
  "A field spec is a bare symbol or (immutable NAME) / (mutable NAME)."
  (if (pair? f) (cadr f) f))

(cond-expand
 (guile
  (define vf-record-constructor record-constructor)
  (define vf-record-predicate record-predicate)
  (define vf-record-accessor record-accessor)
  (define vf-record-modifier record-modifier)
  (define vf-record-type-name record-type-name)
  (define vf-record-type-fields record-type-fields)
  (define (vf-record? x) (struct? x))
  (define %interned (make-hash-table))
  (define (%mint name fields) (make-record-type name fields))
  (define (%lookup name) (hashq-ref %interned name))
  (define (%intern! name v) (hashq-set! %interned name v))
  (define (vf-record-type-names)
    "Every interned type name — what has crossed the seam so far."
    (hash-map->list (lambda (k v) k) %interned)))
 (else
  (define-record-type <vf-rtd> (%make-rtd name fields) vf-rtd? (name %rtd-name) (fields %rtd-fields))
  (define-record-type <vf-instance> (%make-instance rtd vals) vf-instance? (rtd %inst-rtd) (vals %inst-vals))
  (define (%index rtd field)
    (let loop ((fs (%rtd-fields rtd)) (i 0))
      (cond ((null? fs) (error "no such field" (%rtd-name rtd) field))
            ((eq? (car fs) field) i)
            (else (loop (cdr fs) (+ i 1))))))
  (define (%check rtd r who)
    (unless (and (vf-instance? r) (eq? (%inst-rtd r) rtd))
      (error "wrong record type" who (%rtd-name rtd))))
  (define (vf-record? x) (vf-instance? x))
  (define (vf-record-type-name rtd) (%rtd-name rtd))
  (define (vf-record-type-fields rtd) (%rtd-fields rtd))
  (define (vf-record-constructor rtd)
    (let ((n (length (%rtd-fields rtd))))
      (lambda args
        (unless (= (length args) n) (error "wrong number of fields" (%rtd-name rtd) n))
        (%make-instance rtd (list->vector args)))))
  (define (vf-record-predicate rtd) (lambda (x) (and (vf-instance? x) (eq? (%inst-rtd x) rtd))))
  (define (vf-record-accessor rtd field)
    (let ((i (%index rtd field)))
      (lambda (r) (%check rtd r field) (vector-ref (%inst-vals r) i))))
  (define (vf-record-modifier rtd field)
    (let ((i (%index rtd field)))
      (lambda (r v) (%check rtd r field) (vector-set! (%inst-vals r) i v))))
  (define %interned '())
  (define (%mint name fields) (%make-rtd name (map field-name fields)))
  (define (%lookup name) (assq-ref %interned name))
  (define (%intern! name v) (set! %interned (cons (cons name v) %interned)))
  (define (vf-record-type-names) (map car %interned))))

(define (vf-record-type name fields)
  "The record type called NAME, minted once and shared thereafter.

   Drop-in for `make-record-type`: same arguments, same return, except that
   evaluating the definition twice yields the SAME type rather than two."
  (let ((names (map field-name fields))
        (have  (%lookup name)))
    (cond
     ((not have)
      (let ((t (%mint name fields)))
        (%intern! name (cons t names))
        t))
     ((equal? (cdr have) names) (car have))
     (else
      (error "record type redefined with different fields" name
             'was (cdr have) 'now names)))))

(define (vf-record-copier rtd)
  "The functional update on records of type RTD: (copy r #:field value …) is a
   new record carrying every field of R except those named. The type knows its
   own fields, accessors and constructor, so a field added to the type is carried
   by every copy with no edit, and a keyword naming no field is an error.

   (define copy-intent (vf-record-copier <intent>))
   (copy-intent it #:finished #t)"
  (let* ((fields (vf-record-type-fields rtd))
         (make   (vf-record-constructor rtd))
         (refs   (map (lambda (f) (vf-record-accessor rtd f)) fields)))
    (lambda (r . overrides)
      (let ((given (let loop ((k overrides) (acc '()))
                     (cond ((null? k) acc)
                           ((or (not (keyword? (car k))) (null? (cdr k)))
                            (error "copy: expected #:field value pairs" (vf-record-type-name rtd) k))
                           (else
                            (let ((f (keyword->symbol (car k))))
                              (unless (memq f fields)
                                (error "copy: no such field" (vf-record-type-name rtd) f))
                              (loop (cddr k) (acons f (cadr k) acc))))))))
        (apply make (map (lambda (f ref) (let ((o (assq f given))) (if o (cdr o) (ref r))))
                         fields refs))))))

(define (vf-record-maker rtd)
  "The keyword constructor of records of type RTD: (make #:field value …) is a
   record carrying the named fields and #f in every other — the copier over the
   blank record, so a keyword naming no field is the same error, and a call
   spells only what it states.

   (define make-intent (vf-record-maker <intent>))
   (make-intent #:id \"i1\" #:action 'consume #:resource-conforms-to \"bread\")"
  (let* ((fields (vf-record-type-fields rtd))
         (blank  (apply (vf-record-constructor rtd) (map (lambda (f) #f) fields)))
         (copy   (vf-record-copier rtd)))
    (lambda args (if (null? args) blank (apply copy blank args)))))

(define (vf-record-from-list rtd)
  "The reader of a record a store keeps as its field list, the type's fields in
   order with trailing ones left off: (list->x lst) reads #f in every field the
   list leaves off. The stores that write a record as a list (the agent, process
   and place registries) read it back through this; a record built in code
   names its fields (vf-record-maker)."
  (let ((fields (vf-record-type-fields rtd))
        (make   (vf-record-constructor rtd)))
    (lambda (lst)
      (apply make (append lst (map (lambda (f) #f)
                                   (list-tail fields (min (length lst) (length fields)))))))))

;; ── one declaration per record type ─────────────────────────────────────────
;; (define-vf-record <agent> Agent (id type name …) [#:register register!] [#:prefix p])
;; defines the type (vf-record-type, so it keeps its identity across the load
;; seam), the predicate `agent?` and one accessor `agent-<field>` per field —
;; the names the hand-written blocks spelled, now read off the type name and
;; the field list. The declaring module names them in its define-module's
;; #:export (Hoot reads exports there alone and has no run-time `export`), and
;; tools/lint/check-record-exports.scm holds that list to the declarations.
;; With #:register, the
;; type is handed to that procedure as it is defined (the serdes registry),
;; so a record type is persistable by being declared. The keyword maker, a
;; positional constructor and a copier stay one-liners beside the form,
;; since their names vary (make-x, %x, %make-x, copy-x).
(define-syntax define-vf-record
  (lambda (x)
    (define (sym->str s) (symbol->string s))
    (define (prefix-of type-sym)
      ;; <economic-event> → "economic-event"
      (let ((s (sym->str type-sym)))
        (if (and (> (string-length s) 2)
                 (char=? (string-ref s 0) #\<)
                 (char=? (string-ref s (- (string-length s) 1)) #\>))
            (substring s 1 (- (string-length s) 1))
            s)))
    (syntax-case x ()
      ((_ type name (field ...) . opts)
       (let* ((o (syntax->datum #'opts))
              (opt (lambda (k) (let loop ((o o)) (cond ((or (null? o) (null? (cdr o))) #f)
                                                      ((eq? (car o) k) (cadr o))
                                                      (else (loop (cddr o)))))))
              ;; #:prefix p names the accessors p-<field> (the predicate stays <type>?) where
              ;; they do not read off the type name (rstock-spec of <regenerating-stock>)
              (tpfx (prefix-of (syntax->datum #'type)))
              (pfx (let ((p (opt #:prefix))) (if p (sym->str p) tpfx)))
              (ctx #'type)
              (mk (lambda (str) (datum->syntax ctx (string->symbol str))))
              (fields (syntax->datum #'(field ...)))
              (reg (opt #:register)))
         (with-syntax ((pred (mk (string-append tpfx "?")))
                       ((acc ...) (map (lambda (f) (mk (string-append pfx "-" (sym->str f)))) fields))
                       (register (if reg (datum->syntax ctx reg) #f)))
           (if reg
               #'(begin
                   (define type (vf-record-type 'name '((immutable field) ...)))
                   (define pred (vf-record-predicate type))
                   (define acc (vf-record-accessor type 'field)) ...
                   (register type))
               #'(begin
                   (define type (vf-record-type 'name '((immutable field) ...)))
                   (define pred (vf-record-predicate type))
                   (define acc (vf-record-accessor type 'field)) ...))))))))
