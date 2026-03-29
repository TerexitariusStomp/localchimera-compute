;;; spatial-things.scm — Goblins actor for location management
;;;
;;; Translated from src/lib/knowledge/spatial-things.ts
;;; State: hashmap of location-id -> <spatial-thing> record.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (spatial-thing->list st)
  (list (spatial-thing-id st)
        (spatial-thing-name st)
        (spatial-thing-note st)
        (spatial-thing-lat st)
        (spatial-thing-long st)
        (spatial-thing-alt st)
        (spatial-thing-mappable-address st)
        (spatial-thing-contained-in st)))

(define (list->spatial-thing lst)
  (apply make-spatial-thing lst))


;; =========================================================================
;; Internal helpers (pure, operate on hashmap)
;; =========================================================================

(define (resolve-chain-hm locations id)
  "Walk containedIn chain from id. Returns list [self, parent, ..., root].
   Breaks on cycle or missing parent."
  (let loop ((current-id id) (visited '()) (chain '()))
    (cond
      ((not current-id) (reverse chain))
      ((member current-id visited string=?) (reverse chain))  ; cycle guard
      (else
        (let ((st (hashmap-ref locations current-id #f)))
          (if (not st)
              (reverse chain)
              (loop (spatial-thing-contained-in st)
                    (cons current-id visited)
                    (cons st chain))))))))

(define (resolve-coordinates-hm locations id)
  "Walk chain upward, return first (lat . long) pair found, or #f."
  (let ((chain (resolve-chain-hm locations id)))
    (let loop ((rest chain))
      (if (null? rest)
          #f
          (let ((st (car rest)))
            (if (and (spatial-thing-lat st) (spatial-thing-long st))
                (cons (spatial-thing-lat st) (spatial-thing-long st))
                (loop (cdr rest))))))))

(define (is-descendant-or-equal-hm locations candidate-id ancestor-id)
  "True if candidate-id equals ancestor-id or is transitively contained in it."
  (if (string=? candidate-id ancestor-id)
      #t
      (let ((chain (resolve-chain-hm locations candidate-id)))
        (any (lambda (st) (string=? (spatial-thing-id st) ancestor-id)) chain))))


;; =========================================================================
;; ^spatial-thing-store
;; =========================================================================

(define-actor (^spatial-thing-store bcom locations)
  ;; locations: hashmap of string -> <spatial-thing>

  #:portrait
  (lambda () (list (serialize-hashmap locations spatial-thing->list)))

  #:version 2

  #:restore
  (lambda (version data)
    (case version
      ;; v1: 7-field records — append #f for contained-in
      ((1) (spawn ^spatial-thing-store
             (deserialize-hashmap data
               (lambda (lst) (list->spatial-thing (append lst '(#f)))))))
      ((2) (spawn ^spatial-thing-store (deserialize-hashmap data list->spatial-thing)))
      (else (error "Unknown ^spatial-thing-store version" version))))

  (methods

    ((add-location loc)
     (let* ((id (or (spatial-thing-id loc) (generate-id "loc-")))
            ;; Cycle detection: walk proposed parent's chain for id
            (contained (spatial-thing-contained-in loc))
            (_ (when contained
                 (let ((chain (resolve-chain-hm locations contained)))
                   (when (any (lambda (st) (string=? (spatial-thing-id st) id)) chain)
                     (error "SpatialThing cycle detected" id contained)))))
            (new-locs (hashmap-set locations id loc)))
       (bcom (^spatial-thing-store bcom new-locs) id)))

    ((get-location id)
     (hashmap-ref locations id #f))

    ((all-locations)
     (hashmap-values locations))

    ((resolve-root id)
     (let ((chain (resolve-chain-hm locations id)))
       (if (null? chain) #f (last chain))))

    ((resolve-coordinates id)
     (resolve-coordinates-hm locations id))

    ((resolve-chain id)
     (resolve-chain-hm locations id))

    ((is-descendant-or-equal candidate-id ancestor-id)
     (is-descendant-or-equal-hm locations candidate-id ancestor-id))

    ((children-of id)
     (filter (lambda (st) (equal? (spatial-thing-contained-in st) id))
             (hashmap-values locations)))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define spatial-thing-store-env
  (make-persistence-env
    `((((vf knowledge) ^spatial-thing-store) ,^spatial-thing-store))))
