;;; live-registry.scm — Goblins actor mapping resource-ids to live-resource actors
;;;
;;; A thin registry within the scope's vat. When lift-planning-facts encounters
;;; a resource-id in this registry, it reads available capacity from the
;;; live-resource actor instead of the observer's accounting-quantity.

(define-module (playnet observation live-registry)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet utils store-utils)
  #:use-module (goblins utils hashmap)
  #:export (^live-registry live-registry-env live-availability))


;; =========================================================================
;; ^live-registry
;; =========================================================================

(define-actor (^live-registry bcom resources)
  ;; resources: hashmap of resource-id (string) → ^live-resource actor ref

  #:portrait
  (lambda () (list resources))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^live-registry data))
      (else (error "Unknown ^live-registry version" version))))

  (methods

    ((register resource-id live-ref)
     (bcom (^live-registry bcom
             (hashmap-set resources resource-id live-ref))
           resource-id))

    ((get resource-id)
     (hashmap-ref resources resource-id #f))

    ((has? resource-id)
     (if (hashmap-ref resources resource-id #f) #t #f))

    ((all-ids)
     (hashmap-keys resources))

    ((remove resource-id)
     (bcom (^live-registry bcom
             (hashmap-remove resources resource-id))))))


;; =========================================================================
;; live-availability — the registry as the engine's #:live-avail reading
;; =========================================================================

(define (live-availability registry)
  "REGISTRY → a (resource-id → available | #f) procedure, the exact shape
   ingest-stock!'s #:live-avail takes: reservation-aware free capacity for a
   registered resource, #f for anything unregistered (the ingest then reads
   the observer's onhand as usual). Call within the registry's vat — the
   solve's ingest runs in the same turn as the scope reads.

   REGISTRY #f — a scope that keeps none — yields #f rather than a procedure,
   which is the engine's own `live-avail` default: nothing is registered, so
   every ingest reads onhand. A missing registry is the limit case of an empty
   one, and answering it here keeps the absence from becoming a closure that
   only fails later, inside the ingest, far from the root that lacked the part."
  (and registry
       (lambda (resource-id)
         (let ((ref ($ registry 'get resource-id)))
           (and ref ($ ref 'available))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define live-registry-env
  (make-persistence-env
    `((((vf observation) ^live-registry) ,^live-registry))))
