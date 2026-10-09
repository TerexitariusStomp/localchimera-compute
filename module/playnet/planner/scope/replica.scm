;;; replica.scm — a scope's books, copied to wherever its member is.
;;;
;;; A member's device holds a copy of the scope they are in, so that a count, a
;;; need, an offer are made the same way with or without a gateway in reach. A
;;; replica is that copy as one datum: the scope's goods, places and people, the
;;; needs that stand in it, and the observer's books whole (its stock and every
;;; event behind it), each in the form its own store already keeps it in. The
;;; records travel through the serializer every portrait uses (utils/serdes.scm)
;;; and the books through the observer's own portable snapshot, so a replica is
;;; text that `write` and `read` carry, and nothing here knows a record's fields.
;;;
;;; `scope->replica` reads a scope root; `hold-replica!` seeds another scope root
;;; from it. Seeding replaces by id, so holding a newer replica over an older one
;;; is the refresh.

(define-module (playnet planner scope replica)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet planner vf schemas) #:select (intent-id intent-finished))
  #:use-module ((playnet planner facts person-facts) #:select (need-id?))
  #:use-module ((playnet planner vf serdes) #:select (vf-serialize vf-deserialize))
  #:export (scope->replica hold-replica! replica->text text->replica))

(define (standing-needs plan-store)
  (filter (lambda (i) (and (need-id? (intent-id i)) (not (intent-finished i))))
          ($ plan-store 'all-intents)))

(define (scope->replica root)
  "The scope ROOT holds, as a replica: an alist of its goods, places, people and
   standing needs (serialized records) and its observer's books (the portable
   snapshot)."
  `((specs    . ,(vf-serialize ($ ($ root 'recipe-store) 'all-resource-specs)))
    (places   . ,(vf-serialize ($ ($ root 'spatial-thing-store) 'all-locations)))
    (people   . ,(vf-serialize ($ ($ root 'agent-store) 'all-agents)))
    (needs    . ,(vf-serialize (standing-needs ($ root 'plan-store))))
    (books    . ,($ ($ root 'observer) 'serialize))))

(define (hold-replica! root replica)
  "Seed the scope ROOT from REPLICA: its goods, places, people and needs replace
   by id what the root holds, and its books become the observer's own."
  (define (each key add!)
    (for-each add! (vf-deserialize (or (assq-ref replica key) '()))))
  (let ((rs ($ root 'recipe-store)) (ps ($ root 'plan-store)))
    (each 'specs  (lambda (s) ($ rs 'add-resource-spec s)))
    (each 'places (lambda (p) ($ ($ root 'spatial-thing-store) 'add-location p)))
    (each 'people (lambda (a) ($ ($ root 'agent-store) 'add-agent a)))
    (each 'needs  (lambda (i)
                    (when ($ ps 'get-intent (intent-id i)) ($ ps 'remove-intent (intent-id i)))
                    ($ ps 'add-intent i)))
    (let ((books (assq-ref replica 'books)))
      (when books ($ ($ root 'observer) 'load-snapshot books)))
    root))

;; A replica is plain data — strings, numbers, symbols, booleans, lists — so the
;; text of it is what `write` prints and `read` reads back.
(define (replica->text replica)
  (call-with-output-string (lambda (port) (write replica port))))
(define (text->replica text)
  (read (open-input-string text)))
