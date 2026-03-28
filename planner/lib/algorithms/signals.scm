;;; signals.scm — Planning signal types and conversion functions
;;;
;;; Translated from src/lib/planning/planning.ts (signal sections)
;;; Pure functions for converting between typed signal alists and VF Intents.
;;;
;;; Signal kinds: deficit, surplus, conservation, replenishment
;;; Each signal is an alist with a 'kind key and domain-specific fields.
;;; Signals are stored as Intents with tag-based classification +
;;; metadata alists in the plan-store.

;; Assumes schemas.scm is loaded.

(use-modules (srfi srfi-1))


;; =========================================================================
;; Plan tags — canonical classification tags for signal intents
;; =========================================================================

(define *plan-tags*
  '((deficit       . "tag:plan:deficit")
    (surplus       . "tag:plan:surplus")
    (conservation  . "tag:plan:conservation")
    (replenishment . "tag:plan:replenishment")
    (metabolic-debt . "tag:plan:metabolic-debt")
    (reservation-gap . "tag:plan:reservation-gap")
    (container-bound . "tag:plan:container-bound")
    (offer         . "tag:plan:offer")
    (request       . "tag:plan:request")))

(define (plan-tag kind)
  "Get the tag string for a signal kind symbol."
  (or (assq-ref *plan-tags* kind)
      (string-append "tag:plan:" (symbol->string kind))))


;; =========================================================================
;; Signal -> Intent conversion
;; =========================================================================

