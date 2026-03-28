;;; store-registry.scm — Goblins actor for cross-scope reference resolution
;;;
;;; Translated from src/lib/planning/store-registry.ts
;;; Implements the federation namespace: maps scope IDs to plan-store
;;; actor references and supports qualified reference resolution.
;;;
;;; Qualified reference format: "scope-id::record-id"

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

;; Assumes schemas.scm, store-utils.scm, signals.scm are loaded.


;; ═════════════════════════════════════════════════════════════════════════
;; Qualified reference parsing
;; ═════════════════════════════════════════════════════════════════════════

(define (qualify scope-id record-id)
  "Encode a qualified reference: scope-id::record-id."
  (string-append scope-id "::" record-id))

(define (parse-ref ref)
  "Parse a qualified reference. Returns (values scope-id record-id) or #f."
  (let ((idx (string-contains ref "::")))
    (if (not idx) (values #f #f)
        (values (substring ref 0 idx)
                (substring ref (+ idx 2))))))


;; ═════════════════════════════════════════════════════════════════════════
;; ^store-registry — persistent Goblins actor
;; ═════════════════════════════════════════════════════════════════════════

(define-actor (^store-registry bcom scope-refs)
  ;; scope-refs: hashmap of scope-id (string) -> plan-store actor reference
  ;; Actor references persist natively in Goblins (near refs serialize as IDs).

  (methods

    ((register scope-id plan-store-ref)
     ;; Add or update a scope's plan-store reference.
     (bcom (^store-registry bcom
             (hashmap-set scope-refs scope-id plan-store-ref))
           scope-id))

    ((get scope-id)
     ;; Get the plan-store reference for a scope, or #f.
     (hashmap-ref scope-refs scope-id #f))

    ((all-scope-ids)
     ;; List all registered scope IDs.
     (hashmap-keys scope-refs))

    ((resolve qualified-ref)
     ;; Resolve a qualified reference "scope-id::record-id".
     ;; Returns alist: ((intent . ...) (commitment . ...) (plan . ...)) or empty.
     (let-values (((scope-id record-id) (parse-ref qualified-ref)))
       (if (not scope-id) '()
           (let ((store (hashmap-ref scope-refs scope-id #f)))
             (if (not store) '()
                 ;; Try each record type
                 (let ((intent ($ store 'get-intent record-id))
                       (commitment ($ store 'get-commitment record-id))
                       (plan ($ store 'get-plan record-id))
                       (meta ($ store 'get-meta record-id)))
                   (filter cdr
                     `((intent . ,intent)
                       (commitment . ,commitment)
                       (plan . ,plan)
                       (meta . ,meta)))))))))

    ((intents-for-tag tag)
     ;; Cross-scope tag query. Returns list of (scope-id . intent) pairs.
     (hashmap-fold
       (lambda (scope-id store acc)
         (let ((intents ($ store 'intents-for-tag tag)))
           (append (map (lambda (i) (cons scope-id i)) intents) acc)))
       '() scope-refs))

    ((scope-count)
     (hashmap-count scope-refs))))


;; ═════════════════════════════════════════════════════════════════════════
;; Persistence environment
;; ═════════════════════════════════════════════════════════════════════════

(define store-registry-env
  (make-persistence-env
    `((((vf planning) ^store-registry) ,^store-registry))))
