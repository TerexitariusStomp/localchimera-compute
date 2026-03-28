;;; process-registry.scm — Goblins actor for shared process lifecycle
;;;
;;; Translated from src/lib/process-registry.ts
;;; Shared between PlanStore and Observer — both reference the same processes.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (process->list p)
  (list (process-id p) (process-name p) (process-note p)
        (process-based-on p) (process-classified-as p)
        (process-planned-within p) (process-nested-in p)
        (process-in-scope-of p) (process-has-beginning p)
        (process-has-end p) (process-finished p)))

(define (list->process* lst) (apply make-process lst))


;; =========================================================================
;; ^process-registry — persistent Goblins actor
;; =========================================================================

(define-actor (^process-registry bcom procs)
  ;; procs: hashmap of process-id -> <process>

  #:portrait
  (lambda () (list (serialize-hashmap procs process->list)))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^process-registry (deserialize-hashmap data list->process*)))
      (else (error "Unknown ^process-registry version" version))))

  (methods

    ((register proc)
     (let* ((id (or (process-id proc) (generate-id "proc-")))
            (new-procs (hashmap-set procs id proc)))
       (bcom (^process-registry bcom new-procs) proc)))

    ((get id)
     (hashmap-ref procs id #f))

    ((has id)
     (if (hashmap-ref procs id #f) #t #f))

    ((all)
     (hashmap-values procs))

    ((for-plan plan-id)
     (hashmap-filter
       (lambda (p) (equal? (process-planned-within p) plan-id))
       procs))

    ((for-spec spec-id)
     (hashmap-filter
       (lambda (p) (equal? (process-based-on p) spec-id))
       procs))

    ((finished)
     (hashmap-filter (lambda (p) (process-finished p)) procs))

    ((active)
     (hashmap-filter (lambda (p) (not (process-finished p))) procs))

    ((mark-finished id)
     (let ((proc (hashmap-ref procs id #f)))
       (if (not proc) (values)
           (let ((updated (make-process
                            id (process-name proc) (process-note proc)
                            (process-based-on proc) (process-classified-as proc)
                            (process-planned-within proc) (process-nested-in proc)
                            (process-in-scope-of proc) (process-has-beginning proc)
                            (process-has-end proc) #t)))
             (bcom (^process-registry bcom (hashmap-set procs id updated)))))))

    ((unregister id)
     (bcom (^process-registry bcom (hashmap-remove procs id))))

    ((clear)
     (bcom (^process-registry bcom (hashmap))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define process-registry-env
  (make-persistence-env
    `((((vf) ^process-registry) ,^process-registry))))