(define (signal->intent signal plan-id)
  "Convert a typed signal alist to Intent fields + metadata alist.
   Returns (values intent-alist meta-alist).
   signal: alist with 'kind key + domain fields.
   plan-id: string."
  (let ((kind (assq-ref signal 'kind)))
    (case kind
      ((deficit)
       (let* ((spec-id (assq-ref signal 'spec-id))
              (qty (assq-ref signal 'qty))
              (unit (or (assq-ref signal 'unit) "each"))
              (scope (assq-ref signal 'scope))
              (due (assq-ref signal 'due))
              (location (assq-ref signal 'location))
              (source (assq-ref signal 'source))
              (tags (if (eq? source 'metabolic-debt)
                        (list (plan-tag 'deficit) (plan-tag 'metabolic-debt))
                        (list (plan-tag 'deficit))))
              (intent-fields
                (make-intent
                  #f 'transfer #f #f #f #f #f #f
                  spec-id tags
                  (make-measure qty unit) #f #f #f
                  #f scope  ;; receiver = scope
                  #f #f #f due
                  location #f #f
                  plan-id #f #f #f #f))
              (meta `((kind . deficit)
                      (original-shortfall . ,(or (assq-ref signal 'original-shortfall) qty))
                      (resolved-at . ,(or (assq-ref signal 'resolved-at) '())))))
         (values intent-fields meta)))

      ((surplus)
       (let* ((spec-id (assq-ref signal 'spec-id))
              (qty (assq-ref signal 'qty))
              (unit (or (assq-ref signal 'unit) "each"))
              (scope (assq-ref signal 'scope))
              (available-from (assq-ref signal 'available-from))
              (location (assq-ref signal 'location))
              (intent-fields
                (make-intent
                  #f 'transfer #f #f #f #f #f #f
                  spec-id (list (plan-tag 'surplus))
                  (make-measure qty unit) #f #f #f
                  scope #f  ;; provider = scope
                  #f #f #f available-from
                  location #f #f
                  plan-id #f #f #f #f))
              (meta `((kind . surplus))))
         (values intent-fields meta)))

      ((conservation)
       (let* ((spec-id (assq-ref signal 'spec-id))
              (scope (assq-ref signal 'scope))
              (intent-fields
                (make-intent
                  #f 'cite #f #f #f #f #f #f
                  spec-id (list (plan-tag 'conservation))
                  #f #f #f #f
                  #f scope
                  #f #f #f #f #f #f #f
                  plan-id #f #f #f #f))
              (meta `((kind . conservation)
                      (onhand . ,(assq-ref signal 'onhand))
                      (tor . ,(assq-ref signal 'tor))
                      (toy . ,(assq-ref signal 'toy))
                      (tog . ,(assq-ref signal 'tog))
                      (zone . ,(assq-ref signal 'zone))
                      (tipping-point-breached . ,(assq-ref signal 'tipping-point-breached)))))
         (values intent-fields meta)))

      ((replenishment)
       (let* ((spec-id (assq-ref signal 'spec-id))
              (qty (assq-ref signal 'qty))
              (unit (or (assq-ref signal 'unit) "each"))
              (due-date (assq-ref signal 'due-date))
              (intent-fields
                (make-intent
                  #f 'produce #f #f #f #f #f #f
                  spec-id (list (plan-tag 'replenishment))
                  (make-measure qty unit) #f #f #f
                  #f #f  ;; agents TBD
                  #f #f #f due-date #f #f #f
                  plan-id #f #f #f #f))
              (meta `((kind . replenishment)
                      (onhand . ,(assq-ref signal 'onhand))
                      (onorder . ,(assq-ref signal 'onorder))
                      (qualified-demand . ,(assq-ref signal 'qualified-demand))
                      (nfp . ,(assq-ref signal 'nfp))
                      (priority . ,(assq-ref signal 'priority))
                      (zone . ,(assq-ref signal 'zone))
                      (recommended-qty . ,qty)
                      (due-date . ,due-date)
                      (buffer-zone-id . ,(assq-ref signal 'buffer-zone-id))
                      (status . open))))
         (values intent-fields meta)))

      (else (error (format #f "Unknown signal kind: ~a" kind))))))


;; =========================================================================
;; Intent -> Signal reconstruction
;; =========================================================================

(define (intent->signal intent meta)
  "Reconstruct a typed signal alist from an Intent + metadata.
   Returns signal alist or #f if the intent is not a signal."
  (let ((tags (or (intent-resource-classified-as intent) '())))
    (cond
      ((member (plan-tag 'deficit) tags)
       (let ((qty (if (intent-resource-quantity intent)
                      (measure-has-numerical-value (intent-resource-quantity intent))
                      0)))
         `((kind . deficit)
           (spec-id . ,(intent-resource-conforms-to intent))
           (qty . ,qty)
           (unit . ,(if (intent-resource-quantity intent)
                        (measure-has-unit (intent-resource-quantity intent))
                        "each"))
           (scope . ,(intent-receiver intent))
           (due . ,(intent-due intent))
           (location . ,(intent-at-location intent))
           (original-shortfall . ,(and meta (assq-ref meta 'original-shortfall)))
           (resolved-at . ,(and meta (assq-ref meta 'resolved-at)))
           (source . ,(if (member (plan-tag 'metabolic-debt) tags)
                          'metabolic-debt 'unmet-demand)))))

      ((member (plan-tag 'surplus) tags)
       (let ((qty (if (intent-resource-quantity intent)
                      (measure-has-numerical-value (intent-resource-quantity intent))
                      0)))
         `((kind . surplus)
           (spec-id . ,(intent-resource-conforms-to intent))
           (qty . ,qty)
           (unit . ,(if (intent-resource-quantity intent)
                        (measure-has-unit (intent-resource-quantity intent))
                        "each"))
           (scope . ,(intent-provider intent))
           (available-from . ,(intent-due intent))
           (location . ,(intent-at-location intent)))))

      ((member (plan-tag 'conservation) tags)
       (if (not meta) #f
           `((kind . conservation)
             (spec-id . ,(intent-resource-conforms-to intent))
             (scope . ,(intent-receiver intent))
             (onhand . ,(assq-ref meta 'onhand))
             (tor . ,(assq-ref meta 'tor))
             (toy . ,(assq-ref meta 'toy))
             (tog . ,(assq-ref meta 'tog))
             (zone . ,(assq-ref meta 'zone))
             (tipping-point-breached . ,(assq-ref meta 'tipping-point-breached)))))

      ((member (plan-tag 'replenishment) tags)
       (if (not meta) #f
           (let ((qty (if (intent-resource-quantity intent)
                          (measure-has-numerical-value (intent-resource-quantity intent))
                          0)))
             `((kind . replenishment)
               (spec-id . ,(intent-resource-conforms-to intent))
               (qty . ,qty)
               (unit . ,(if (intent-resource-quantity intent)
                            (measure-has-unit (intent-resource-quantity intent))
                            "each"))
               (nfp . ,(assq-ref meta 'nfp))
               (priority . ,(assq-ref meta 'priority))
               (zone . ,(assq-ref meta 'zone))
               (due-date . ,(assq-ref meta 'due-date))
               (buffer-zone-id . ,(assq-ref meta 'buffer-zone-id))))))

      (else #f))))
