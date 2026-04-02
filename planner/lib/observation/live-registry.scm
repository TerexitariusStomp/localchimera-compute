;;; live-registry.scm — Goblins actor mapping resource-ids to live-resource actors
;;;
;;; A thin registry within the scope's vat. When lift-planning-facts encounters
;;; a resource-id in this registry, it reads available capacity from the
;;; live-resource actor instead of the observer's accounting-quantity.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))


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
             (hashmap-delete resources resource-id))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define live-registry-env
  (make-persistence-env
    `((((vf observation) ^live-registry) ,^live-registry))))
