;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; serdes.scm — Generic record serialization for VF schemas
;;;
;;; Replaces the per-type `<thing>->list` / `list-><thing>` boilerplate
;;; that used to be hand-rolled in `lib/knowledge/recipes.scm`,
;;; `lib/observation/observer.scm`, and `lib/observation/account.scm`.
;;;
;;; Each record type defined in `lib/schemas.scm` is registered ONCE
;;; via `register-vf-record!`. After that, `vf-serialize` walks any
;;; value and emits a goblins-persistence-friendly form (lists, pairs,
;;; primitives) — recursing into nested records and lists of records
;;; automatically. `vf-deserialize` is the inverse.
;;;
;;; The wire format for a serialized record is:
;;;
;;;   (@vf TypeName (field-name . field-value) ...)
;;;
;;; where `@vf` is a sentinel symbol, `TypeName` is the symbol returned
;;; by `record-type-name`, and the field alist is keyed by the symbols
;;; from `record-type-fields`. The format is self-describing — adding
;;; a field to a record doesn't break previously-serialized data, and
;;; field reordering doesn't either, because reconstruction looks up
;;; fields by name not by position.
;;;
;;; Failure mode: if `vf-serialize` encounters a record whose type was
;;; never registered, it raises an error naming the missing type.
;;; This replaces the previous silent failure where goblins persistence
;;; would crash deep inside `process-one` with no clue which record
;;; was unhandled. (See the `<positioning-analysis>` bug fixed by
;;; lifting it through this module.)
;;;
;;; Registering a new record type is one line:
;;;
;;;   (register-vf-record! <my-record>)
;;;
;;; That's it. The accessor list is read off the type via
;;; `record-type-fields` + `record-accessor`, and the constructor via
;;; `record-constructor`. Adding a field to the record requires no
;;; serdes change.

(define-module (playnet vf serdes)
  #:use-module ((playnet utils records) #:select (vf-record? vf-record-type-name vf-record-type-fields vf-record-constructor vf-record-predicate vf-record-accessor))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (*vf-serdes-registry* vf-serdes-clear! register-vf-record!
            vf-serdes-lookup-by-name vf-serdes-lookup-by-instance vf-record-instance?
            vf-serialize vf-deserialize register-vf-records!))



