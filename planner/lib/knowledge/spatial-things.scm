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
        (spatial-thing-mappable-address st)))

(define (list->spatial-thing lst)
  (apply make-spatial-thing lst))


;; =========================================================================
;; ^spatial-thing-store
;; =========================================================================

(define-actor (^spatial-thing-store bcom locations)
  ;; locations: hashmap of string -> <spatial-thing>

  #:portrait
  (lambda () (list (serialize-hashmap locations spatial-thing->list)))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^spatial-thing-store (deserialize-hashmap data list->spatial-thing)))
      (else (error "Unknown ^spatial-thing-store version" version))))

  (methods

    ((add-location loc)
     (let* ((id (or (spatial-thing-id loc) (generate-id "loc-")))
            (new-locs (hashmap-set locations id loc)))
       (bcom (^spatial-thing-store bcom new-locs) id)))

    ((get-location id)
     (hashmap-ref locations id #f))

    ((all-locations)
     (hashmap-values locations))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define spatial-thing-store-env
  (make-persistence-env
    `((((vf knowledge) ^spatial-thing-store) ,^spatial-thing-store))))
