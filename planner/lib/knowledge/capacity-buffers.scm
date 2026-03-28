;;; capacity-buffers.scm — Goblins actor for capacity buffer management
;;;
;;; Translated from src/lib/knowledge/capacity-buffers.ts
;;; State: hashmap of buffer-id -> <capacity-buffer> record.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (capacity-buffer->list b)
  (list (capacity-buffer-id b)
        (capacity-buffer-process-spec-id b)
        (capacity-buffer-total-capacity-hours b)
        (capacity-buffer-period-days b)
        (capacity-buffer-current-load-hours b)
        (capacity-buffer-green-threshold b)
        (capacity-buffer-yellow-threshold b)
        (capacity-buffer-note b)))

(define (list->capacity-buffer lst)
  (apply make-capacity-buffer lst))


;; =========================================================================
;; ^capacity-buffer-store
;; =========================================================================

(define-actor (^capacity-buffer-store bcom buffers)
  ;; buffers: hashmap of string -> <capacity-buffer>

  #:portrait
  (lambda () (list (serialize-hashmap buffers capacity-buffer->list)))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^capacity-buffer-store (deserialize-hashmap data list->capacity-buffer)))
      (else (error "Unknown ^capacity-buffer-store version" version))))

  (methods

    ((add-buffer buf)
     (let* ((id (or (capacity-buffer-id buf) (generate-id "cb-")))
            (new-buffers (hashmap-set buffers id buf)))
       (bcom (^capacity-buffer-store bcom new-buffers) id)))

    ((get-buffer id)
     (hashmap-ref buffers id #f))

    ((all-buffers)
     (hashmap-values buffers))

    ((buffer-for-spec process-spec-id)
     (hashmap-find
       (lambda (b) (equal? (capacity-buffer-process-spec-id b) process-spec-id))
       buffers))

    ((update-buffer id updates-alist)
     ;; updates-alist: list of (field-symbol . value) pairs.
     ;; Rebuilds the record with updated fields.
     (let ((existing (hashmap-ref buffers id #f)))
       (unless existing
         (error (string-append "CapacityBuffer " id " not found")))
       (let* ((fields (capacity-buffer->list existing))
              ;; Field index mapping for the 8 fields
              (idx-map '((process-spec-id . 1) (total-capacity-hours . 2)
                         (period-days . 3) (current-load-hours . 4)
                         (green-threshold . 5) (yellow-threshold . 6) (note . 7)))
              (updated-fields
                (let loop ((fl fields) (i 0))
                  (if (null? fl) '()
                      (let ((override (assq (cdr (or (find (lambda (p) (= (cdr p) i)) idx-map) (cons #f #f)))
                                            updates-alist)))
                        (cons (if override (cdr override) (car fl))
                              (loop (cdr fl) (+ i 1))))))))
         ;; Keep original id
         (let ((new-buf (list->capacity-buffer (cons id (cdr updated-fields)))))
           (bcom (^capacity-buffer-store bcom (hashmap-set buffers id new-buf)))))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define capacity-buffer-store-env
  (make-persistence-env
    `((((vf knowledge) ^capacity-buffer-store) ,^capacity-buffer-store))))
