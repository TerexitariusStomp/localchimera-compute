;;; buffer-snapshots.scm — Goblins actor for buffer health time-series
;;;
;;; Translated from src/lib/knowledge/buffer-snapshots.ts
;;; State: append-only list of <buffer-snapshot> records.

(use-modules (goblins)
             (goblins actor-lib methods)
             (srfi srfi-1))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (buffer-snapshot->list s)
  (list (buffer-snapshot-spec-id s)
        (buffer-snapshot-date s)
        (buffer-snapshot-onhand s)
        (buffer-snapshot-tor s)
        (buffer-snapshot-toy s)
        (buffer-snapshot-tog s)
        (buffer-snapshot-zone s)))

(define (list->buffer-snapshot lst)
  (apply make-buffer-snapshot lst))


;; =========================================================================
;; ^snapshot-store
;; =========================================================================

(define-actor (^snapshot-store bcom snapshots)
  ;; snapshots: list of <buffer-snapshot> (newest first for efficient cons)

  #:portrait
  (lambda () (list (map buffer-snapshot->list snapshots)))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^snapshot-store (map list->buffer-snapshot data)))
      (else (error "Unknown ^snapshot-store version" version))))

  (methods

    ((record-snapshot snap)
     ;; Append a single snapshot.
     (bcom (^snapshot-store bcom (cons snap snapshots))))

    ((record-all snaps)
     ;; Append multiple snapshots.
     (bcom (^snapshot-store bcom (append (reverse snaps) snapshots))))

    ((for-spec spec-id . rest)
     ;; Filter by spec-id. Optional date range: (for-spec id from to).
     (let* ((from (if (and (pair? rest) (car rest)) (car rest) #f))
            (to   (if (and (pair? rest) (pair? (cdr rest)) (cadr rest)) (cadr rest) #f))
            (matching (filter
                        (lambda (s) (equal? (buffer-snapshot-spec-id s) spec-id))
                        snapshots)))
       (filter (lambda (s)
                 (let ((d (buffer-snapshot-date s)))
                   (and (or (not from) (string>=? d from))
                        (or (not to)   (string<=? d to)))))
               matching)))

    ((latest spec-id)
     ;; Most recent snapshot for a spec (by date string comparison).
     (let ((matching (filter
                       (lambda (s) (equal? (buffer-snapshot-spec-id s) spec-id))
                       snapshots)))
       (if (null? matching) #f
           (fold (lambda (s best)
                   (if (string>? (buffer-snapshot-date s) (buffer-snapshot-date best))
                       s best))
                 (car matching) (cdr matching)))))

    ((all-snapshots)
     (reverse snapshots))

    ((tracked-specs)
     ;; Unique spec IDs.
     (delete-duplicates (map buffer-snapshot-spec-id snapshots)))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define snapshot-store-env
  (make-persistence-env
    `((((vf knowledge) ^snapshot-store) ,^snapshot-store))))