;; ─────────────────────────────────────────────────────────────────────
;; Registry — alist keyed by record-type-name symbol.
;;
;; Each entry: (TypeName . #(rtd predicate constructor field-names accessors))
;;
;; vector for cheap field access; alist (not hashmap) so the registry
;; can be walked in registration order if we ever need it.
;; ─────────────────────────────────────────────────────────────────────

(define *vf-serdes-registry* '())

(define (vf-serdes-clear!)
  "Reset the registry. Mostly useful for tests."
  (set! *vf-serdes-registry* '()))

(define (register-vf-record! rtd)
  "Register a record type for generic serialization. Idempotent —
   re-registering the same type updates its entry."
  (let* ((name (vf-record-type-name rtd))
         (fields (vf-record-type-fields rtd))
         (predicate (vf-record-predicate rtd))
         (constructor (vf-record-constructor rtd))
         (accessors (map (lambda (f) (vf-record-accessor rtd f)) fields))
         (entry (vector rtd predicate constructor fields accessors)))
    (set! *vf-serdes-registry*
      (cons (cons name entry)
            (filter (lambda (e) (not (eq? (car e) name)))
                    *vf-serdes-registry*)))))

(define (vf-serdes-lookup-by-name name)
  "Return the registry vector for type NAME, or #f."
  (let ((entry (assq name *vf-serdes-registry*)))
    (and entry (cdr entry))))

(define (vf-serdes-lookup-by-instance v)
  "Linear scan: return the registry vector whose predicate matches V,
   or #f. O(N) where N is the number of registered types — small."
  (let loop ((entries *vf-serdes-registry*))
    (cond
      ((null? entries) #f)
      (((vector-ref (cdar entries) 1) v) (cdar entries))
      (else (loop (cdr entries))))))

(define (vf-record-instance? v)
  "True if V is an instance of any registered VF record type."
  (and (vf-serdes-lookup-by-instance v) #t))


;; ─────────────────────────────────────────────────────────────────────
;; vf-serialize / vf-deserialize
;; ─────────────────────────────────────────────────────────────────────

(define (vf-serialize v)
  "Recursively serialize V into a goblins-persistence-friendly form.

   - Primitives (string, number, symbol, boolean, char, '()) pass
     through unchanged.
   - Pairs and proper lists recurse element-wise.
   - Vectors recurse element-wise.
   - Records of REGISTERED types become (@vf TypeName (field . val) ...).
   - Records of UNREGISTERED types raise an error naming the type —
     the deliberate failure mode that prevents silent persistence bugs.
   - Anything else (procedure, port, raw struct, etc.) raises an error.

   Note: this walker does NOT special-case hashmaps. The store-utils
   helpers `serialize-hashmap` / `deserialize-hashmap` already handle
   the collection layer; vf-serialize is meant to be the
   per-value function passed to them."
  (cond
    ((string? v) v)
    ((number? v) v)
    ((symbol? v) v)
    ((boolean? v) v)
    ((char? v) v)
    ((null? v) v)
    ((pair? v)
     (cons (vf-serialize (car v)) (vf-serialize (cdr v))))
    ((vector? v)
     (list->vector (map vf-serialize (vector->list v))))
    ((vf-record? v)
     ;; Looks like a record. Try to serialize.
     (let ((entry (vf-serdes-lookup-by-instance v)))
       (if entry
           (let* ((name (vf-record-type-name (vector-ref entry 0)))
                  (fields (vector-ref entry 3))
                  (accessors (vector-ref entry 4))
                  (field-pairs
                    (map (lambda (f acc)
                           (cons f (vf-serialize (acc v))))
                         fields accessors)))
             (cons '@vf (cons name field-pairs)))
           ;; A struct, but not a registered VF record. Loud failure.
           (error 'vf-serialize
                  "Unregistered record type encountered during serialization. \
Declare it with define-vf-record #:register register-vf-record! (vf/schemas.scm), or call register-vf-record! where it is defined."
                  v))))
    (else
     (error 'vf-serialize "Don't know how to serialize value" v))))

(define (vf-deserialize v)
  "Inverse of vf-serialize. Walks the wire form and reconstructs
   records via their registered constructors."
  (cond
    ((string? v) v)
    ((number? v) v)
    ((symbol? v) v)
    ((boolean? v) v)
    ((char? v) v)
    ((null? v) v)
    ((and (pair? v) (eq? (car v) '@vf))
     (let* ((name (cadr v))
            (field-pairs (cddr v))
            (entry (vf-serdes-lookup-by-name name)))
       (if (not entry)
           (error 'vf-deserialize
                  "Unknown record type in serialized data. \
Did you forget #:register register-vf-record! on its define-vf-record?"
                  name)
           (let* ((fields (vector-ref entry 3))
                  (constructor (vector-ref entry 2))
                  ;; Walk fields in constructor order, look up by name.
                  (vals (map (lambda (f)
                               (let ((cell (assq f field-pairs)))
                                 (if cell
                                     (vf-deserialize (cdr cell))
                                     ;; Field absent in payload —
                                     ;; tolerate as #f, the VF
                                     ;; "optional missing" convention.
                                     #f)))
                             fields)))
             (apply constructor vals)))))
    ((pair? v)
     (cons (vf-deserialize (car v)) (vf-deserialize (cdr v))))
    ((vector? v)
     (list->vector (map vf-deserialize (vector->list v))))
    (else v)))


;; ─────────────────────────────────────────────────────────────────────
;; Convenience: bulk registration
;; ─────────────────────────────────────────────────────────────────────

(define (register-vf-records! . rtds)
  "Register a list of record types in one call."
  (for-each register-vf-record! rtds))
